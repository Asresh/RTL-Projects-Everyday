// ---------------------------------------------------------------------------
// Day 44 - self-checking testbench for the FR-FCFS DRAM memory controller
//
// Three independent checkers run against the DUT:
//
//   1. A DRAM DEVICE MODEL that snoops the command bus, maintains the real
//      bank/row state and the memory array, and asserts on ANY violated timing
//      constraint (tRCD, tRP, tRAS, tWR, tCCD, tRRD, tFAW, tWTR, tRTW, tRFC)
//      or illegal command (CAS to a closed bank, ACT on an open bank, REF with
//      a bank still open).  It returns read data CAS_LAT cycles after each RD.
//
//   2. A GOLDEN MEMORY updated in strict request-arrival order.  Every read is
//      snapshotted against it at the moment the request is accepted, so any
//      same-address reordering by the scheduler shows up as a data mismatch.
//
//   3. A RESPONSE SCOREBOARD keyed by transaction ID, which also proves that
//      no response is duplicated, invented, or lost.
//
// Stimulus: directed phases for row-hit streaks, row thrash, bank parallelism,
// read/write turnaround, backpressure, refresh and starvation bounding, then a
// long randomized soak.  A watchdog bounds the whole run.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

// ===========================================================================
// DRAM device model + protocol/timing checker
// ===========================================================================
module dram_device_model #(
    parameter int BANKS    = 4,
    parameter int ROW_BITS = 8,
    parameter int COL_BITS = 6,
    parameter int DATA_W   = 32,
    parameter int T_RCD    = 4,
    parameter int T_RP     = 4,
    parameter int T_RAS    = 10,
    parameter int T_WR     = 4,
    parameter int T_CCD    = 2,
    parameter int T_RRD    = 3,
    parameter int T_FAW    = 14,
    parameter int T_WTR    = 4,
    parameter int T_RTW    = 3,
    parameter int T_RFC    = 16,
    parameter int CAS_LAT  = 5,
    parameter int BB       = (BANKS <= 1) ? 1 : $clog2(BANKS)
) (
    input  logic                clk,
    input  logic                rst_n,
    input  logic [2:0]          cmd_i,
    input  logic [BB-1:0]       bank_i,
    input  logic [ROW_BITS-1:0] row_i,
    input  logic [COL_BITS-1:0] col_i,
    input  logic [DATA_W-1:0]   wdata_i,
    output logic                rvalid_o,
    output logic [DATA_W-1:0]   rdata_o,
    output int                  viol_o
);

  localparam int MEM_W  = ROW_BITS + BB + COL_BITS;
  localparam int MEM_SZ = 1 << MEM_W;
  localparam int NEVER  = -1000;

  localparam logic [2:0] CMD_NOP  = 3'd0;
  localparam logic [2:0] CMD_ACT  = 3'd1;
  localparam logic [2:0] CMD_RD   = 3'd2;
  localparam logic [2:0] CMD_WR   = 3'd3;
  localparam logic [2:0] CMD_PRE  = 3'd4;
  localparam logic [2:0] CMD_PREA = 3'd5;
  localparam logic [2:0] CMD_REF  = 3'd6;

  logic [DATA_W-1:0] mem [MEM_SZ-1:0];

  logic              open  [BANKS-1:0];
  logic [ROW_BITS-1:0] orow [BANKS-1:0];
  int                t_act  [BANKS-1:0];   // last ACT on this bank
  int                t_pre  [BANKS-1:0];   // last PRE on this bank
  int                t_wr_b [BANKS-1:0];   // last WR on this bank

  int                t_act_any, t_pre_any, t_cas_any, t_rd_any, t_wr_any, t_ref;
  int                act_win [3:0];        // circular history of the last 4 ACTs
  int                act_wp;
  int                cyc;
  int                viol;

  logic [DATA_W-1:0] pipe_d [CAS_LAT-1:0];
  logic              pipe_v [CAS_LAT-1:0];

  assign viol_o   = viol;
  assign rvalid_o = pipe_v[CAS_LAT-1];
  assign rdata_o  = pipe_d[CAS_LAT-1];

  function automatic int addr_of(input int b, input int r, input int c);
    addr_of = (r << (BB + COL_BITS)) | (b << COL_BITS) | c;
  endfunction

  task automatic fail(input string what);
    begin
      viol = viol + 1;
      $display("[%0t] DEVICE VIOLATION (cycle %0d): %s", $time, cyc, what);
    end
  endtask

  initial begin
    for (int i = 0; i < MEM_SZ; i++) mem[i] = '0;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cyc       <= 0;
      viol      <= 0;
      t_act_any <= NEVER;
      t_pre_any <= NEVER;
      t_cas_any <= NEVER;
      t_rd_any  <= NEVER;
      t_wr_any  <= NEVER;
      t_ref     <= NEVER;
      act_wp    <= 0;
      for (int i = 0; i < 4; i++) act_win[i] <= NEVER;
      for (int b = 0; b < BANKS; b++) begin
        open[b]   <= 1'b0;
        orow[b]   <= '0;
        t_act[b]  <= NEVER;
        t_pre[b]  <= NEVER;
        t_wr_b[b] <= NEVER;
      end
      for (int i = 0; i < CAS_LAT; i++) begin
        pipe_v[i] <= 1'b0;
        pipe_d[i] <= '0;
      end
    end else begin
      cyc <= cyc + 1;

      for (int i = CAS_LAT - 1; i > 0; i--) begin
        pipe_v[i] <= pipe_v[i-1];
        pipe_d[i] <= pipe_d[i-1];
      end
      pipe_v[0] <= 1'b0;
      pipe_d[0] <= '0;

      // Anything at all must respect tRFC after a refresh.
      if ((cmd_i != CMD_NOP) && ((cyc - t_ref) < T_RFC))
        fail($sformatf("cmd %0d only %0d cycles after REF (tRFC=%0d)",
                       cmd_i, cyc - t_ref, T_RFC));

      case (cmd_i)
        CMD_ACT: begin
          if (open[bank_i])
            fail($sformatf("ACT on bank %0d which is already active", bank_i));
          if ((cyc - t_pre[bank_i]) < T_RP)
            fail($sformatf("ACT bank %0d only %0d cycles after PRE (tRP=%0d)",
                           bank_i, cyc - t_pre[bank_i], T_RP));
          if ((cyc - t_act_any) < T_RRD)
            fail($sformatf("ACT bank %0d only %0d cycles after previous ACT (tRRD=%0d)",
                           bank_i, cyc - t_act_any, T_RRD));
          if ((cyc - act_win[act_wp]) < T_FAW)
            fail($sformatf("fifth ACT inside %0d cycles (tFAW=%0d)",
                           cyc - act_win[act_wp], T_FAW));

          open[bank_i]   <= 1'b1;
          orow[bank_i]   <= row_i;
          t_act[bank_i]  <= cyc;
          t_act_any      <= cyc;
          act_win[act_wp] <= cyc;
          act_wp         <= (act_wp + 1) % 4;
        end

        CMD_RD, CMD_WR: begin
          if (!open[bank_i])
            fail($sformatf("column command to precharged bank %0d", bank_i));
          else begin
            if (row_i !== orow[bank_i])
              fail($sformatf("column command bank %0d row %0d but row %0d is open",
                             bank_i, row_i, orow[bank_i]));
            if ((cyc - t_act[bank_i]) < T_RCD)
              fail($sformatf("column command bank %0d only %0d cycles after ACT (tRCD=%0d)",
                             bank_i, cyc - t_act[bank_i], T_RCD));
          end
          if ((cyc - t_cas_any) < T_CCD)
            fail($sformatf("column command only %0d cycles after previous one (tCCD=%0d)",
                           cyc - t_cas_any, T_CCD));
          if ((cmd_i == CMD_RD) && ((cyc - t_wr_any) < T_WTR))
            fail($sformatf("RD only %0d cycles after WR (tWTR=%0d)",
                           cyc - t_wr_any, T_WTR));
          if ((cmd_i == CMD_WR) && ((cyc - t_rd_any) < T_RTW))
            fail($sformatf("WR only %0d cycles after RD (tRTW=%0d)",
                           cyc - t_rd_any, T_RTW));

          t_cas_any <= cyc;
          if (cmd_i == CMD_RD) begin
            t_rd_any  <= cyc;
            pipe_v[0] <= 1'b1;
            pipe_d[0] <= mem[addr_of(bank_i, orow[bank_i], col_i)];
          end else begin
            t_wr_any        <= cyc;
            t_wr_b[bank_i]  <= cyc;
            mem[addr_of(bank_i, orow[bank_i], col_i)] <= wdata_i;
          end
        end

        CMD_PRE: begin
          if (!open[bank_i])
            fail($sformatf("PRE on bank %0d which is already precharged", bank_i));
          if ((cyc - t_act[bank_i]) < T_RAS)
            fail($sformatf("PRE bank %0d only %0d cycles after ACT (tRAS=%0d)",
                           bank_i, cyc - t_act[bank_i], T_RAS));
          if ((cyc - t_wr_b[bank_i]) < T_WR)
            fail($sformatf("PRE bank %0d only %0d cycles after WR (tWR=%0d)",
                           bank_i, cyc - t_wr_b[bank_i], T_WR));
          open[bank_i]  <= 1'b0;
          t_pre[bank_i] <= cyc;
          t_pre_any     <= cyc;
        end

        CMD_PREA: begin
          for (int b = 0; b < BANKS; b++) begin
            if (open[b]) begin
              if ((cyc - t_act[b]) < T_RAS)
                fail($sformatf("PREA with bank %0d only %0d cycles after ACT (tRAS=%0d)",
                               b, cyc - t_act[b], T_RAS));
              if ((cyc - t_wr_b[b]) < T_WR)
                fail($sformatf("PREA with bank %0d only %0d cycles after WR (tWR=%0d)",
                               b, cyc - t_wr_b[b], T_WR));
            end
            open[b]  <= 1'b0;
            t_pre[b] <= cyc;
          end
          t_pre_any <= cyc;
        end

        CMD_REF: begin
          for (int b = 0; b < BANKS; b++)
            if (open[b]) fail($sformatf("REF while bank %0d is still active", b));
          if ((cyc - t_pre_any) < T_RP)
            fail($sformatf("REF only %0d cycles after PRE (tRP=%0d)",
                           cyc - t_pre_any, T_RP));
          t_ref <= cyc;
        end

        default: ; // NOP
      endcase
    end
  end
endmodule


// ===========================================================================
// Testbench
// ===========================================================================
module tb_dram_fr_fcfs_ctrl;

  localparam int BANKS       = 4;
  localparam int ROW_BITS    = 8;
  localparam int COL_BITS    = 6;
  localparam int DATA_W      = 32;
  localparam int ID_W        = 6;
  localparam int QDEPTH      = 8;
  localparam int ROW_HIT_CAP = 4;

  localparam int T_RCD   = 4;
  localparam int T_RP    = 4;
  localparam int T_RAS   = 10;
  localparam int T_WR    = 4;
  localparam int T_CCD   = 2;
  localparam int T_RRD   = 3;
  localparam int T_FAW   = 14;
  localparam int T_WTR   = 4;
  localparam int T_RTW   = 3;
  localparam int T_RFC   = 16;
  localparam int T_REFI  = 512;
  localparam int CAS_LAT = 5;

  localparam int BB     = $clog2(BANKS);
  localparam int ADDR_W = ROW_BITS + BB + COL_BITS;
  localparam int QCW    = $clog2(QDEPTH + 1);
  localparam int NIDS   = 1 << ID_W;
  localparam int TIMEOUT = 400000;

  // ---------------------------------------------------------------------------
  // Clock, counters
  // ---------------------------------------------------------------------------
  logic clk;
  logic rst_n;

  initial clk = 1'b0;
  always #5 clk = ~clk;

  int cycle;
  always @(posedge clk) cycle <= cycle + 1;

  int errors;
  int seed;
  int nreq, nresp_r, nresp_b;

  // Phase marker, dumped so the figure generator can find each stimulus phase.
  logic [7:0] phase;

  int unsigned rnd_state;
  function automatic int unsigned rnd(input int unsigned m);
    rnd_state = rnd_state * 32'd1103515245 + 32'd12345;
    rnd = ((rnd_state >> 16) & 32'h0000_7FFF) % m;
  endfunction

  task automatic err(input string msg);
    begin
      errors = errors + 1;
      $display("[%0t] ERROR (cycle %0d): %s", $time, cycle, msg);
      if (errors > 25) begin
        $display("RESULT: *** FAIL *** (too many errors)");
        $finish;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // DUT + device model
  // ---------------------------------------------------------------------------
  logic                req_valid, req_we;
  logic                req_ready;
  logic [ADDR_W-1:0]   req_addr;
  logic [DATA_W-1:0]   req_wdata;
  logic [ID_W-1:0]     req_id;

  logic [2:0]          dram_cmd;
  logic [BB-1:0]       dram_bank;
  logic [ROW_BITS-1:0] dram_row;
  logic [COL_BITS-1:0] dram_col;
  logic [DATA_W-1:0]   dram_wdata;
  logic                dram_rvalid;
  logic [DATA_W-1:0]   dram_rdata;

  logic                r_valid, b_valid;
  logic [ID_W-1:0]     r_id, b_id;
  logic [DATA_W-1:0]   r_data;

  logic [31:0] perf_row_hits, perf_row_misses, perf_acts, perf_pres;
  logic [31:0] perf_refreshes, perf_idle;
  logic [BANKS-1:0]          dbg_bank_open;
  logic [BANKS*ROW_BITS-1:0] dbg_open_row;
  logic [BANKS*QCW-1:0]      dbg_occupancy;
  logic                      dbg_ref_active;

  int dev_viol;

  dram_fr_fcfs_ctrl #(
      .BANKS(BANKS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .DATA_W(DATA_W),
      .ID_W(ID_W), .QDEPTH(QDEPTH), .ROW_HIT_CAP(ROW_HIT_CAP),
      .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_WR(T_WR), .T_CCD(T_CCD),
      .T_RRD(T_RRD), .T_FAW(T_FAW), .T_WTR(T_WTR), .T_RTW(T_RTW),
      .T_RFC(T_RFC), .T_REFI(T_REFI), .CAS_LAT(CAS_LAT)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .req_valid_i(req_valid), .req_ready_o(req_ready), .req_we_i(req_we),
      .req_addr_i(req_addr), .req_wdata_i(req_wdata), .req_id_i(req_id),
      .dram_cmd_o(dram_cmd), .dram_bank_o(dram_bank), .dram_row_o(dram_row),
      .dram_col_o(dram_col), .dram_wdata_o(dram_wdata),
      .dram_rvalid_i(dram_rvalid), .dram_rdata_i(dram_rdata),
      .r_valid_o(r_valid), .r_id_o(r_id), .r_data_o(r_data),
      .b_valid_o(b_valid), .b_id_o(b_id),
      .perf_row_hits_o(perf_row_hits), .perf_row_misses_o(perf_row_misses),
      .perf_acts_o(perf_acts), .perf_pres_o(perf_pres),
      .perf_refreshes_o(perf_refreshes), .perf_idle_o(perf_idle),
      .dbg_bank_open_o(dbg_bank_open), .dbg_open_row_o(dbg_open_row),
      .dbg_occupancy_o(dbg_occupancy), .dbg_ref_active_o(dbg_ref_active)
  );

  dram_device_model #(
      .BANKS(BANKS), .ROW_BITS(ROW_BITS), .COL_BITS(COL_BITS), .DATA_W(DATA_W),
      .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_WR(T_WR), .T_CCD(T_CCD),
      .T_RRD(T_RRD), .T_FAW(T_FAW), .T_WTR(T_WTR), .T_RTW(T_RTW),
      .T_RFC(T_RFC), .CAS_LAT(CAS_LAT)
  ) u_dev (
      .clk(clk), .rst_n(rst_n),
      .cmd_i(dram_cmd), .bank_i(dram_bank), .row_i(dram_row), .col_i(dram_col),
      .wdata_i(dram_wdata),
      .rvalid_o(dram_rvalid), .rdata_o(dram_rdata), .viol_o(dev_viol)
  );

  // ---------------------------------------------------------------------------
  // Golden memory and response scoreboard
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] gmem [(1<<ADDR_W)-1:0];

  logic              id_busy  [NIDS-1:0];
  logic              id_is_wr [NIDS-1:0];
  logic [DATA_W-1:0] id_exp   [NIDS-1:0];
  int                id_addr  [NIDS-1:0];
  int                id_cyc   [NIDS-1:0];   // arrival cycle, for latency bounds
  int                outstanding;
  int                next_id;
  int                worst_lat;

  // Read responses
  always @(posedge clk) begin
    if (rst_n && r_valid) begin
      if (!id_busy[r_id])
        err($sformatf("read response for id %0d which is not outstanding", r_id));
      else if (id_is_wr[r_id])
        err($sformatf("read response for id %0d which was a write", r_id));
      else begin
        if (r_data !== id_exp[r_id])
          err($sformatf("read id %0d addr 0x%0h: got 0x%08h expected 0x%08h",
                        r_id, id_addr[r_id], r_data, id_exp[r_id]));
        if ((cycle - id_cyc[r_id]) > worst_lat) worst_lat = cycle - id_cyc[r_id];
        id_busy[r_id] = 1'b0;
        outstanding   = outstanding - 1;
        nresp_r       = nresp_r + 1;
      end
    end
  end

  // Write responses
  always @(posedge clk) begin
    if (rst_n && b_valid) begin
      if (!id_busy[b_id])
        err($sformatf("write response for id %0d which is not outstanding", b_id));
      else if (!id_is_wr[b_id])
        err($sformatf("write response for id %0d which was a read", b_id));
      else begin
        if ((cycle - id_cyc[b_id]) > worst_lat) worst_lat = cycle - id_cyc[b_id];
        id_busy[b_id] = 1'b0;
        outstanding   = outstanding - 1;
        nresp_b       = nresp_b + 1;
      end
    end
  end

  // Device-model violations are fatal to the run's verdict.
  int dev_viol_seen;
  always @(posedge clk) begin
    if (rst_n && (dev_viol != dev_viol_seen)) begin
      errors        = errors + (dev_viol - dev_viol_seen);
      dev_viol_seen = dev_viol;
    end
  end

  // ---------------------------------------------------------------------------
  // Stimulus helpers
  // ---------------------------------------------------------------------------
  function automatic int mk_addr(input int bank, input int row, input int col);
    mk_addr = (row << (BB + COL_BITS)) | (bank << COL_BITS) | col;
  endfunction

  // Allocate an ID that is not already in flight.
  task automatic alloc_id(output int id);
    begin
      id = -1;
      while (id < 0) begin
        if (!id_busy[next_id]) id = next_id;
        next_id = (next_id + 1) % NIDS;
        if (id < 0) @(posedge clk);
      end
    end
  endtask

  // Issue one request and snapshot the golden model at the acceptance cycle.
  task automatic push(input bit we, input int addr, input logic [DATA_W-1:0] wd);
    int id;
    begin
      alloc_id(id);
      @(negedge clk);
      req_valid = 1'b1;
      req_we    = we;
      req_addr  = addr[ADDR_W-1:0];
      req_wdata = wd;
      req_id    = id[ID_W-1:0];
      @(posedge clk);
      while (!req_ready) begin
        @(negedge clk);
        @(posedge clk);
      end
      // Accepted on this edge - update the golden model in arrival order.
      id_busy[id]  = 1'b1;
      id_is_wr[id] = we;
      id_addr[id]  = addr;
      id_cyc[id]   = cycle;
      if (we) begin
        gmem[addr] = wd;
        id_exp[id] = wd;
      end else begin
        id_exp[id] = gmem[addr];
      end
      outstanding = outstanding + 1;
      nreq        = nreq + 1;
      @(negedge clk);
      req_valid = 1'b0;
    end
  endtask

  task automatic idle_cycles(input int n);
    begin
      @(negedge clk);
      req_valid = 1'b0;
      repeat (n) @(posedge clk);
    end
  endtask

  task automatic drain(input string what);
    int guard;
    begin
      guard = 0;
      @(negedge clk);
      req_valid = 1'b0;
      while (outstanding != 0) begin
        @(posedge clk);
        guard = guard + 1;
        if (guard > 20000) begin
          err($sformatf("drain timeout in %s with %0d outstanding", what, outstanding));
          return;
        end
      end
      repeat (4) @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test phases
  // ---------------------------------------------------------------------------
  int snap_hits, snap_acts, snap_pres, snap_refs;
  int lat_id, lat_start;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    rnd_state = 32'h1234_5678 + 32'(seed) * 32'd2654435761;

    $dumpfile("dram_fr_fcfs_ctrl.vcd");
    $dumpvars(0, tb_dram_fr_fcfs_ctrl);

    errors = 0; nreq = 0; nresp_r = 0; nresp_b = 0;
    outstanding = 0; next_id = 0; worst_lat = 0; dev_viol_seen = 0;
    phase = 8'd0;
    req_valid = 1'b0; req_we = 1'b0; req_addr = '0; req_wdata = '0; req_id = '0;

    for (int i = 0; i < NIDS; i++) begin
      id_busy[i]  = 1'b0;
      id_is_wr[i] = 1'b0;
      id_exp[i]   = '0;
      id_addr[i]  = 0;
      id_cyc[i]   = 0;
    end
    for (int i = 0; i < (1 << ADDR_W); i++) gmem[i] = '0;

    $display("=========================================================");
    $display(" Day 44 - FR-FCFS DRAM memory controller");
    $display("  BANKS=%0d ROWS=%0d COLS=%0d QDEPTH=%0d CAP=%0d seed=%0d",
             BANKS, 1 << ROW_BITS, 1 << COL_BITS, QDEPTH, ROW_HIT_CAP, seed);
    $display("  tRCD=%0d tRP=%0d tRAS=%0d tWR=%0d tCCD=%0d tRRD=%0d tFAW=%0d",
             T_RCD, T_RP, T_RAS, T_WR, T_CCD, T_RRD, T_FAW);
    $display("  tWTR=%0d tRTW=%0d tRFC=%0d tREFI=%0d CL=%0d",
             T_WTR, T_RTW, T_RFC, T_REFI, CAS_LAT);
    $display("=========================================================");

    // -- reset ---------------------------------------------------------------
    rst_n = 1'b0;
    repeat (6) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);

    if (dram_cmd !== 3'd0) err("command bus not idle out of reset");
    if (r_valid || b_valid) err("a response was asserted out of reset");
    if (dbg_bank_open !== '0) err("a bank was open out of reset");

    // -- phase 1: a single write then read-back ------------------------------
    phase = 8'd1;
    push(1'b1, mk_addr(0, 3, 7), 32'hCAFE_0001);
    drain("phase 1 write");
    push(1'b0, mk_addr(0, 3, 7), 32'h0);
    drain("phase 1 read");
    if (nresp_r != 1 || nresp_b != 1)
      err("phase 1 did not produce exactly one read and one write response");

    // -- phase 2: row-hit streak, then a forced row turn (waveform region) ---
    // Bank 1 / row 5, four reads that all hit the same open row, then one read
    // to bank 1 / row 9 that must precharge and re-activate.
    phase = 8'd2;
    snap_hits = perf_row_hits;
    snap_acts = perf_acts;
    snap_pres = perf_pres;
    idle_cycles(4);
    for (int c = 0; c < 4; c++) push(1'b0, mk_addr(1, 5, c), 32'h0);
    push(1'b0, mk_addr(1, 9, 0), 32'h0);
    drain("phase 2");
    if ((perf_acts - snap_acts) != 2)
      err($sformatf("phase 2 expected exactly 2 ACTs, saw %0d", perf_acts - snap_acts));
    if ((perf_pres - snap_pres) != 1)
      err($sformatf("phase 2 expected exactly 1 PRE, saw %0d", perf_pres - snap_pres));
    if ((perf_row_hits - snap_hits) != 3)
      err($sformatf("phase 2 expected 3 row hits, saw %0d", perf_row_hits - snap_hits));

    // -- phase 3: bank parallelism -------------------------------------------
    // One request per bank, all to different rows.  The scheduler should
    // overlap the four activations rather than serialize four full round trips.
    phase = 8'd3;
    idle_cycles(4);
    snap_acts = perf_acts;
    lat_start = cycle;
    for (int b = 0; b < BANKS; b++) push(1'b0, mk_addr(b, 16 + b, b), 32'h0);
    drain("phase 3");
    if ((perf_acts - snap_acts) != BANKS)
      err($sformatf("phase 3 expected %0d ACTs, saw %0d", BANKS, perf_acts - snap_acts));
    // Four serialized misses would cost at least 4*(tRP+tRCD+CL); overlapping
    // them must beat that comfortably.
    if ((cycle - lat_start) >= (BANKS * (T_RP + T_RCD + CAS_LAT)))
      err($sformatf("phase 3 took %0d cycles - banks were not overlapped",
                    cycle - lat_start));

    // -- phase 4: read/write turnaround and write visibility -----------------
    phase = 8'd4;
    idle_cycles(4);
    for (int c = 0; c < 6; c++) begin
      push(1'b1, mk_addr(2, 33, c), 32'hA000_0000 + c);
      push(1'b0, mk_addr(2, 33, c), 32'h0);
    end
    drain("phase 4");

    // -- phase 5: fill every queue, exercise backpressure --------------------
    phase = 8'd5;
    idle_cycles(2);
    for (int i = 0; i < BANKS * QDEPTH; i++)
      push(1'b1, mk_addr(i % BANKS, 40 + (i / BANKS), i % (1 << COL_BITS)),
           32'hB000_0000 + i);
    for (int i = 0; i < BANKS * QDEPTH; i++)
      push(1'b0, mk_addr(i % BANKS, 40 + (i / BANKS), i % (1 << COL_BITS)),
           32'h0);
    drain("phase 5");
    if (dbg_occupancy !== '0) err("queues not empty after phase 5 drained");

    // -- phase 6: refresh ----------------------------------------------------
    // Sit idle long enough that at least one tREFI deadline fires, then prove
    // the controller still serves traffic correctly afterwards.
    phase = 8'd6;
    snap_refs = perf_refreshes;
    idle_cycles(T_REFI + T_RFC + 4 * T_RP + 40);
    if (perf_refreshes == snap_refs)
      err("no refresh was issued across a full tREFI interval");
    push(1'b0, mk_addr(3, 3, 3), 32'h0);
    push(1'b1, mk_addr(3, 3, 3), 32'hDEAD_BEEF);
    push(1'b0, mk_addr(3, 3, 3), 32'h0);
    drain("phase 6");

    // -- phase 7: starvation bound -------------------------------------------
    // Park one old request on bank 0 / row 200, then hammer bank 0 / row 100
    // with row hits.  The row-hit cap must force the row to turn, so the old
    // request has to complete within a bounded number of cycles.
    phase = 8'd7;
    idle_cycles(4);
    push(1'b0, mk_addr(0, 100, 0), 32'h0);   // opens row 100
    drain("phase 7 warmup");
    alloc_id(lat_id);
    push(1'b0, mk_addr(0, 200, 0), 32'h0);   // the victim: a different row
    lat_id    = -1;
    lat_start = cycle;
    for (int i = 0; i < 24; i++) begin
      push(1'b0, mk_addr(0, 100, i % (1 << COL_BITS)), 32'h0);
      if (outstanding > (QDEPTH - 2)) idle_cycles(2);
    end
    drain("phase 7");
    if ((cycle - lat_start) > 600)
      err($sformatf("phase 7: victim request starved for %0d cycles",
                    cycle - lat_start));

    // -- phase 8: randomized soak --------------------------------------------
    phase = 8'd8;
    idle_cycles(4);
    for (int i = 0; i < 1200; i++) begin
      int b, r, c, a;
      bit we;
      // A skewed row choice keeps row hits and row misses both common.
      b  = rnd(BANKS);
      r  = (rnd(100) < 60) ? rnd(4) : rnd(1 << ROW_BITS);
      c  = rnd(1 << COL_BITS);
      we = (rnd(100) < 45);
      a  = mk_addr(b, r, c);
      push(we, a, 32'hC0DE_0000 + i);
      if (rnd(100) < 12) idle_cycles(1 + rnd(6));
    end
    drain("phase 8");

    // -- phase 9: full memory comparison -------------------------------------
    phase = 8'd9;
    begin
      int mismatches;
      mismatches = 0;
      for (int a = 0; a < (1 << ADDR_W); a++) begin
        if (u_dev.mem[a] !== gmem[a]) begin
          if (mismatches < 5)
            err($sformatf("memory mismatch at 0x%0h: device 0x%08h golden 0x%08h",
                          a, u_dev.mem[a], gmem[a]));
          mismatches = mismatches + 1;
        end
      end
      if (mismatches == 0)
        $display("[%0t] backdoor memory compare over %0d words: clean",
                 $time, 1 << ADDR_W);
    end

    if (nreq != (nresp_r + nresp_b))
      err($sformatf("%0d requests but %0d responses", nreq, nresp_r + nresp_b));
    if (outstanding != 0)
      err($sformatf("%0d requests never answered", outstanding));

    $display("---------------------------------------------------------");
    $display(" requests %0d  (reads %0d, writes %0d)", nreq, nresp_r, nresp_b);
    $display(" row hits %0d  row misses %0d  hit rate %0d%%",
             perf_row_hits, perf_row_misses,
             (perf_row_hits * 100) / ((perf_row_hits + perf_row_misses) == 0 ?
                                       1 : (perf_row_hits + perf_row_misses)));
    $display(" ACT %0d  PRE %0d  REF %0d  idle cmd slots %0d",
             perf_acts, perf_pres, perf_refreshes, perf_idle);
    $display(" worst request latency %0d cycles, device violations %0d",
             worst_lat, dev_viol);
    $display("---------------------------------------------------------");

    if (errors == 0) $display("RESULT: *** PASS ***");
    else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Watchdog
  // ---------------------------------------------------------------------------
  initial begin
    repeat (TIMEOUT) @(posedge clk);
    $display("[%0t] watchdog expired in phase %0d with %0d outstanding",
             $time, phase, outstanding);
    $display("RESULT: *** FAIL *** (timeout)");
    $finish;
  end

endmodule
