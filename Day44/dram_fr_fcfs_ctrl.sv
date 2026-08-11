// ---------------------------------------------------------------------------
// Day 44 - DDR-style DRAM memory controller with FR-FCFS bank scheduling
//
// Accepts a stream of read/write transactions on a valid/ready port, splits
// them into per-bank transaction queues, and issues one DRAM command per cycle
// on a command bus (ACT / RD / WR / PRE / PREA / REF) while obeying a full set
// of JEDEC-style timing constraints.
//
// Scheduling policy: FR-FCFS (First-Ready, First-Come-First-Served)
//   tier 1  a column command (RD/WR) that HITS the currently open row
//   tier 2  an ACTIVATE for a bank that is precharged and has work
//   tier 3  a PRECHARGE of a bank whose open row no longer serves its oldest
//           request
// Within a tier the globally oldest candidate wins, compared with a wrap-safe
// modular age comparison, so a younger request can never permanently pass an
// older one at the same readiness level.
//
// A row-hit cap (ROW_HIT_CAP) closes the classic FR-FCFS starvation hole: a
// bank may serve at most that many consecutive row hits while an older request
// to a different row waits, after which the bank is forced to turn its row.
//
// Refresh is an all-bank blocking refresh: on the tREFI deadline the scheduler
// stops issuing, precharges everything, issues REF, and waits out tRFC.
//
// Ordering guarantee: two requests to the SAME address always complete in
// arrival order (same address implies same bank and same row, so they are
// always in the same tier and are then ordered by age).  Requests to different
// addresses may complete out of order; each carries an ID and is answered on a
// separate read-response / write-response channel.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module dram_fr_fcfs_ctrl #(
    // Geometry ---------------------------------------------------------------
    parameter int BANKS       = 4,   // DRAM banks (power of two)
    parameter int ROW_BITS    = 8,   // rows per bank = 2**ROW_BITS
    parameter int COL_BITS    = 6,   // columns per row = 2**COL_BITS
    parameter int DATA_W      = 32,  // data beat width
    parameter int ID_W        = 6,   // transaction ID width
    parameter int QDEPTH      = 8,   // transaction queue entries per bank
    parameter int ROW_HIT_CAP = 4,   // max consecutive row hits with work waiting
    // Timing, in controller clocks -------------------------------------------
    parameter int T_RCD   = 4,       // ACT -> column command, same bank
    parameter int T_RP    = 4,       // PRE -> ACT, same bank
    parameter int T_RAS   = 10,      // ACT -> PRE, same bank
    parameter int T_WR    = 4,       // WR  -> PRE, same bank (write recovery)
    parameter int T_CCD   = 2,       // column command -> column command
    parameter int T_RRD   = 3,       // ACT -> ACT, different banks
    parameter int T_FAW   = 14,      // rolling window holding at most four ACTs
    parameter int T_WTR   = 4,       // WR -> RD bus turnaround
    parameter int T_RTW   = 3,       // RD -> WR bus turnaround
    parameter int T_RFC   = 16,      // REF -> any command
    parameter int T_REFI  = 512,     // average refresh interval
    parameter int CAS_LAT = 5,       // device read latency (contract with the PHY)
    // Derived - do not override ----------------------------------------------
    parameter int BB     = (BANKS <= 1) ? 1 : $clog2(BANKS),
    parameter int ADDR_W = ROW_BITS + BB + COL_BITS,
    parameter int QCW    = $clog2(QDEPTH + 1)
) (
    input  logic                      clk,
    input  logic                      rst_n,

    // Request ingress --------------------------------------------------------
    input  logic                      req_valid_i,
    output logic                      req_ready_o,
    input  logic                      req_we_i,
    input  logic [ADDR_W-1:0]         req_addr_i,
    input  logic [DATA_W-1:0]         req_wdata_i,
    input  logic [ID_W-1:0]           req_id_i,

    // DRAM command bus (registered) -----------------------------------------
    output logic [2:0]                dram_cmd_o,
    output logic [BB-1:0]             dram_bank_o,
    output logic [ROW_BITS-1:0]       dram_row_o,
    output logic [COL_BITS-1:0]       dram_col_o,
    output logic [DATA_W-1:0]         dram_wdata_o,

    // DRAM read-data return (device drives it CAS_LAT cycles after RD) -------
    input  logic                      dram_rvalid_i,
    input  logic [DATA_W-1:0]         dram_rdata_i,

    // Read response channel --------------------------------------------------
    output logic                      r_valid_o,
    output logic [ID_W-1:0]           r_id_o,
    output logic [DATA_W-1:0]         r_data_o,

    // Write response channel -------------------------------------------------
    output logic                      b_valid_o,
    output logic [ID_W-1:0]           b_id_o,

    // Performance counters and debug ----------------------------------------
    output logic [31:0]               perf_row_hits_o,
    output logic [31:0]               perf_row_misses_o,
    output logic [31:0]               perf_acts_o,
    output logic [31:0]               perf_pres_o,
    output logic [31:0]               perf_refreshes_o,
    output logic [31:0]               perf_idle_o,
    output logic [BANKS-1:0]          dbg_bank_open_o,
    output logic [BANKS*ROW_BITS-1:0] dbg_open_row_o,
    output logic [BANKS*QCW-1:0]      dbg_occupancy_o,
    output logic                      dbg_ref_active_o
);

  // ---------------------------------------------------------------------------
  // Local sizes and encodings
  // ---------------------------------------------------------------------------
  localparam int QIW   = (QDEPTH <= 1) ? 1 : $clog2(QDEPTH);
  localparam int AGE_W = 8;                       // >= 2 * BANKS * QDEPTH
  localparam int RIDD  = 8;                       // outstanding read-ID FIFO
  localparam int RIDPW = $clog2(RIDD);
  localparam int RIDW  = $clog2(RIDD + 1);
  localparam int TCW   = 10;                      // timer width
  localparam int REFW  = $clog2(T_REFI + 1);
  localparam int FAWW  = (T_FAW <= 2) ? 2 : (T_FAW - 1);

  localparam logic [2:0] CMD_NOP  = 3'd0;
  localparam logic [2:0] CMD_ACT  = 3'd1;
  localparam logic [2:0] CMD_RD   = 3'd2;
  localparam logic [2:0] CMD_WR   = 3'd3;
  localparam logic [2:0] CMD_PRE  = 3'd4;
  localparam logic [2:0] CMD_PREA = 3'd5;
  localparam logic [2:0] CMD_REF  = 3'd6;

  localparam logic [1:0] R_IDLE = 2'd0;  // no refresh outstanding
  localparam logic [1:0] R_PRE  = 2'd1;  // waiting until an all-bank PRE is legal
  localparam logic [1:0] R_RP   = 2'd2;  // waiting out tRP after PREA
  localparam logic [1:0] R_RFC  = 2'd3;  // waiting out tRFC after REF

  // Wrap-safe "is a older than b" over the modulo-2**AGE_W age counter.  Valid
  // as long as fewer than 2**(AGE_W-1) requests are ever live at once.
  function automatic logic older(input logic [AGE_W-1:0] a,
                                 input logic [AGE_W-1:0] b);
    logic [AGE_W-1:0] diff;
    begin
      diff  = a - b;
      older = diff[AGE_W-1];
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Per-bank transaction queues.  Each is a collapsing queue, so entry 0 is
  // always that bank's oldest live request and per-bank age order is implicit
  // in the index; only cross-bank comparisons need the age field.
  // ---------------------------------------------------------------------------
  logic                 q_val [BANKS-1:0][QDEPTH-1:0];
  logic                 q_we  [BANKS-1:0][QDEPTH-1:0];
  logic [ROW_BITS-1:0]  q_row [BANKS-1:0][QDEPTH-1:0];
  logic [COL_BITS-1:0]  q_col [BANKS-1:0][QDEPTH-1:0];
  logic [DATA_W-1:0]    q_dat [BANKS-1:0][QDEPTH-1:0];
  logic [ID_W-1:0]      q_id  [BANKS-1:0][QDEPTH-1:0];
  logic [AGE_W-1:0]     q_age [BANKS-1:0][QDEPTH-1:0];
  logic [QCW-1:0]       q_cnt [BANKS-1:0];

  // Bank row-buffer state and per-bank timers.
  logic                 bnk_open   [BANKS-1:0];
  logic [ROW_BITS-1:0]  bnk_row    [BANKS-1:0];
  logic [TCW-1:0]       c_rcd      [BANKS-1:0];  // until a column command is legal
  logic [TCW-1:0]       c_rp       [BANKS-1:0];  // until ACT is legal
  logic [TCW-1:0]       c_ras      [BANKS-1:0];  // until PRE is legal (from ACT)
  logic [TCW-1:0]       c_wr       [BANKS-1:0];  // until PRE is legal (from WR)
  logic [QCW-1:0]       hit_streak [BANKS-1:0];  // consecutive hits since ACT

  // Channel-wide timers and refresh state.
  logic [TCW-1:0]       g_ccd, g_rrd, g_wtr, g_rtw, g_rfc;
  logic [FAWW-1:0]      act_hist;
  logic [REFW-1:0]      refi_cnt;
  logic [1:0]           ref_st;
  logic [AGE_W-1:0]     age_ctr;

  // Outstanding read IDs, returned strictly in issue order by the device.
  logic [ID_W-1:0]      rid_mem [RIDD-1:0];
  logic [RIDW-1:0]      rid_cnt;
  logic [RIDPW-1:0]     rid_rd, rid_wr;

  // ---------------------------------------------------------------------------
  // Address decode: {row, bank, col} with the bank field in the middle, so
  // consecutive cache lines spread across banks and expose bank parallelism.
  // ---------------------------------------------------------------------------
  logic [COL_BITS-1:0] req_col;
  logic [BB-1:0]       req_bnk;
  logic [ROW_BITS-1:0] req_row;

  always_comb begin
    req_col = req_addr_i[COL_BITS-1:0];
    req_bnk = req_addr_i[COL_BITS+BB-1:COL_BITS];
    req_row = req_addr_i[ADDR_W-1:COL_BITS+BB];
  end

  assign req_ready_o = (q_cnt[req_bnk] < QDEPTH[QCW-1:0]);
  wire   req_fire    = req_valid_i & req_ready_o;

  // ---------------------------------------------------------------------------
  // Per-bank candidate analysis
  // ---------------------------------------------------------------------------
  logic             has_any  [BANKS-1:0];
  logic             has_hit  [BANKS-1:0];  // a queued entry targets the open row
  logic [QIW-1:0]   hit_idx  [BANKS-1:0];  // oldest such entry
  logic [AGE_W-1:0] hit_age  [BANKS-1:0];
  logic             has_miss [BANKS-1:0];  // a queued entry targets another row
  logic             cap_stop [BANKS-1:0];  // row-hit cap reached, must turn row
  logic             need_act [BANKS-1:0];
  logic             need_pre [BANKS-1:0];

  always_comb begin
    for (int b = 0; b < BANKS; b++) begin
      has_any[b]  = (q_cnt[b] != '0);
      has_hit[b]  = 1'b0;
      hit_idx[b]  = '0;
      hit_age[b]  = '0;
      has_miss[b] = 1'b0;

      // Scanning downward leaves the LOWEST matching index latched, which is
      // the oldest hit for this bank.
      for (int i = QDEPTH - 1; i >= 0; i--) begin
        if (q_val[b][i]) begin
          if (bnk_open[b] && (q_row[b][i] == bnk_row[b])) begin
            has_hit[b] = 1'b1;
            hit_idx[b] = i[QIW-1:0];
            hit_age[b] = q_age[b][i];
          end else begin
            has_miss[b] = 1'b1;
          end
        end
      end

      cap_stop[b] = has_miss[b] && (hit_streak[b] >= ROW_HIT_CAP[QCW-1:0]);
      need_act[b] = has_any[b] && !bnk_open[b];
      need_pre[b] = bnk_open[b] && has_miss[b] && (!has_hit[b] || cap_stop[b]);
    end
  end

  // ---------------------------------------------------------------------------
  // tFAW: at most four ACTs inside any rolling T_FAW-cycle window.  act_hist
  // holds the previous T_FAW-1 cycles, so three earlier ACTs plus this one is
  // the limit.
  // ---------------------------------------------------------------------------
  logic [3:0] faw_cnt;
  logic       faw_ok;

  always_comb begin
    faw_cnt = 4'd0;
    for (int k = 0; k < FAWW; k++) begin
      if (act_hist[k]) faw_cnt = faw_cnt + 4'd1;
    end
    faw_ok = (faw_cnt < 4'd4);
  end

  // ---------------------------------------------------------------------------
  // Command selection - one command per cycle, FR-FCFS over three tiers
  // ---------------------------------------------------------------------------
  logic [2:0]          sel_cmd;
  logic [BB-1:0]       sel_bank;
  logic [ROW_BITS-1:0] sel_row;
  logic [COL_BITS-1:0] sel_col;
  logic [DATA_W-1:0]   sel_dat;
  logic [ID_W-1:0]     sel_id;
  logic                sel_pop;     // dequeue the selected bank entry
  logic [QIW-1:0]      sel_idx;
  logic                sel_first;   // this CAS is the first after its ACT

  logic                cand_v;
  logic [BB-1:0]       cand_b;
  logic [AGE_W-1:0]    cand_age;
  logic                cand_we;
  logic                entry_we;
  logic                legal;
  logic                all_quiet;
  logic                all_rp_done;

  always_comb begin
    sel_cmd   = CMD_NOP;
    sel_bank  = '0;
    sel_row   = '0;
    sel_col   = '0;
    sel_dat   = '0;
    sel_id    = '0;
    sel_pop   = 1'b0;
    sel_idx   = '0;
    sel_first = 1'b0;

    cand_v    = 1'b0;
    cand_b    = '0;
    cand_age  = '0;
    cand_we   = 1'b0;
    entry_we  = 1'b0;
    legal     = 1'b0;

    // Are all banks quiet enough (tRAS, tWR met) for an all-bank precharge?
    all_quiet = 1'b1;
    for (int b = 0; b < BANKS; b++) begin
      if ((c_ras[b] != '0) || (c_wr[b] != '0)) all_quiet = 1'b0;
    end
    // Has tRP elapsed on every bank after that precharge?
    all_rp_done = 1'b1;
    for (int b = 0; b < BANKS; b++) begin
      if (c_rp[b] != '0) all_rp_done = 1'b0;
    end

    if (ref_st == R_PRE) begin
      if (all_quiet) sel_cmd = CMD_PREA;
    end else if (ref_st == R_RP) begin
      if (all_rp_done) sel_cmd = CMD_REF;
    end else if (ref_st == R_IDLE) begin

      // -- tier 1: column command on an already-open row ----------------------
      for (int b = 0; b < BANKS; b++) begin
        if (has_hit[b] && !cap_stop[b] && (c_rcd[b] == '0) && (g_ccd == '0) &&
            (g_rfc == '0)) begin
          entry_we = q_we[b][hit_idx[b]];
          legal    = entry_we ? (g_rtw == '0)
                              : ((g_wtr == '0) && (rid_cnt < RIDD[RIDW-1:0]));
          if (legal && (!cand_v || older(hit_age[b], cand_age))) begin
            cand_v   = 1'b1;
            cand_b   = b[BB-1:0];
            cand_age = hit_age[b];
            cand_we  = entry_we;
          end
        end
      end

      if (cand_v) begin
        sel_cmd   = cand_we ? CMD_WR : CMD_RD;
        sel_bank  = cand_b;
        sel_idx   = hit_idx[cand_b];
        sel_row   = bnk_row[cand_b];
        sel_col   = q_col[cand_b][hit_idx[cand_b]];
        sel_dat   = q_dat[cand_b][hit_idx[cand_b]];
        sel_id    = q_id [cand_b][hit_idx[cand_b]];
        sel_pop   = 1'b1;
        sel_first = (hit_streak[cand_b] == '0);
      end else begin

        // -- tier 2: activate a precharged bank that has work -----------------
        for (int b = 0; b < BANKS; b++) begin
          if (need_act[b] && (c_rp[b] == '0) && (g_rrd == '0) && faw_ok &&
              (g_rfc == '0)) begin
            if (!cand_v || older(q_age[b][0], cand_age)) begin
              cand_v   = 1'b1;
              cand_b   = b[BB-1:0];
              cand_age = q_age[b][0];
            end
          end
        end

        if (cand_v) begin
          sel_cmd  = CMD_ACT;
          sel_bank = cand_b;
          sel_row  = q_row[cand_b][0];   // the oldest request picks the row
        end else begin

          // -- tier 3: precharge a bank that must turn its row ---------------
          for (int b = 0; b < BANKS; b++) begin
            if (need_pre[b] && (c_ras[b] == '0) && (c_wr[b] == '0) &&
                (g_rfc == '0)) begin
              if (!cand_v || older(q_age[b][0], cand_age)) begin
                cand_v   = 1'b1;
                cand_b   = b[BB-1:0];
                cand_age = q_age[b][0];
              end
            end
          end
          if (cand_v) begin
            sel_cmd  = CMD_PRE;
            sel_bank = cand_b;
          end
        end
      end
    end
  end

  wire do_act  = (sel_cmd == CMD_ACT);
  wire do_pre  = (sel_cmd == CMD_PRE);
  wire do_prea = (sel_cmd == CMD_PREA);
  wire do_rd   = (sel_cmd == CMD_RD);
  wire do_wr   = (sel_cmd == CMD_WR);
  wire do_ref  = (sel_cmd == CMD_REF);
  wire do_cas  = do_rd | do_wr;

  // ---------------------------------------------------------------------------
  // Queue update: collapse on dequeue, append on accept
  // ---------------------------------------------------------------------------
  logic [QCW-1:0] tail;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < BANKS; b++) begin
        q_cnt[b] <= '0;
        for (int i = 0; i < QDEPTH; i++) begin
          q_val[b][i] <= 1'b0;
          q_we [b][i] <= 1'b0;
          q_row[b][i] <= '0;
          q_col[b][i] <= '0;
          q_dat[b][i] <= '0;
          q_id [b][i] <= '0;
          q_age[b][i] <= '0;
        end
      end
      age_ctr <= '0;
    end else begin
      // Collapse the selected bank around the dequeued entry.  Every source
      // read below is of the pre-update value, so a single pass is correct.
      if (sel_pop) begin
        for (int i = 0; i < QDEPTH - 1; i++) begin
          if (i >= sel_idx) begin
            q_val[sel_bank][i] <= q_val[sel_bank][i+1];
            q_we [sel_bank][i] <= q_we [sel_bank][i+1];
            q_row[sel_bank][i] <= q_row[sel_bank][i+1];
            q_col[sel_bank][i] <= q_col[sel_bank][i+1];
            q_dat[sel_bank][i] <= q_dat[sel_bank][i+1];
            q_id [sel_bank][i] <= q_id [sel_bank][i+1];
            q_age[sel_bank][i] <= q_age[sel_bank][i+1];
          end
        end
        q_val[sel_bank][QDEPTH-1] <= 1'b0;
        q_cnt[sel_bank]           <= q_cnt[sel_bank] - 1'b1;
      end

      // Append at the post-collapse tail.  This comes after the shift above, so
      // it wins when both target the same slot.
      if (req_fire) begin
        tail = q_cnt[req_bnk];
        if (sel_pop && (sel_bank == req_bnk)) tail = tail - 1'b1;

        q_val[req_bnk][tail[QIW-1:0]] <= 1'b1;
        q_we [req_bnk][tail[QIW-1:0]] <= req_we_i;
        q_row[req_bnk][tail[QIW-1:0]] <= req_row;
        q_col[req_bnk][tail[QIW-1:0]] <= req_col;
        q_dat[req_bnk][tail[QIW-1:0]] <= req_wdata_i;
        q_id [req_bnk][tail[QIW-1:0]] <= req_id_i;
        q_age[req_bnk][tail[QIW-1:0]] <= age_ctr;

        q_cnt[req_bnk] <= tail + 1'b1;
        age_ctr        <= age_ctr + 1'b1;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Bank state, timers and the refresh FSM
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < BANKS; b++) begin
        bnk_open[b]   <= 1'b0;
        bnk_row[b]    <= '0;
        c_rcd[b]      <= '0;
        c_rp[b]       <= '0;
        c_ras[b]      <= '0;
        c_wr[b]       <= '0;
        hit_streak[b] <= '0;
      end
      g_ccd    <= '0;
      g_rrd    <= '0;
      g_wtr    <= '0;
      g_rtw    <= '0;
      g_rfc    <= '0;
      act_hist <= '0;
      refi_cnt <= T_REFI[REFW-1:0] - 1'b1;
      ref_st   <= R_IDLE;
    end else begin
      // Free-running countdown of every timer.
      for (int b = 0; b < BANKS; b++) begin
        if (c_rcd[b] != '0) c_rcd[b] <= c_rcd[b] - 1'b1;
        if (c_rp[b]  != '0) c_rp[b]  <= c_rp[b]  - 1'b1;
        if (c_ras[b] != '0) c_ras[b] <= c_ras[b] - 1'b1;
        if (c_wr[b]  != '0) c_wr[b]  <= c_wr[b]  - 1'b1;
      end
      if (g_ccd != '0) g_ccd <= g_ccd - 1'b1;
      if (g_rrd != '0) g_rrd <= g_rrd - 1'b1;
      if (g_wtr != '0) g_wtr <= g_wtr - 1'b1;
      if (g_rtw != '0) g_rtw <= g_rtw - 1'b1;
      if (g_rfc != '0) g_rfc <= g_rfc - 1'b1;

      act_hist <= {act_hist[FAWW-2:0], do_act};

      // Command effects.  These come after the decrements above and therefore
      // override them on the cycle a command issues.
      if (do_act) begin
        bnk_open[sel_bank]   <= 1'b1;
        bnk_row[sel_bank]    <= sel_row;
        c_rcd[sel_bank]      <= T_RCD[TCW-1:0] - 1'b1;
        c_ras[sel_bank]      <= T_RAS[TCW-1:0] - 1'b1;
        hit_streak[sel_bank] <= '0;
        g_rrd                <= T_RRD[TCW-1:0] - 1'b1;
      end

      if (do_pre) begin
        bnk_open[sel_bank] <= 1'b0;
        c_rp[sel_bank]     <= T_RP[TCW-1:0] - 1'b1;
      end

      if (do_prea) begin
        for (int b = 0; b < BANKS; b++) begin
          bnk_open[b] <= 1'b0;
          c_rp[b]     <= T_RP[TCW-1:0] - 1'b1;
        end
      end

      if (do_cas) begin
        g_ccd <= T_CCD[TCW-1:0] - 1'b1;
        if (hit_streak[sel_bank] != '1)
          hit_streak[sel_bank] <= hit_streak[sel_bank] + 1'b1;
        if (do_wr) begin
          c_wr[sel_bank] <= T_WR[TCW-1:0] - 1'b1;
          g_wtr          <= T_WTR[TCW-1:0] - 1'b1;
        end else begin
          g_rtw <= T_RTW[TCW-1:0] - 1'b1;
        end
      end

      if (do_ref) g_rfc <= T_RFC[TCW-1:0] - 1'b1;

      // Refresh interval and FSM.
      if (refi_cnt != '0) refi_cnt <= refi_cnt - 1'b1;
      else                refi_cnt <= T_REFI[REFW-1:0] - 1'b1;

      case (ref_st)
        R_IDLE:  if (refi_cnt == '0) ref_st <= R_PRE;
        R_PRE:   if (do_prea)        ref_st <= R_RP;
        R_RP:    if (do_ref)         ref_st <= R_RFC;
        R_RFC:   if (g_rfc == '0)    ref_st <= R_IDLE;
        default:                     ref_st <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Outstanding-read ID FIFO.  The device returns read data strictly in the
  // order the RD commands were issued, so a plain FIFO recovers the ID.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rid_cnt <= '0;
      rid_rd  <= '0;
      rid_wr  <= '0;
      for (int i = 0; i < RIDD; i++) rid_mem[i] <= '0;
    end else begin
      if (do_rd) begin
        rid_mem[rid_wr] <= sel_id;
        rid_wr          <= rid_wr + 1'b1;   // RIDD is a power of two: wraps
      end
      if (dram_rvalid_i) rid_rd <= rid_rd + 1'b1;

      case ({do_rd, dram_rvalid_i})
        2'b10:   rid_cnt <= rid_cnt + 1'b1;
        2'b01:   rid_cnt <= rid_cnt - 1'b1;
        default: rid_cnt <= rid_cnt;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Registered command bus and response channels
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      dram_cmd_o   <= CMD_NOP;
      dram_bank_o  <= '0;
      dram_row_o   <= '0;
      dram_col_o   <= '0;
      dram_wdata_o <= '0;
      b_valid_o    <= 1'b0;
      b_id_o       <= '0;
      r_valid_o    <= 1'b0;
      r_id_o       <= '0;
      r_data_o     <= '0;
    end else begin
      dram_cmd_o   <= sel_cmd;
      dram_bank_o  <= sel_bank;
      dram_row_o   <= sel_row;
      dram_col_o   <= sel_col;
      dram_wdata_o <= sel_dat;

      b_valid_o <= do_wr;
      if (do_wr) b_id_o <= sel_id;

      r_valid_o <= dram_rvalid_i;
      if (dram_rvalid_i) begin
        r_id_o   <= rid_mem[rid_rd];
        r_data_o <= dram_rdata_i;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Performance counters and debug fan-out.  A request is charged as a row miss
  // when it is the first column command after the ACT it caused, and as a row
  // hit otherwise.
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      perf_row_hits_o   <= '0;
      perf_row_misses_o <= '0;
      perf_acts_o       <= '0;
      perf_pres_o       <= '0;
      perf_refreshes_o  <= '0;
      perf_idle_o       <= '0;
    end else begin
      if (do_cas &&  sel_first) perf_row_misses_o <= perf_row_misses_o + 1'b1;
      if (do_cas && !sel_first) perf_row_hits_o   <= perf_row_hits_o + 1'b1;
      if (do_act)               perf_acts_o       <= perf_acts_o + 1'b1;
      if (do_pre || do_prea)    perf_pres_o       <= perf_pres_o + 1'b1;
      if (do_ref)               perf_refreshes_o  <= perf_refreshes_o + 1'b1;
      if (sel_cmd == CMD_NOP)   perf_idle_o       <= perf_idle_o + 1'b1;
    end
  end

  always_comb begin
    for (int b = 0; b < BANKS; b++) begin
      dbg_bank_open_o[b]                     = bnk_open[b];
      dbg_open_row_o[b*ROW_BITS +: ROW_BITS] = bnk_row[b];
      dbg_occupancy_o[b*QCW +: QCW]          = q_cnt[b];
    end
  end

  assign dbg_ref_active_o = (ref_st != R_IDLE);

endmodule
