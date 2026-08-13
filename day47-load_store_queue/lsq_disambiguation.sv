// ---------------------------------------------------------------------------
// Day 47 - Out-of-order load/store queue with store-to-load forwarding and
//          speculative memory disambiguation
//
// The memory pipeline of an out-of-order core.  Loads and stores are allocated
// into two age-ordered circular queues in program order at dispatch, execute in
// whatever order their addresses and data happen to arrive, and retire in
// program order.  Everything interesting comes from that middle step: a load
// may need a value that is sitting in the store queue rather than in memory,
// and it may need it before the machine even knows which addresses the older
// stores are going to touch.
//
// The three mechanisms this design implements:
//
//   * Store-to-load forwarding.  A load CAMs the store queue over exactly the
//     age window of stores older than itself, picks the YOUNGEST overlapping
//     one, and takes its data instead of memory's.  Age is a circular-pointer
//     comparison, not an index comparison - the whole point of the extra
//     pointer bits below.
//
//   * Forwarding failure -> replay.  Real forwarding networks only forward when
//     one store covers every byte the load wants and that store's data has
//     arrived.  A partial overlap (store writes 2 bytes of the 4 the load
//     reads) or a store whose data is still in flight cannot be forwarded, so
//     the load is put back to sleep and re-issued later.  Each sleeping load
//     remembers WHICH store blocked it and wakes on that store specifically,
//     rather than spinning every idle cycle.
//
//   * Speculative disambiguation + violation detection.  A load that reaches
//     execute while an older store still has no address does NOT wait for it -
//     it goes to memory and records a disambiguation barrier: the store-queue
//     pointer above which a later-resolving store would have invalidated it.
//     When a store's address finally arrives, it CAMs the load queue for
//     younger executed loads that overlap and sit above their barrier.  Those
//     loads read the wrong value; the oldest is reported as a memory-order
//     violation.
//
// The barrier is what makes the violation check exact rather than conservative.
// A load that forwarded from store P is only wrong if a store BETWEEN P and
// itself resolves onto the same bytes; a store older than P is correctly hidden
// by P and must not raise a violation.  Loads that had no unknown-address store
// above their source can never be violated at all, and the barrier arithmetic
// proves it without needing a separate speculation bit.
//
// Three same-cycle races are handled explicitly, because address resolution,
// data delivery and load execution are independent events on independent
// ports:
//
//   * Store address resolves in the same cycle a load is in S0.  The load's CAM
//     would read the stale (still-unknown) entry and speculate past a store
//     whose address is right there on the input pins - and the violation CAM
//     would not catch it either, because the load is not yet marked executed.
//     The address-generation input is bypassed into the CAM to close it.
//   * Store address resolves in the cycle a load is in S1.  Too late to bypass:
//     that load's forwarding decision was made last cycle against an entry that
//     has since changed.  Its writeback is killed and it replays.
//   * Store data arrives in the same cycle a load is in S0.  Bypassed as well,
//     purely so the load forwards instead of taking a pointless replay.
//
// Recovery from a violation is deliberately done twice over.  The LSU reports
// viol_valid_o so an external ROB can flush and redirect - which is what a real
// machine must do, since dependents of the bad load have already consumed it -
// AND it internally un-executes the offending load and every younger load, so
// that if no flush arrives the value delivered at commit is still correct.  The
// testbench exercises both recovery paths.
//
// The store queue drains committed stores to memory from its head, one per
// cycle, and stays a forwarding source until the entry is actually popped.
// Loads win the single memory port by default; the drain takes over when the
// store queue is full or has been waiting URGENT cycles, which is the only
// thing keeping a steady stream of loads from starving it.
//
// Simplifying assumptions, all of them documented in the README:
//   - one address-generation event per cycle (loads and stores share the port)
//   - single-cycle synchronous memory, always hits
//   - naturally aligned accesses described by a byte-enable mask
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module lsq_disambiguation #(
    parameter int LQ_DEPTH = 8,    // load queue entries (power of two)
    parameter int SQ_DEPTH = 8,    // store queue entries (power of two)
    parameter int ADDR_W   = 12,   // byte-address width
    parameter int DATA_W   = 32,   // data word width (multiple of 8)
    parameter int ROB_W    = 6,    // reorder-buffer tag width
    parameter int URGENT   = 3,    // drain-starvation threshold, in cycles
    // Derived - do not override ---------------------------------------------
    parameter int NB      = DATA_W / 8,
    parameter int LQ_AW   = (LQ_DEPTH <= 1) ? 1 : $clog2(LQ_DEPTH),
    parameter int SQ_AW   = (SQ_DEPTH <= 1) ? 1 : $clog2(SQ_DEPTH),
    parameter int LPTR_W  = LQ_AW + 2,          // two spare bits: see age math
    parameter int SPTR_W  = SQ_AW + 2,
    parameter int WOFF    = (NB <= 1) ? 1 : $clog2(NB),
    parameter int WADDR_W = ADDR_W - WOFF
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // -- Dispatch: in program order, one op per cycle ------------------------
    input  logic                  disp_valid_i,
    input  logic                  disp_is_store_i,
    input  logic [ROB_W-1:0]      disp_rob_i,
    output logic                  disp_lq_ready_o, // load queue has room
    output logic                  disp_sq_ready_o, // store queue has room
    output logic [LQ_AW-1:0]      disp_lq_idx_o,   // slot allocated this cycle
    output logic [SQ_AW-1:0]      disp_sq_idx_o,
    output logic [LPTR_W-1:0]     disp_lq_tail_o,  // pre-allocation pointers,
    output logic [SPTR_W-1:0]     disp_sq_tail_o,  //  for the ROB to checkpoint

    // -- Address generation (STA / load AGU), out of order -------------------
    input  logic                  ag_valid_i,
    input  logic                  ag_is_store_i,
    input  logic [SQ_AW-1:0]      ag_idx_i,        // LQ or SQ slot
    input  logic [ADDR_W-1:0]     ag_addr_i,
    input  logic [NB-1:0]         ag_be_i,

    // -- Store data (STD), out of order and independent of STA ---------------
    input  logic                  sd_valid_i,
    input  logic [SQ_AW-1:0]      sd_idx_i,
    input  logic [DATA_W-1:0]     sd_data_i,

    // -- Load writeback ------------------------------------------------------
    output logic                  ld_wb_valid_o,
    output logic [LQ_AW-1:0]      ld_wb_idx_o,
    output logic [ROB_W-1:0]      ld_wb_rob_o,
    output logic [DATA_W-1:0]     ld_wb_data_o,    // defined on ld_wb_be_o only
    output logic [NB-1:0]         ld_wb_be_o,
    output logic                  ld_wb_fwd_o,     // sourced from the SQ
    output logic                  ld_wb_spec_o,    // executed past an unknown store
    output logic                  ld_replay_o,     // put back to sleep instead
    output logic [1:0]            ld_replay_rsn_o, // RSN_* below

    // -- Memory-order violation ----------------------------------------------
    output logic                  viol_valid_o,
    output logic [LQ_AW-1:0]      viol_idx_o,
    output logic [ROB_W-1:0]      viol_rob_o,

    // -- Commit: in program order, from the ROB ------------------------------
    input  logic                  commit_load_i,
    input  logic                  commit_store_i,
    output logic                  lq_head_ready_o, // oldest load has a result
    output logic                  sq_head_ready_o, // oldest store has addr+data

    // -- Flush / rollback ----------------------------------------------------
    input  logic                  flush_i,
    input  logic [LPTR_W-1:0]     flush_lq_tail_i,
    input  logic [SPTR_W-1:0]     flush_sq_tail_i,

    // -- Data memory port (single cycle synchronous read) --------------------
    output logic                  dmem_req_o,
    output logic                  dmem_we_o,
    output logic [ADDR_W-1:0]     dmem_addr_o,
    output logic [NB-1:0]         dmem_be_o,
    output logic [DATA_W-1:0]     dmem_wdata_o,
    input  logic [DATA_W-1:0]     dmem_rdata_i,

    // -- Observability -------------------------------------------------------
    output logic [LPTR_W-1:0]     lq_cnt_o,
    output logic [SPTR_W-1:0]     sq_cnt_o,
    output logic [SPTR_W-1:0]     sq_uncommitted_o,
    output logic [31:0]           cnt_ld_exec_o,
    output logic [31:0]           cnt_fwd_o,
    output logic [31:0]           cnt_spec_o,
    output logic [31:0]           cnt_rp_partial_o,
    output logic [31:0]           cnt_rp_nodata_o,
    output logic [31:0]           cnt_rp_port_o,
    output logic [31:0]           cnt_rp_kill_o,
    output logic [31:0]           cnt_viol_o,
    output logic [31:0]           cnt_mem_rd_o,
    output logic [31:0]           cnt_mem_wr_o,
    output logic [31:0]           cnt_drain_urgent_o,
    output logic [31:0]           cnt_flush_o
);

    // Replay reasons -------------------------------------------------------
    localparam logic [1:0] RSN_NODATA  = 2'd0;  // covering store has no data yet
    localparam logic [1:0] RSN_PARTIAL = 2'd1;  // overlap, but not full coverage
    localparam logic [1:0] RSN_PORT    = 2'd2;  // lost the memory port to a drain
    localparam logic [1:0] RSN_KILL    = 2'd3;  // store address landed on top of S1

    // =====================================================================
    //  Queue state
    // =====================================================================
    logic                  lq_val   [LQ_DEPTH];
    logic                  lq_aval  [LQ_DEPTH];  // address known
    logic [WADDR_W-1:0]    lq_addr  [LQ_DEPTH];
    logic [NB-1:0]         lq_be    [LQ_DEPTH];
    logic [ROB_W-1:0]      lq_rob   [LQ_DEPTH];
    logic                  lq_exec  [LQ_DEPTH];  // has a committed-visible result
    logic [DATA_W-1:0]     lq_data  [LQ_DEPTH];
    logic                  lq_fwd   [LQ_DEPTH];
    logic                  lq_spec  [LQ_DEPTH];
    logic [SPTR_W-1:0]     lq_ord   [LQ_DEPTH];  // disambiguation barrier
    logic [SPTR_W-1:0]     lq_snap  [LQ_DEPTH];  // sq_tail at dispatch
    logic                  lq_rpend [LQ_DEPTH];  // waiting to re-issue
    logic [1:0]            lq_rrsn  [LQ_DEPTH];
    logic [SPTR_W-1:0]     lq_blk   [LQ_DEPTH];  // store that put it to sleep

    logic                  sq_val   [SQ_DEPTH];
    logic                  sq_aval  [SQ_DEPTH];
    logic                  sq_dval  [SQ_DEPTH];
    logic [WADDR_W-1:0]    sq_addr  [SQ_DEPTH];
    logic [NB-1:0]         sq_be    [SQ_DEPTH];
    logic [DATA_W-1:0]     sq_data  [SQ_DEPTH];

    logic [LPTR_W-1:0]     lq_head, lq_tail;
    logic [SPTR_W-1:0]     sq_head, sq_commit, sq_tail;

    logic [LPTR_W-1:0]     lq_cnt;
    logic [SPTR_W-1:0]     sq_cnt, sq_ucnt;

    assign lq_cnt  = lq_tail   - lq_head;
    assign sq_cnt  = sq_tail   - sq_head;
    assign sq_ucnt = sq_tail   - sq_commit;

    assign lq_cnt_o         = lq_cnt;
    assign sq_cnt_o         = sq_cnt;
    assign sq_uncommitted_o = sq_ucnt;

    wire lq_full = (lq_cnt == LPTR_W'(LQ_DEPTH));
    wire sq_full = (sq_cnt == SPTR_W'(SQ_DEPTH));

    wire [LQ_AW-1:0] lq_head_idx = lq_head[LQ_AW-1:0];
    wire [SQ_AW-1:0] sq_head_idx = sq_head[SQ_AW-1:0];
    wire [LQ_AW-1:0] lq_tail_idx = lq_tail[LQ_AW-1:0];
    wire [SQ_AW-1:0] sq_tail_idx = sq_tail[SQ_AW-1:0];

    // ---------------------------------------------------------------------
    //  Age arithmetic
    //
    //  Both pointers are free-running counters two bits wider than the index
    //  they carry.  For a resident entry, rel = ptr - head is its age rank:
    //  0 is the oldest.  The two spare bits exist so that a pointer which has
    //  fallen BEHIND the head (its entry already popped) produces a rel that
    //  is unambiguously larger than DEPTH instead of aliasing onto a legal
    //  rank - which is exactly the question the barrier check has to answer.
    // ---------------------------------------------------------------------
    function automatic [SPTR_W-1:0] s_rel(input logic [SPTR_W-1:0] p,
                                          input logic [SPTR_W-1:0] h);
        s_rel = p - h;
    endfunction

    // =====================================================================
    //  Dispatch
    // =====================================================================
    assign disp_lq_ready_o = !lq_full;
    assign disp_sq_ready_o = !sq_full;
    assign disp_lq_idx_o   = lq_tail_idx;
    assign disp_sq_idx_o   = sq_tail_idx;
    assign disp_lq_tail_o  = lq_tail;
    assign disp_sq_tail_o  = sq_tail;

    wire disp_fire  = disp_valid_i && !flush_i &&
                      (disp_is_store_i ? disp_sq_ready_o : disp_lq_ready_o);
    wire disp_ld    = disp_fire && !disp_is_store_i;
    wire disp_st    = disp_fire &&  disp_is_store_i;

    // =====================================================================
    //  Store-queue CAM for a load in S0
    //
    //  Walk the age window [sq_head, load.snap) from YOUNGEST to OLDEST.  The
    //  first overlapping store with a known address is the forwarding source;
    //  any unknown-address store seen before it is a store this load is about
    //  to speculate past.
    // =====================================================================
    logic                s0_val;
    logic [LQ_AW-1:0]    s0_idx;
    logic [WADDR_W-1:0]  s0_addr;
    logic [NB-1:0]       s0_be;
    logic [ROB_W-1:0]    s0_rob;
    logic [SPTR_W-1:0]   s0_snap;

    logic                cam_hit;     // some older store overlaps
    logic                cam_full;    // ... and covers every requested byte
    logic                cam_dval;    // ... and its data has arrived
    logic [DATA_W-1:0]   cam_data;
    logic [NB-1:0]       cam_be;
    logic [SPTR_W-1:0]   cam_ptr;     // pointer of the forwarding source
    logic                cam_unk;     // unknown-address store above the source

    always_comb begin : store_cam
        int unsigned older_n;
        int          p;
        logic [SQ_AW-1:0]   slot;
        logic [WADDR_W-1:0] e_addr;
        logic [NB-1:0]      e_be;
        logic [DATA_W-1:0]  e_data;
        logic               e_aval, e_dval, ovl;

        cam_hit  = 1'b0;
        cam_full = 1'b0;
        cam_dval = 1'b0;
        cam_data = '0;
        cam_be   = '0;
        cam_ptr  = '0;
        cam_unk  = 1'b0;

        older_n = int'(unsigned'(s0_snap - sq_head));

        for (p = SQ_DEPTH - 1; p >= 0; p = p - 1) begin
            if (s0_val && (p < older_n)) begin
                slot = sq_head_idx + SQ_AW'(p);

                // Same-cycle address-generation bypass: an STA landing on this
                // slot right now is architecturally older than the load, so the
                // CAM must see it even though the entry still reads "unknown".
                if (ag_valid_i && ag_is_store_i && (ag_idx_i == slot)) begin
                    e_aval = 1'b1;
                    e_addr = ag_addr_i[ADDR_W-1:WOFF];
                    e_be   = ag_be_i;
                end else begin
                    e_aval = sq_aval[slot];
                    e_addr = sq_addr[slot];
                    e_be   = sq_be[slot];
                end

                // Same-cycle store-data bypass: saves an otherwise pointless
                // RSN_NODATA replay when STD and the load collide.
                if (sd_valid_i && (sd_idx_i == slot)) begin
                    e_dval = 1'b1;
                    e_data = sd_data_i;
                end else begin
                    e_dval = sq_dval[slot];
                    e_data = sq_data[slot];
                end

                if (sq_val[slot]) begin
                    if (e_aval) begin
                        ovl = (e_addr == s0_addr) && ((e_be & s0_be) != {NB{1'b0}});
                        if (ovl && !cam_hit) begin
                            cam_hit  = 1'b1;
                            cam_full = ((e_be & s0_be) == s0_be);
                            cam_dval = e_dval;
                            cam_data = e_data;
                            cam_be   = e_be;
                            cam_ptr  = sq_head + SPTR_W'(p);
                        end
                    end else if (!cam_hit) begin
                        cam_unk = 1'b1;
                    end
                end
            end
        end
    end

    // Forwarding verdict ---------------------------------------------------
    wire cam_fwd_ok  = cam_hit && cam_full && cam_dval;
    wire cam_replay  = cam_hit && !cam_fwd_ok;
    wire cam_need_mem = !cam_fwd_ok;

    // Disambiguation barrier: the store-queue pointer at or above which a
    // later-resolving store invalidates this load.  With a forwarding source
    // it is one past that source; without one, every older store counts.
    wire [SPTR_W-1:0] s0_ord = cam_hit ? (cam_ptr + SPTR_W'(1)) : sq_head;

    // =====================================================================
    //  Replay wake-up: an asleep load re-issues only when the store that
    //  blocked it has actually changed state.
    // =====================================================================
    function automatic logic blk_woken(input logic [1:0]        rsn,
                                       input logic [SPTR_W-1:0] blk);
        logic [SPTR_W-1:0] rel;
        logic              resident;
        begin
            rel      = s_rel(blk, sq_head);
            resident = (rel < sq_cnt);
            case (rsn)
                // popped => the value is in memory now; data arrived => forwardable
                RSN_NODATA : blk_woken = !resident || sq_dval[blk[SQ_AW-1:0]] ||
                                         (sd_valid_i && (sd_idx_i == blk[SQ_AW-1:0]));
                RSN_PARTIAL: blk_woken = !resident;   // only a drain unblocks it
                default    : blk_woken = 1'b1;        // port loss / kill: retry at once
            endcase
        end
    endfunction

    logic             rp_val;
    logic [LQ_AW-1:0] rp_idx;

    always_comb begin : replay_pick
        int               q;
        logic [LQ_AW-1:0] slot;
        rp_val = 1'b0;
        rp_idx = '0;
        for (q = LQ_DEPTH - 1; q >= 0; q = q - 1) begin
            if (q < int'(unsigned'(lq_cnt))) begin
                slot = lq_head_idx + LQ_AW'(q);
                if (lq_val[slot] && lq_rpend[slot] && lq_aval[slot] &&
                    blk_woken(lq_rrsn[slot], lq_blk[slot])) begin
                    rp_val = 1'b1;          // loop runs youngest->oldest, so the
                    rp_idx = slot;          // last write wins: oldest ready load
                end
            end
        end
    end

    // =====================================================================
    //  S0 source select - a fresh AGU load beats a replay
    // =====================================================================
    wire ag_ld = ag_valid_i && !ag_is_store_i;
    wire ag_st = ag_valid_i &&  ag_is_store_i;

    wire [LQ_AW-1:0] ag_lq_idx = ag_idx_i[LQ_AW-1:0];

    always_comb begin : s0_select
        s0_val  = (ag_ld || rp_val) && !flush_i;
        s0_idx  = ag_ld ? ag_lq_idx : rp_idx;
        s0_addr = ag_ld ? ag_addr_i[ADDR_W-1:WOFF] : lq_addr[s0_idx];
        s0_be   = ag_ld ? ag_be_i                  : lq_be[s0_idx];
        s0_rob  = lq_rob[s0_idx];
        s0_snap = lq_snap[s0_idx];
    end

    // =====================================================================
    //  Memory port arbitration
    // =====================================================================
    wire               drain_req  = (sq_head != sq_commit);
    logic [7:0]        drain_wait;
    wire               drain_urg  = drain_req && (sq_full || (drain_wait >= 8'(URGENT)));

    wire               s0_wants_mem = s0_val && !cam_replay && cam_need_mem;
    wire               ld_gnt       = s0_wants_mem && !drain_urg;
    wire               st_gnt       = drain_req && (!s0_wants_mem || drain_urg);

    wire               s0_fire      = s0_val && !cam_replay && (!cam_need_mem || ld_gnt);
    wire               s0_lostport  = s0_val && !cam_replay && cam_need_mem && !ld_gnt;

    assign dmem_req_o   = st_gnt || ld_gnt;
    assign dmem_we_o    = st_gnt;
    assign dmem_addr_o  = st_gnt ? {sq_addr[sq_head_idx], {WOFF{1'b0}}}
                                 : {s0_addr,              {WOFF{1'b0}}};
    assign dmem_be_o    = st_gnt ? sq_be[sq_head_idx] : s0_be;
    assign dmem_wdata_o = sq_data[sq_head_idx];

    // =====================================================================
    //  S1 - result select and writeback
    // =====================================================================
    logic              s1_val;
    logic [LQ_AW-1:0]  s1_idx;
    logic [ROB_W-1:0]  s1_rob;
    logic [NB-1:0]     s1_be;
    logic [WADDR_W-1:0] s1_addr;
    logic              s1_fwd;
    logic [DATA_W-1:0] s1_fwd_data;
    logic [NB-1:0]     s1_fwd_be;
    logic              s1_spec;
    logic [SPTR_W-1:0] s1_ord;
    logic [SPTR_W-1:0] s1_snap;

    logic [DATA_W-1:0] s1_result;
    always_comb begin : result_mux
        int b;
        for (b = 0; b < NB; b = b + 1) begin
            s1_result[b*8 +: 8] = (s1_fwd && s1_fwd_be[b]) ? s1_fwd_data[b*8 +: 8]
                                                           : dmem_rdata_i[b*8 +: 8];
        end
    end

    // A store address that resolves while the load is in S1 arrives too late to
    // bypass: S1's forwarding decision was made against the pre-resolution
    // entry.  Kill the writeback and let the load replay against the truth.
    logic s1_kill;
    always_comb begin : s1_kill_check
        logic [SPTR_W-1:0] pos_s, ord_rel_raw, ord_rel;
        logic              older, ovl, above;

        s1_kill     = 1'b0;
        pos_s       = SPTR_W'(ag_idx_i - sq_head_idx) & SPTR_W'(SQ_DEPTH - 1);
        older       = (pos_s < s_rel(s1_snap, sq_head));
        ovl         = (ag_addr_i[ADDR_W-1:WOFF] == s1_addr) &&
                      ((ag_be_i & s1_be) != {NB{1'b0}});
        ord_rel_raw = s_rel(s1_ord, sq_head);
        ord_rel     = (ord_rel_raw > SPTR_W'(SQ_DEPTH)) ? '0 : ord_rel_raw;
        above       = (pos_s >= ord_rel);

        if (s1_val && ag_st && sq_val[ag_idx_i])
            s1_kill = older && ovl && above;
    end

    // A violation detected this cycle also invalidates any load still in S1 at
    // or below the victim in age, so its writeback must not be broadcast.
    wire [LPTR_W-1:0] viol_rank;   // driven by the violation CAM below
    wire [LPTR_W-1:0] s1_rank   = LPTR_W'(s1_idx - lq_head_idx) & LPTR_W'(LQ_DEPTH - 1);
    wire              s1_squash = viol_valid_o && (s1_rank >= viol_rank);

    wire s1_wb = s1_val && !s1_kill && !s1_squash && !flush_i;

    assign ld_wb_valid_o   = s1_wb;
    assign ld_wb_idx_o     = s1_idx;
    assign ld_wb_rob_o     = s1_rob;
    assign ld_wb_data_o    = s1_result;
    assign ld_wb_be_o      = s1_be;
    assign ld_wb_fwd_o     = s1_fwd;
    assign ld_wb_spec_o    = s1_spec;

    wire s0_replay_now = s0_val && (cam_replay || s0_lostport);
    wire [1:0] s0_replay_rsn = cam_replay ? (!cam_full ? RSN_PARTIAL : RSN_NODATA)
                                          : RSN_PORT;

    assign ld_replay_o     = (s0_replay_now || (s1_val && s1_kill)) && !flush_i;
    assign ld_replay_rsn_o = s0_replay_now ? s0_replay_rsn : RSN_KILL;

    // =====================================================================
    //  Violation CAM - a resolving store against younger executed loads
    // =====================================================================
    logic             viol_hit;
    logic [LQ_AW-1:0] viol_slot;

    always_comb begin : violation_cam
        int                q;
        logic [LQ_AW-1:0]  slot;
        logic [SPTR_W-1:0] pos_s, ord_rel_raw, ord_rel;
        logic              older, ovl, above;

        viol_hit  = 1'b0;
        viol_slot = '0;

        pos_s = SPTR_W'(ag_idx_i - sq_head_idx) & SPTR_W'(SQ_DEPTH - 1);

        for (q = LQ_DEPTH - 1; q >= 0; q = q - 1) begin
            if (ag_st && sq_val[ag_idx_i] && (q < int'(unsigned'(lq_cnt)))) begin
                slot = lq_head_idx + LQ_AW'(q);
                if (lq_val[slot] && lq_exec[slot] && lq_aval[slot]) begin
                    older = (pos_s < s_rel(lq_snap[slot], sq_head));
                    ovl   = (ag_addr_i[ADDR_W-1:WOFF] == lq_addr[slot]) &&
                            ((ag_be_i & lq_be[slot]) != {NB{1'b0}});

                    ord_rel_raw = s_rel(lq_ord[slot], sq_head);
                    ord_rel     = (ord_rel_raw > SPTR_W'(SQ_DEPTH)) ? '0 : ord_rel_raw;
                    above       = (pos_s >= ord_rel);

                    if (older && ovl && above) begin
                        viol_hit  = 1'b1;   // youngest->oldest scan, last write
                        viol_slot = slot;   // wins: report the OLDEST victim
                    end
                end
            end
        end
    end

    assign viol_valid_o = viol_hit && !flush_i;
    assign viol_idx_o   = viol_slot;
    assign viol_rob_o   = lq_rob[viol_slot];

    // Rank of the reported victim, so the squash can un-execute it and
    // everything younger in the same cycle it is detected.
    assign viol_rank = LPTR_W'(viol_slot - lq_head_idx) & LPTR_W'(LQ_DEPTH - 1);

    // =====================================================================
    //  Commit / head status
    // =====================================================================
    assign lq_head_ready_o = (lq_cnt != '0) && lq_val[lq_head_idx] && lq_exec[lq_head_idx];
    assign sq_head_ready_o = (sq_ucnt != '0) && sq_val[sq_commit[SQ_AW-1:0]] &&
                             sq_aval[sq_commit[SQ_AW-1:0]] && sq_dval[sq_commit[SQ_AW-1:0]];

    // =====================================================================
    //  Sequential state
    // =====================================================================
    integer i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lq_head <= '0;  lq_tail <= '0;
            sq_head <= '0;  sq_commit <= '0;  sq_tail <= '0;
            drain_wait <= '0;
            s1_val <= 1'b0;
            s1_idx <= '0;  s1_rob <= '0;  s1_be <= '0;  s1_addr <= '0;
            s1_fwd <= 1'b0;  s1_fwd_data <= '0;  s1_fwd_be <= '0;
            s1_spec <= 1'b0;  s1_ord <= '0;  s1_snap <= '0;
            for (i = 0; i < LQ_DEPTH; i = i + 1) begin
                lq_val[i]   <= 1'b0; lq_aval[i] <= 1'b0; lq_addr[i] <= '0;
                lq_be[i]    <= '0;   lq_rob[i]  <= '0;   lq_exec[i] <= 1'b0;
                lq_data[i]  <= '0;   lq_fwd[i]  <= 1'b0; lq_spec[i] <= 1'b0;
                lq_ord[i]   <= '0;   lq_snap[i] <= '0;   lq_rpend[i]<= 1'b0;
                lq_rrsn[i]  <= 2'd0; lq_blk[i]  <= '0;
            end
            for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                sq_val[i]  <= 1'b0; sq_aval[i] <= 1'b0; sq_dval[i] <= 1'b0;
                sq_addr[i] <= '0;   sq_be[i]   <= '0;   sq_data[i] <= '0;
            end
            cnt_ld_exec_o <= '0; cnt_fwd_o <= '0; cnt_spec_o <= '0;
            cnt_rp_partial_o <= '0; cnt_rp_nodata_o <= '0; cnt_rp_port_o <= '0;
            cnt_rp_kill_o <= '0; cnt_viol_o <= '0;
            cnt_mem_rd_o <= '0; cnt_mem_wr_o <= '0;
            cnt_drain_urgent_o <= '0; cnt_flush_o <= '0;
        end else begin
            // ---- pipeline register ---------------------------------------
            s1_val <= s0_fire;
            if (s0_fire) begin
                s1_idx      <= s0_idx;
                s1_rob      <= s0_rob;
                s1_be       <= s0_be;
                s1_addr     <= s0_addr;
                s1_snap     <= s0_snap;
                s1_fwd      <= cam_fwd_ok;
                s1_fwd_data <= cam_data;
                s1_fwd_be   <= cam_be;
                s1_spec     <= cam_unk;
                s1_ord      <= s0_ord;
            end

            // ---- dispatch: allocate in program order ----------------------
            if (disp_ld) begin
                lq_val  [lq_tail_idx] <= 1'b1;
                lq_aval [lq_tail_idx] <= 1'b0;
                lq_exec [lq_tail_idx] <= 1'b0;
                lq_rpend[lq_tail_idx] <= 1'b0;
                lq_fwd  [lq_tail_idx] <= 1'b0;
                lq_spec [lq_tail_idx] <= 1'b0;
                lq_rob  [lq_tail_idx] <= disp_rob_i;
                lq_snap [lq_tail_idx] <= sq_tail;      // age boundary
                lq_ord  [lq_tail_idx] <= sq_tail;
                lq_be   [lq_tail_idx] <= '0;
                lq_tail               <= lq_tail + LPTR_W'(1);
            end
            if (disp_st) begin
                sq_val  [sq_tail_idx] <= 1'b1;
                sq_aval [sq_tail_idx] <= 1'b0;
                sq_dval [sq_tail_idx] <= 1'b0;
                sq_be   [sq_tail_idx] <= '0;
                sq_tail               <= sq_tail + SPTR_W'(1);
            end

            // ---- address generation --------------------------------------
            if (ag_valid_i && !flush_i) begin
                if (ag_is_store_i) begin
                    sq_aval[ag_idx_i] <= 1'b1;
                    sq_addr[ag_idx_i] <= ag_addr_i[ADDR_W-1:WOFF];
                    sq_be  [ag_idx_i] <= ag_be_i;
                end else begin
                    lq_aval[ag_lq_idx] <= 1'b1;
                    lq_addr[ag_lq_idx] <= ag_addr_i[ADDR_W-1:WOFF];
                    lq_be  [ag_lq_idx] <= ag_be_i;
                end
            end

            // ---- store data ----------------------------------------------
            if (sd_valid_i && !flush_i) begin
                sq_dval[sd_idx_i] <= 1'b1;
                sq_data[sd_idx_i] <= sd_data_i;
            end

            // ---- S0 outcome: either the load advances, or it sleeps -------
            if (s0_replay_now && !flush_i) begin
                lq_rpend[s0_idx] <= 1'b1;
                lq_rrsn [s0_idx] <= s0_replay_rsn;
                lq_blk  [s0_idx] <= cam_replay ? cam_ptr : sq_head;
                case (s0_replay_rsn)
                    RSN_PARTIAL: cnt_rp_partial_o <= cnt_rp_partial_o + 32'd1;
                    RSN_NODATA : cnt_rp_nodata_o  <= cnt_rp_nodata_o  + 32'd1;
                    default    : cnt_rp_port_o    <= cnt_rp_port_o    + 32'd1;
                endcase
            end else if (s0_fire) begin
                lq_rpend[s0_idx] <= 1'b0;
            end

            // ---- S1 writeback --------------------------------------------
            if (s1_val && !flush_i) begin
                if (s1_kill) begin
                    lq_rpend[s1_idx] <= 1'b1;
                    lq_rrsn [s1_idx] <= RSN_KILL;
                    lq_blk  [s1_idx] <= sq_head;
                    lq_exec [s1_idx] <= 1'b0;
                    cnt_rp_kill_o    <= cnt_rp_kill_o + 32'd1;
                end else if (!s1_squash) begin
                    lq_exec[s1_idx] <= 1'b1;
                    lq_data[s1_idx] <= s1_result;
                    lq_fwd [s1_idx] <= s1_fwd;
                    lq_spec[s1_idx] <= s1_spec;
                    lq_ord [s1_idx] <= s1_ord;
                    cnt_ld_exec_o   <= cnt_ld_exec_o + 32'd1;
                    if (s1_fwd)  cnt_fwd_o  <= cnt_fwd_o  + 32'd1;
                    if (s1_spec) cnt_spec_o <= cnt_spec_o + 32'd1;
                end
            end

            // ---- violation squash (must beat the S1 writeback above) ------
            if (viol_valid_o) begin
                cnt_viol_o <= cnt_viol_o + 32'd1;
                for (i = 0; i < LQ_DEPTH; i = i + 1) begin
                    if (lq_val[i] &&
                        (LPTR_W'(LQ_AW'(i) - lq_head_idx) & LPTR_W'(LQ_DEPTH-1)) >= viol_rank &&
                        (LPTR_W'(LQ_AW'(i) - lq_head_idx) & LPTR_W'(LQ_DEPTH-1)) <  lq_cnt) begin
                        if (lq_exec[i] || lq_rpend[i]) begin
                            lq_exec [i] <= 1'b0;
                            lq_rpend[i] <= lq_aval[i];
                            lq_rrsn [i] <= RSN_KILL;
                            lq_blk  [i] <= sq_head;
                        end
                    end
                end
                // an in-flight load in that window is stale too
                if (s1_val) begin
                    if ((LPTR_W'(s1_idx - lq_head_idx) & LPTR_W'(LQ_DEPTH-1)) >= viol_rank) begin
                        lq_exec [s1_idx] <= 1'b0;
                        lq_rpend[s1_idx] <= 1'b1;
                        lq_rrsn [s1_idx] <= RSN_KILL;
                        lq_blk  [s1_idx] <= sq_head;
                    end
                end
            end

            // ---- commit ---------------------------------------------------
            if (commit_load_i) begin
                lq_val[lq_head_idx] <= 1'b0;
                lq_head             <= lq_head + LPTR_W'(1);
            end
            if (commit_store_i) begin
                sq_commit <= sq_commit + SPTR_W'(1);
            end

            // ---- store drain ----------------------------------------------
            if (st_gnt) begin
                sq_val[sq_head_idx] <= 1'b0;
                sq_head             <= sq_head + SPTR_W'(1);
                drain_wait          <= '0;
                cnt_mem_wr_o        <= cnt_mem_wr_o + 32'd1;
                if (drain_urg) cnt_drain_urgent_o <= cnt_drain_urgent_o + 32'd1;
            end else if (drain_req) begin
                if (drain_wait != 8'hFF) drain_wait <= drain_wait + 8'd1;
            end else begin
                drain_wait <= '0;
            end

            if (ld_gnt) cnt_mem_rd_o <= cnt_mem_rd_o + 32'd1;

            // ---- flush: restore the checkpointed tails ---------------------
            if (flush_i) begin
                lq_tail <= flush_lq_tail_i;
                sq_tail <= flush_sq_tail_i;
                s1_val  <= 1'b0;
                cnt_flush_o <= cnt_flush_o + 32'd1;
                for (i = 0; i < LQ_DEPTH; i = i + 1) begin
                    if ((LPTR_W'(LQ_AW'(i) - lq_head_idx) & LPTR_W'(LQ_DEPTH-1)) >=
                        (flush_lq_tail_i - lq_head)) begin
                        lq_val[i]   <= 1'b0;
                        lq_rpend[i] <= 1'b0;
                        lq_exec[i]  <= 1'b0;
                    end else if (lq_val[i] && lq_aval[i] && !lq_exec[i]) begin
                        // A surviving load that has an address but no result is
                        // one whose S0/S1 pass the flush just killed - S0 had
                        // already cleared its replay bit on the way in.  Without
                        // this it would sit valid and addressed forever: the
                        // replay arbiter only looks at replay-pending entries,
                        // and its address generation has already happened.
                        lq_rpend[i] <= 1'b1;
                        lq_rrsn [i] <= RSN_KILL;
                        lq_blk  [i] <= sq_head;
                    end
                end
                for (i = 0; i < SQ_DEPTH; i = i + 1) begin
                    if ((SPTR_W'(SQ_AW'(i) - sq_head_idx) & SPTR_W'(SQ_DEPTH-1)) >=
                        (flush_sq_tail_i - sq_head)) begin
                        sq_val[i]  <= 1'b0;
                        sq_aval[i] <= 1'b0;
                        sq_dval[i] <= 1'b0;
                    end
                end
                // a drain in flight this cycle is a committed store: keep it
                if (st_gnt) begin
                    sq_val[sq_head_idx] <= 1'b0;
                    sq_head             <= sq_head + SPTR_W'(1);
                end
            end
        end
    end

endmodule
