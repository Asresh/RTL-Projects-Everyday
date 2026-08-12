// ---------------------------------------------------------------------------
// Day 45 - MESI snooping cache-coherence complex (multi-core, cache-to-cache)
//
// A complete shared-memory coherence subsystem: NUM_CORES write-back,
// write-allocate L1 data caches, each holding a MESI state per line, tied
// together by an atomic snooping bus with round-robin arbitration and a single
// backing-memory port.
//
// The protocol is textbook MESI with the optimisations that make it worth
// building in hardware:
//
//   * E (Exclusive-clean).  A read miss with no other sharer fills in E, so the
//     subsequent store upgrades E->M *silently* - zero bus traffic.  This is the
//     whole reason MESI exists instead of MSI, and the testbench measures it.
//   * BusUpgr.  A store that hits a shared line needs permission, not data, so
//     it issues an invalidate-only transaction: no memory read, no line move.
//   * Cache-to-cache intervention.  If a snooped line is dirty in another
//     cache, that cache supplies it directly off the bus (C2C_LAT cycles) and
//     the bus flushes it to memory in the same transaction, instead of paying a
//     full memory read latency.
//
// Coherence invariants the design maintains, and the testbench checks every
// cycle:
//     I1  at most one cache holds a given line in M or E
//     I2  if any cache holds a line in M or E, it is the ONLY valid copy
//     I3  memory is stale for a line only while some cache holds it in M
//
// The two races that make snooping protocols hard are handled explicitly,
// because a cache can sit for many cycles between deciding what it wants and
// actually winning the bus:
//
//   * Upgrade race.  Two caches both hold a line in S and both store to it in
//     the same cycle.  Both request BusUpgr; the arbiter picks one, whose
//     transaction invalidates the loser's copy.  The loser must NOT go on to
//     issue its BusUpgr - it no longer has the line, so an invalidate-only
//     transaction would leave it claiming M over stale data.  It detects the
//     lost copy while still waiting for grant and promotes its own request to
//     BusRdX (perf_upgr_race_o).
//   * Writeback race.  A cache waiting for the bus to write back a dirty
//     victim gets snooped on that very line, supplies it by intervention, and
//     the bus flushes it to memory.  The pending writeback is now redundant, so
//     it is cancelled rather than issued (perf_wb_cancel_o).
//
// The bus is atomic: exactly one transaction is in flight, so no snoop can
// interleave with a granted transaction and every state change is ordered by
// the arbiter.  That is what makes the protocol verifiable; a split-transaction
// bus would need a separate conflict/retry layer on top of this same FSM.
//
// Replacement is invalid-ways-first, then round-robin per set.  Dirty victims
// are written back; clean victims (S or E) are dropped silently, which is legal
// precisely because I3 says memory is already up to date for them.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

// ===========================================================================
//  One core's write-back / write-allocate L1 data cache with MESI states
// ===========================================================================
module mesi_l1_cache #(
    parameter int SETS       = 8,    // sets per cache (power of two)
    parameter int WAYS       = 2,    // associativity
    parameter int LINE_WORDS = 4,    // words per coherence line (power of two)
    parameter int DATA_W     = 32,   // word width
    parameter int TAG_W      = 4,    // address tag bits
    // Derived - do not override ---------------------------------------------
    parameter int SIDX   = (SETS <= 1) ? 1 : $clog2(SETS),
    parameter int WOFF   = (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS),
    parameter int WSEL   = (WAYS <= 1) ? 1 : $clog2(WAYS),
    parameter int ADDR_W = TAG_W + SIDX + WOFF,
    parameter int LADDR_W= TAG_W + SIDX,
    parameter int LINE_W = LINE_WORDS * DATA_W
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // Core port (single outstanding request) ---------------------------------
    input  logic                          core_req_valid_i,
    output logic                          core_req_ready_o,
    input  logic                          core_we_i,
    input  logic [ADDR_W-1:0]             core_addr_i,
    input  logic [DATA_W-1:0]             core_wdata_i,
    output logic                          core_resp_valid_o,
    output logic [DATA_W-1:0]             core_rdata_o,

    // Bus request side ------------------------------------------------------
    output logic                          bus_req_o,
    output logic [1:0]                    bus_cmd_o,
    output logic [LADDR_W-1:0]            bus_line_o,
    output logic [LINE_W-1:0]             bus_wdata_o,   // victim line on BUSWB
    input  logic                          bus_gnt_i,

    // Snoop broadcast (driven by the bus for the transaction in flight) ------
    input  logic                          snp_valid_i,
    input  logic [1:0]                    snp_cmd_i,
    input  logic [LADDR_W-1:0]            snp_line_i,
    input  logic                          snp_isme_i,    // I am the requester
    input  logic                          snp_commit_i,  // apply the transition
    output logic                          snp_hit_o,     // I hold a valid copy
    output logic                          snp_dirty_o,   // ... and it is dirty
    output logic [LINE_W-1:0]             snp_data_o,    // intervention data

    // Fill / completion for my own transaction ------------------------------
    input  logic                          fill_valid_i,
    input  logic [LINE_W-1:0]             fill_data_i,
    input  logic                          fill_shared_i, // other sharers exist
    input  logic                          xact_done_i,

    // Observability ---------------------------------------------------------
    output logic [SETS*WAYS*2-1:0]        dbg_state_o,
    output logic [SETS*WAYS*TAG_W-1:0]    dbg_tag_o,
    output logic [3:0]                    dbg_fsm_o,
    output logic [31:0]                   perf_hits_o,
    output logic [31:0]                   perf_misses_o,
    output logic [31:0]                   perf_silent_upgr_o,
    output logic [31:0]                   perf_upgr_race_o,
    output logic [31:0]                   perf_wb_cancel_o
);

    // MESI line states
    localparam logic [1:0] ST_I = 2'd0;
    localparam logic [1:0] ST_S = 2'd1;
    localparam logic [1:0] ST_E = 2'd2;
    localparam logic [1:0] ST_M = 2'd3;

    // Bus commands
    localparam logic [1:0] BUSRD   = 2'd0;  // read, want a shareable copy
    localparam logic [1:0] BUSRDX  = 2'd1;  // read for ownership
    localparam logic [1:0] BUSUPGR = 2'd2;  // invalidate only, I already have data
    localparam logic [1:0] BUSWB   = 2'd3;  // write back a dirty victim

    // Core FSM
    localparam logic [3:0] C_IDLE = 4'd0;
    localparam logic [3:0] C_LOOK = 4'd1;
    localparam logic [3:0] C_WB   = 4'd2;
    localparam logic [3:0] C_REQ  = 4'd3;
    localparam logic [3:0] C_WAIT = 4'd4;
    localparam logic [3:0] C_RESP = 4'd5;

    // -----------------------------------------------------------------------
    // Tag / state / data arrays
    // -----------------------------------------------------------------------
    logic [1:0]        state_q [SETS][WAYS];
    logic [TAG_W-1:0]  tag_q   [SETS][WAYS];
    logic [LINE_W-1:0] data_q  [SETS][WAYS];
    logic [WSEL-1:0]   rr_q    [SETS];       // round-robin victim pointer

    // -----------------------------------------------------------------------
    // Latched core request
    // -----------------------------------------------------------------------
    logic [3:0]        fsm_q;
    logic              rq_we_q;
    logic [TAG_W-1:0]  rq_tag_q;
    logic [SIDX-1:0]   rq_set_q;
    logic [WOFF-1:0]   rq_off_q;
    logic [DATA_W-1:0] rq_wdata_q;
    logic [DATA_W-1:0] rd_q;
    logic [1:0]        rq_cmd_q;
    logic [WSEL-1:0]   rq_way_q;      // fill / upgrade target way
    logic [WSEL-1:0]   wb_way_q;
    logic [TAG_W-1:0]  wb_tag_q;
    logic              wait_wb_q;     // the granted transaction is my writeback
    logic [LINE_W-1:0] line_nx;       // combinational temp for the fill merge

    logic [31:0] hits_q, misses_q, sil_q, race_q, wbc_q;

    // -----------------------------------------------------------------------
    // Address split of the incoming core address
    // -----------------------------------------------------------------------
    logic [TAG_W-1:0] in_tag;
    logic [SIDX-1:0]  in_set;
    logic [WOFF-1:0]  in_off;
    always_comb begin
        in_off = core_addr_i[WOFF-1:0];
        in_set = core_addr_i[WOFF+SIDX-1:WOFF];
        in_tag = core_addr_i[ADDR_W-1:WOFF+SIDX];
    end

    // -----------------------------------------------------------------------
    // Lookup for the latched request
    // -----------------------------------------------------------------------
    logic            look_hit;
    logic [WSEL-1:0] look_way;
    logic [1:0]      look_state;
    logic            look_free;      // an invalid way exists
    logic [WSEL-1:0] look_free_way;

    always_comb begin
        look_hit      = 1'b0;
        look_way      = '0;
        look_state    = ST_I;
        look_free     = 1'b0;
        look_free_way = '0;
        for (int w = WAYS - 1; w >= 0; w--) begin
            if (state_q[rq_set_q][w] != ST_I && tag_q[rq_set_q][w] == rq_tag_q) begin
                look_hit   = 1'b1;
                look_way   = w[WSEL-1:0];
                look_state = state_q[rq_set_q][w];
            end
            if (state_q[rq_set_q][w] == ST_I) begin
                look_free     = 1'b1;
                look_free_way = w[WSEL-1:0];
            end
        end
    end

    logic [WSEL-1:0] victim_way;
    assign victim_way = look_free ? look_free_way : rr_q[rq_set_q];

    // -----------------------------------------------------------------------
    // Snoop lookup - combinational read of the registered arrays
    // -----------------------------------------------------------------------
    logic [TAG_W-1:0] snp_tag;
    logic [SIDX-1:0]  snp_set;
    logic             snp_match;
    logic [WSEL-1:0]  snp_way;
    logic [1:0]       snp_state;

    always_comb begin
        snp_set   = snp_line_i[SIDX-1:0];
        snp_tag   = snp_line_i[LADDR_W-1:SIDX];
        snp_match = 1'b0;
        snp_way   = '0;
        snp_state = ST_I;
        for (int w = WAYS - 1; w >= 0; w--) begin
            if (state_q[snp_set][w] != ST_I && tag_q[snp_set][w] == snp_tag) begin
                snp_match = 1'b1;
                snp_way   = w[WSEL-1:0];
                snp_state = state_q[snp_set][w];
            end
        end
    end

    // A cache never snoops itself: the requester's own copy is updated by the
    // fill path, not by the invalidate path.
    logic snoop_active;
    assign snoop_active = snp_valid_i && !snp_isme_i && snp_match;

    always_comb begin
        snp_hit_o   = snoop_active;
        snp_dirty_o = snoop_active && (snp_state == ST_M);
        snp_data_o  = data_q[snp_set][snp_way];
    end

    // Does my pending-request line still exist in my cache?  Used to catch the
    // upgrade race, and to cancel a writeback whose victim was snooped away.
    logic own_copy_valid, wb_still_dirty;
    always_comb begin
        own_copy_valid = (state_q[rq_set_q][rq_way_q] != ST_I) &&
                         (tag_q[rq_set_q][rq_way_q] == rq_tag_q);
        wb_still_dirty = (state_q[rq_set_q][wb_way_q] == ST_M) &&
                         (tag_q[rq_set_q][wb_way_q] == wb_tag_q);
    end

    // A snoop committing against the very line a hit is being resolved for.
    // The snoop is the ordering point, so the hit loses and the lookup is
    // retried against the updated state next cycle - otherwise a silent E->M
    // upgrade could race an incoming invalidate and leave two owners.
    logic snoop_conflict;
    always_comb begin
        snoop_conflict = snp_commit_i && snoop_active &&
                         (snp_line_i == {rq_tag_q, rq_set_q});
    end

    // -----------------------------------------------------------------------
    // Bus request outputs
    //
    // The upgrade-race promotion is *combinational* on purpose.  If it were
    // registered, the arbiter could grant in the same cycle the promotion is
    // decided and latch the stale BUSUPGR - running an invalidate-only
    // transaction for a cache that no longer holds the line.  Driving the
    // effective command means whatever the bus latches is always consistent
    // with the requester's current copy state.
    // -----------------------------------------------------------------------
    logic [1:0] eff_cmd;
    always_comb begin
        eff_cmd = (rq_cmd_q == BUSUPGR && !own_copy_valid) ? BUSRDX : rq_cmd_q;
    end

    always_comb begin
        bus_req_o   = (fsm_q == C_WB && wb_still_dirty) || (fsm_q == C_REQ);
        bus_cmd_o   = (fsm_q == C_WB) ? BUSWB : eff_cmd;
        bus_line_o  = (fsm_q == C_WB) ? {wb_tag_q, rq_set_q} : {rq_tag_q, rq_set_q};
        bus_wdata_o = data_q[rq_set_q][wb_way_q];
    end

    always_comb begin
        core_req_ready_o = (fsm_q == C_IDLE);
        dbg_fsm_o        = fsm_q;
        perf_hits_o        = hits_q;
        perf_misses_o      = misses_q;
        perf_silent_upgr_o = sil_q;
        perf_upgr_race_o   = race_q;
        perf_wb_cancel_o   = wbc_q;
    end

    // -----------------------------------------------------------------------
    // Main sequential block
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < SETS; s++) begin
                rr_q[s] <= '0;
                for (int w = 0; w < WAYS; w++) begin
                    state_q[s][w] <= ST_I;
                    tag_q[s][w]   <= '0;
                    data_q[s][w]  <= '0;
                end
            end
            fsm_q             <= C_IDLE;
            rq_we_q           <= 1'b0;
            rq_tag_q          <= '0;
            rq_set_q          <= '0;
            rq_off_q          <= '0;
            rq_wdata_q        <= '0;
            rd_q              <= '0;
            rq_cmd_q          <= BUSRD;
            rq_way_q          <= '0;
            wb_way_q          <= '0;
            wb_tag_q          <= '0;
            wait_wb_q         <= 1'b0;
            line_nx           = '0;
            core_resp_valid_o <= 1'b0;
            hits_q            <= '0;
            misses_q          <= '0;
            sil_q             <= '0;
            race_q            <= '0;
            wbc_q             <= '0;
        end else begin
            core_resp_valid_o <= 1'b0;

            // ---------------------------------------------------------------
            // Snoop side.  Ordered before the core FSM below so that a fill
            // landing in the same cycle wins - it cannot happen, because the
            // bus is atomic, but the ordering makes that explicit.
            // ---------------------------------------------------------------
            if (snp_commit_i && snoop_active) begin
                case (snp_cmd_i)
                    BUSRD: if (snp_state != ST_S) state_q[snp_set][snp_way] <= ST_S;
                    BUSRDX, BUSUPGR: state_q[snp_set][snp_way] <= ST_I;
                    default: ;   // BUSWB - no other cache can hold the line
                endcase
            end

            // ---------------------------------------------------------------
            // Core FSM
            // ---------------------------------------------------------------
            case (fsm_q)

            C_IDLE: begin
                if (core_req_valid_i) begin
                    rq_we_q    <= core_we_i;
                    rq_tag_q   <= in_tag;
                    rq_set_q   <= in_set;
                    rq_off_q   <= in_off;
                    rq_wdata_q <= core_wdata_i;
                    fsm_q      <= C_LOOK;
                end
            end

            C_LOOK: begin
                if (snoop_conflict) begin
                    // Lose to the bus and re-look-up next cycle.
                    fsm_q <= C_LOOK;
                end else if (look_hit && !rq_we_q) begin
                    // Read hit in S / E / M.
                    rd_q     <= data_q[rq_set_q][look_way][rq_off_q*DATA_W +: DATA_W];
                    hits_q   <= hits_q + 32'd1;
                    fsm_q    <= C_RESP;
                end else if (look_hit && look_state == ST_M) begin
                    // Write hit with ownership already held.
                    data_q[rq_set_q][look_way][rq_off_q*DATA_W +: DATA_W] <= rq_wdata_q;
                    hits_q <= hits_q + 32'd1;
                    fsm_q  <= C_RESP;
                end else if (look_hit && look_state == ST_E) begin
                    // The MESI payoff: E->M needs no bus transaction at all.
                    data_q[rq_set_q][look_way][rq_off_q*DATA_W +: DATA_W] <= rq_wdata_q;
                    state_q[rq_set_q][look_way] <= ST_M;
                    hits_q <= hits_q + 32'd1;
                    sil_q  <= sil_q + 32'd1;
                    fsm_q  <= C_RESP;
                end else if (look_hit) begin
                    // Write hit on a shared line: permission only, keep the data.
                    rq_way_q <= look_way;
                    rq_cmd_q <= BUSUPGR;
                    misses_q <= misses_q + 32'd1;   // a coherence miss
                    fsm_q    <= C_REQ;
                end else begin
                    // True miss - allocate.  Dirty victims must be written back.
                    misses_q <= misses_q + 32'd1;
                    rq_way_q <= victim_way;
                    rq_cmd_q <= rq_we_q ? BUSRDX : BUSRD;
                    if (WAYS > 1) rr_q[rq_set_q] <= rr_q[rq_set_q] + 1'b1;
                    if (!look_free && state_q[rq_set_q][victim_way] == ST_M) begin
                        wb_way_q <= victim_way;
                        wb_tag_q <= tag_q[rq_set_q][victim_way];
                        fsm_q    <= C_WB;
                    end else begin
                        fsm_q    <= C_REQ;
                    end
                end
            end

            C_WB: begin
                // Writeback race: an intervening snoop already flushed this
                // victim to memory, so the writeback is redundant.
                if (!wb_still_dirty) begin
                    wbc_q <= wbc_q + 32'd1;
                    fsm_q <= C_REQ;
                end else if (bus_gnt_i) begin
                    wait_wb_q <= 1'b1;
                    fsm_q     <= C_WAIT;
                end
            end

            C_REQ: begin
                // Upgrade race: my shared copy was invalidated while I waited
                // for the bus, so an invalidate-only transaction would be a
                // lie.  Capture the promotion to read-for-ownership - the bus
                // has already seen it on bus_cmd_o.
                if (eff_cmd != rq_cmd_q) begin
                    rq_cmd_q <= eff_cmd;
                    race_q   <= race_q + 32'd1;
                end
                if (bus_gnt_i) begin
                    wait_wb_q <= 1'b0;
                    fsm_q     <= C_WAIT;
                end
            end

            C_WAIT: begin
                if (xact_done_i) begin
                    if (wait_wb_q) begin
                        // Victim flushed; now go do the allocation itself.
                        state_q[rq_set_q][wb_way_q] <= ST_I;
                        fsm_q                       <= C_REQ;
                    end else begin
                        // BUSRD / BUSRDX bring a line; BUSUPGR keeps the copy
                        // already present.  A store merges into the line here,
                        // so the array sees exactly one write either way.
                        line_nx = fill_valid_i ? fill_data_i
                                               : data_q[rq_set_q][rq_way_q];
                        if (rq_we_q)
                            line_nx[rq_off_q*DATA_W +: DATA_W] = rq_wdata_q;

                        tag_q[rq_set_q][rq_way_q]   <= rq_tag_q;
                        data_q[rq_set_q][rq_way_q]  <= line_nx;
                        rd_q                        <= line_nx[rq_off_q*DATA_W +: DATA_W];
                        state_q[rq_set_q][rq_way_q] <= (rq_cmd_q == BUSRD)
                                                     ? (fill_shared_i ? ST_S : ST_E)
                                                     : ST_M;
                        fsm_q <= C_RESP;
                    end
                end
            end

            C_RESP: begin
                core_resp_valid_o <= 1'b1;
                fsm_q             <= C_IDLE;
            end

            default: fsm_q <= C_IDLE;
            endcase
        end
    end

    assign core_rdata_o = rd_q;

    // -----------------------------------------------------------------------
    // Flattened state/tag observability
    // -----------------------------------------------------------------------
    always_comb begin
        dbg_state_o = '0;
        dbg_tag_o   = '0;
        for (int s = 0; s < SETS; s++) begin
            for (int w = 0; w < WAYS; w++) begin
                dbg_state_o[(s*WAYS + w)*2      +: 2]     = state_q[s][w];
                dbg_tag_o  [(s*WAYS + w)*TAG_W  +: TAG_W] = tag_q[s][w];
            end
        end
    end

endmodule


// ===========================================================================
//  Atomic snooping bus: round-robin arbiter, snoop phase, intervention path,
//  memory port, and the single point that orders every coherence event.
// ===========================================================================
module mesi_snoop_bus #(
    parameter int NUM_CORES = 4,
    parameter int LADDR_W   = 7,
    parameter int LINE_W    = 128,
    parameter int C2C_LAT   = 2,     // cache-to-cache intervention transfer
    // Derived - do not override ---------------------------------------------
    parameter int CSEL = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES)
) (
    input  logic                            clk,
    input  logic                            rst_n,

    // Per-cache request ports (flattened) ------------------------------------
    input  logic [NUM_CORES-1:0]            req_i,
    input  logic [NUM_CORES*2-1:0]          cmd_i,
    input  logic [NUM_CORES*LADDR_W-1:0]    line_i,
    input  logic [NUM_CORES*LINE_W-1:0]     wdata_i,
    output logic [NUM_CORES-1:0]            gnt_o,

    // Snoop broadcast --------------------------------------------------------
    output logic                            snp_valid_o,
    output logic [1:0]                      snp_cmd_o,
    output logic [LADDR_W-1:0]              snp_line_o,
    output logic [NUM_CORES-1:0]            snp_isme_o,
    output logic                            snp_commit_o,
    input  logic [NUM_CORES-1:0]            snp_hit_i,
    input  logic [NUM_CORES-1:0]            snp_dirty_i,
    input  logic [NUM_CORES*LINE_W-1:0]     snp_data_i,

    // Fill / completion ------------------------------------------------------
    output logic [NUM_CORES-1:0]            fill_valid_o,
    output logic [LINE_W-1:0]               fill_data_o,
    output logic [NUM_CORES-1:0]            fill_shared_o,
    output logic [NUM_CORES-1:0]            done_o,

    // Backing memory port ----------------------------------------------------
    output logic                            mem_req_o,
    output logic                            mem_we_o,
    output logic [LADDR_W-1:0]              mem_line_o,
    output logic [LINE_W-1:0]               mem_wdata_o,
    input  logic                            mem_ready_i,
    input  logic                            mem_rvalid_i,
    input  logic [LINE_W-1:0]               mem_rdata_i,

    // Observability ----------------------------------------------------------
    output logic [2:0]                      dbg_bus_state_o,
    output logic [CSEL-1:0]                 dbg_owner_o,
    output logic [31:0]                     perf_busrd_o,
    output logic [31:0]                     perf_busrdx_o,
    output logic [31:0]                     perf_busupgr_o,
    output logic [31:0]                     perf_wb_o,
    output logic [31:0]                     perf_c2c_o,
    output logic [31:0]                     perf_mem_rd_o,
    output logic [31:0]                     perf_mem_wr_o,
    output logic [31:0]                     perf_inval_o,
    output logic [31:0]                     perf_downgrade_o
);

    localparam logic [1:0] BUSRD   = 2'd0;
    localparam logic [1:0] BUSRDX  = 2'd1;
    localparam logic [1:0] BUSUPGR = 2'd2;
    localparam logic [1:0] BUSWB   = 2'd3;

    localparam logic [2:0] B_IDLE  = 3'd0;
    localparam logic [2:0] B_SNOOP = 3'd1;
    localparam logic [2:0] B_C2C   = 3'd2;
    localparam logic [2:0] B_MEMWR = 3'd3;
    localparam logic [2:0] B_MEMRD = 3'd4;
    localparam logic [2:0] B_MEMWT = 3'd5;   // waiting for read data
    localparam logic [2:0] B_COMMIT= 3'd6;

    logic [2:0]         bs_q;
    logic [CSEL-1:0]    owner_q, rr_q;
    logic [1:0]         cmd_q;
    logic [LADDR_W-1:0] line_q;
    logic [LINE_W-1:0]  buf_q;
    logic               shared_q;      // another cache had a copy
    logic               need_fill_q;   // requester expects data
    logic               flush_q;       // dirty intervention -> memory writeback
    logic [15:0]        cnt_q;

    logic [31:0] n_rd_q, n_rdx_q, n_upgr_q, n_wb_q, n_c2c_q;
    logic [31:0] n_mrd_q, n_mwr_q, n_inv_q, n_dwn_q;

    // -----------------------------------------------------------------------
    // Round-robin arbitration: first requester at or after rr_q
    // -----------------------------------------------------------------------
    logic            any_req;
    logic [CSEL-1:0] winner;
    integer          arb_idx;
    always_comb begin
        any_req = |req_i;
        winner  = rr_q;
        // Descending k so that the nearest requester at or after rr_q (k = 0
        // first in priority, evaluated last) ends up in `winner`.
        for (int k = NUM_CORES - 1; k >= 0; k--) begin
            arb_idx = (rr_q + k) % NUM_CORES;
            if (req_i[arb_idx]) winner = arb_idx[CSEL-1:0];
        end
    end

    // -----------------------------------------------------------------------
    // Snoop-phase aggregation over every cache except the requester
    // -----------------------------------------------------------------------
    logic [NUM_CORES-1:0] other_hit, other_dirty;
    logic                 shared_any, dirty_any;
    logic [CSEL-1:0]      supplier;
    logic [LINE_W-1:0]    supplier_data;
    logic [31:0]          hit_count;

    always_comb begin
        other_hit     = snp_hit_i   & ~snp_isme_o;
        other_dirty   = snp_dirty_i & ~snp_isme_o;
        shared_any    = |other_hit;
        dirty_any     = |other_dirty;
        supplier      = '0;
        hit_count     = '0;
        for (int c = NUM_CORES - 1; c >= 0; c--) begin
            if (other_dirty[c]) supplier = c[CSEL-1:0];
            if (other_hit[c])   hit_count = hit_count + 32'd1;
        end
        supplier_data = snp_data_i[supplier*LINE_W +: LINE_W];
    end

    logic [1:0]         sel_cmd;
    logic [LADDR_W-1:0] sel_line;
    logic [LINE_W-1:0]  sel_wdata;
    always_comb begin
        sel_cmd   = cmd_i  [winner*2 +: 2];
        sel_line  = line_i [winner*LADDR_W +: LADDR_W];
        sel_wdata = wdata_i[winner*LINE_W  +: LINE_W];
    end

    // -----------------------------------------------------------------------
    // Outputs
    // -----------------------------------------------------------------------
    always_comb begin
        gnt_o        = '0;
        fill_valid_o = '0;
        fill_shared_o= '0;
        done_o       = '0;

        snp_valid_o  = (bs_q != B_IDLE);
        snp_cmd_o    = cmd_q;
        snp_line_o   = line_q;
        snp_isme_o   = '0;
        snp_isme_o[owner_q] = 1'b1;
        snp_commit_o = (bs_q == B_COMMIT);

        if (bs_q == B_IDLE && any_req) gnt_o[winner] = 1'b1;

        if (bs_q == B_COMMIT) begin
            done_o[owner_q]        = 1'b1;
            fill_valid_o[owner_q]  = need_fill_q;
            fill_shared_o[owner_q] = shared_q;
        end

        fill_data_o = buf_q;

        mem_req_o   = (bs_q == B_MEMWR) || (bs_q == B_MEMRD);
        mem_we_o    = (bs_q == B_MEMWR);
        mem_line_o  = line_q;
        mem_wdata_o = buf_q;

        dbg_bus_state_o = bs_q;
        dbg_owner_o     = owner_q;
        perf_busrd_o     = n_rd_q;
        perf_busrdx_o    = n_rdx_q;
        perf_busupgr_o   = n_upgr_q;
        perf_wb_o        = n_wb_q;
        perf_c2c_o       = n_c2c_q;
        perf_mem_rd_o    = n_mrd_q;
        perf_mem_wr_o    = n_mwr_q;
        perf_inval_o     = n_inv_q;
        perf_downgrade_o = n_dwn_q;
    end

    // -----------------------------------------------------------------------
    // Bus FSM
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bs_q        <= B_IDLE;
            owner_q     <= '0;
            rr_q        <= '0;
            cmd_q       <= BUSRD;
            line_q      <= '0;
            buf_q       <= '0;
            shared_q    <= 1'b0;
            need_fill_q <= 1'b0;
            flush_q     <= 1'b0;
            cnt_q       <= '0;
            n_rd_q      <= '0;
            n_rdx_q     <= '0;
            n_upgr_q    <= '0;
            n_wb_q      <= '0;
            n_c2c_q     <= '0;
            n_mrd_q     <= '0;
            n_mwr_q     <= '0;
            n_inv_q     <= '0;
            n_dwn_q     <= '0;
        end else begin
            case (bs_q)

            B_IDLE: begin
                if (any_req) begin
                    owner_q <= winner;
                    cmd_q   <= sel_cmd;
                    line_q  <= sel_line;
                    buf_q   <= sel_wdata;    // meaningful only for BUSWB
                    rr_q    <= (winner == NUM_CORES - 1) ? '0 : winner + 1'b1;
                    case (sel_cmd)
                        BUSRD:   n_rd_q   <= n_rd_q   + 32'd1;
                        BUSRDX:  n_rdx_q  <= n_rdx_q  + 32'd1;
                        BUSUPGR: n_upgr_q <= n_upgr_q + 32'd1;
                        default: n_wb_q   <= n_wb_q   + 32'd1;
                    endcase
                    bs_q <= B_SNOOP;
                end
            end

            B_SNOOP: begin
                shared_q <= shared_any;
                case (cmd_q)
                    BUSWB: begin
                        need_fill_q <= 1'b0;
                        flush_q     <= 1'b0;
                        bs_q        <= B_MEMWR;
                    end
                    BUSUPGR: begin
                        // Permission only: no data moves anywhere.
                        need_fill_q <= 1'b0;
                        flush_q     <= 1'b0;
                        n_inv_q     <= n_inv_q + hit_count;
                        bs_q        <= B_COMMIT;
                    end
                    default: begin   // BUSRD / BUSRDX
                        need_fill_q <= 1'b1;
                        if (cmd_q == BUSRDX) n_inv_q <= n_inv_q + hit_count;
                        else                 n_dwn_q <= n_dwn_q + hit_count;
                        if (dirty_any) begin
                            // Intervention: the owner supplies the line and the
                            // bus flushes it, so memory is clean afterwards.
                            buf_q   <= supplier_data;
                            flush_q <= 1'b1;
                            n_c2c_q <= n_c2c_q + 32'd1;
                            cnt_q   <= C2C_LAT;
                            bs_q    <= (C2C_LAT == 0) ? B_MEMWR : B_C2C;
                        end else begin
                            flush_q <= 1'b0;
                            bs_q    <= B_MEMRD;
                        end
                    end
                endcase
            end

            B_C2C: begin
                if (cnt_q <= 16'd1) bs_q  <= B_MEMWR;
                else                cnt_q <= cnt_q - 16'd1;
            end

            B_MEMWR: begin
                if (mem_ready_i) begin
                    n_mwr_q <= n_mwr_q + 32'd1;
                    bs_q    <= B_COMMIT;
                end
            end

            B_MEMRD: begin
                if (mem_ready_i) begin
                    n_mrd_q <= n_mrd_q + 32'd1;
                    bs_q    <= B_MEMWT;
                end
            end

            B_MEMWT: begin
                if (mem_rvalid_i) begin
                    buf_q <= mem_rdata_i;
                    bs_q  <= B_COMMIT;
                end
            end

            B_COMMIT: bs_q <= B_IDLE;

            default: bs_q <= B_IDLE;
            endcase
        end
    end

endmodule


// ===========================================================================
//  Top level: NUM_CORES coherent L1 caches on one snooping bus
// ===========================================================================
module mesi_snoop_coherence #(
    parameter int NUM_CORES  = 4,
    parameter int SETS       = 8,
    parameter int WAYS       = 2,
    parameter int LINE_WORDS = 4,
    parameter int DATA_W     = 32,
    parameter int TAG_W      = 4,
    parameter int C2C_LAT    = 2,
    // Derived - do not override ---------------------------------------------
    parameter int SIDX    = (SETS <= 1) ? 1 : $clog2(SETS),
    parameter int WOFF    = (LINE_WORDS <= 1) ? 1 : $clog2(LINE_WORDS),
    parameter int CSEL    = (NUM_CORES <= 1) ? 1 : $clog2(NUM_CORES),
    parameter int ADDR_W  = TAG_W + SIDX + WOFF,
    parameter int LADDR_W = TAG_W + SIDX,
    parameter int LINE_W  = LINE_WORDS * DATA_W
) (
    input  logic                              clk,
    input  logic                              rst_n,

    // Per-core memory ports (flattened) -------------------------------------
    input  logic [NUM_CORES-1:0]              core_req_valid_i,
    output logic [NUM_CORES-1:0]              core_req_ready_o,
    input  logic [NUM_CORES-1:0]              core_we_i,
    input  logic [NUM_CORES*ADDR_W-1:0]       core_addr_i,
    input  logic [NUM_CORES*DATA_W-1:0]       core_wdata_i,
    output logic [NUM_CORES-1:0]              core_resp_valid_o,
    output logic [NUM_CORES*DATA_W-1:0]       core_rdata_o,

    // Backing memory (line granular) ----------------------------------------
    output logic                              mem_req_o,
    output logic                              mem_we_o,
    output logic [LADDR_W-1:0]                mem_line_o,
    output logic [LINE_W-1:0]                 mem_wdata_o,
    input  logic                              mem_ready_i,
    input  logic                              mem_rvalid_i,
    input  logic [LINE_W-1:0]                 mem_rdata_i,

    // Coherence observability ------------------------------------------------
    output logic [NUM_CORES*SETS*WAYS*2-1:0]  dbg_state_o,
    output logic [NUM_CORES*SETS*WAYS*TAG_W-1:0] dbg_tag_o,
    output logic [NUM_CORES*4-1:0]            dbg_fsm_o,
    output logic                              bus_active_o,
    output logic [1:0]                        bus_cmd_o,
    output logic [LADDR_W-1:0]                bus_line_o,
    output logic [CSEL-1:0]                   bus_owner_o,
    output logic [2:0]                        bus_state_o,
    output logic                              bus_commit_o,
    output logic [NUM_CORES-1:0]              bus_gnt_o,
    output logic [NUM_CORES-1:0]              snp_hit_o,
    output logic [NUM_CORES-1:0]              snp_dirty_o,

    // Performance counters ---------------------------------------------------
    output logic [31:0]                       perf_busrd_o,
    output logic [31:0]                       perf_busrdx_o,
    output logic [31:0]                       perf_busupgr_o,
    output logic [31:0]                       perf_wb_o,
    output logic [31:0]                       perf_c2c_o,
    output logic [31:0]                       perf_mem_rd_o,
    output logic [31:0]                       perf_mem_wr_o,
    output logic [31:0]                       perf_inval_o,
    output logic [31:0]                       perf_downgrade_o,
    output logic [31:0]                       perf_hits_o,
    output logic [31:0]                       perf_misses_o,
    output logic [31:0]                       perf_silent_upgr_o,
    output logic [31:0]                       perf_upgr_race_o,
    output logic [31:0]                       perf_wb_cancel_o
);

    // Cache <-> bus wiring, flattened so the whole thing stays synthesizable
    // without interfaces (which Icarus does not support).
    logic [NUM_CORES-1:0]         c_req, c_gnt;
    logic [NUM_CORES*2-1:0]       c_cmd;
    logic [NUM_CORES*LADDR_W-1:0] c_line;
    logic [NUM_CORES*LINE_W-1:0]  c_wdata, c_snpdata;
    logic [NUM_CORES-1:0]         c_hit, c_dirty, c_isme, c_fillv, c_shared, c_done;
    logic                         snp_valid, snp_commit;
    logic [1:0]                   snp_cmd;
    logic [LADDR_W-1:0]           snp_line;
    logic [LINE_W-1:0]            fill_data;

    logic [NUM_CORES*32-1:0] p_hits, p_miss, p_sil, p_race, p_wbc;

    genvar g;
    generate
        for (g = 0; g < NUM_CORES; g++) begin : g_cache
            mesi_l1_cache #(
                .SETS(SETS), .WAYS(WAYS), .LINE_WORDS(LINE_WORDS),
                .DATA_W(DATA_W), .TAG_W(TAG_W)
            ) u_cache (
                .clk               (clk),
                .rst_n             (rst_n),
                .core_req_valid_i  (core_req_valid_i[g]),
                .core_req_ready_o  (core_req_ready_o[g]),
                .core_we_i         (core_we_i[g]),
                .core_addr_i       (core_addr_i[g*ADDR_W +: ADDR_W]),
                .core_wdata_i      (core_wdata_i[g*DATA_W +: DATA_W]),
                .core_resp_valid_o (core_resp_valid_o[g]),
                .core_rdata_o      (core_rdata_o[g*DATA_W +: DATA_W]),
                .bus_req_o         (c_req[g]),
                .bus_cmd_o         (c_cmd[g*2 +: 2]),
                .bus_line_o        (c_line[g*LADDR_W +: LADDR_W]),
                .bus_wdata_o       (c_wdata[g*LINE_W +: LINE_W]),
                .bus_gnt_i         (c_gnt[g]),
                .snp_valid_i       (snp_valid),
                .snp_cmd_i         (snp_cmd),
                .snp_line_i        (snp_line),
                .snp_isme_i        (c_isme[g]),
                .snp_commit_i      (snp_commit),
                .snp_hit_o         (c_hit[g]),
                .snp_dirty_o       (c_dirty[g]),
                .snp_data_o        (c_snpdata[g*LINE_W +: LINE_W]),
                .fill_valid_i      (c_fillv[g]),
                .fill_data_i       (fill_data),
                .fill_shared_i     (c_shared[g]),
                .xact_done_i       (c_done[g]),
                .dbg_state_o       (dbg_state_o[g*SETS*WAYS*2 +: SETS*WAYS*2]),
                .dbg_tag_o         (dbg_tag_o[g*SETS*WAYS*TAG_W +: SETS*WAYS*TAG_W]),
                .dbg_fsm_o         (dbg_fsm_o[g*4 +: 4]),
                .perf_hits_o       (p_hits[g*32 +: 32]),
                .perf_misses_o     (p_miss[g*32 +: 32]),
                .perf_silent_upgr_o(p_sil[g*32 +: 32]),
                .perf_upgr_race_o  (p_race[g*32 +: 32]),
                .perf_wb_cancel_o  (p_wbc[g*32 +: 32])
            );
        end
    endgenerate

    mesi_snoop_bus #(
        .NUM_CORES(NUM_CORES), .LADDR_W(LADDR_W), .LINE_W(LINE_W),
        .C2C_LAT(C2C_LAT)
    ) u_bus (
        .clk             (clk),
        .rst_n           (rst_n),
        .req_i           (c_req),
        .cmd_i           (c_cmd),
        .line_i          (c_line),
        .wdata_i         (c_wdata),
        .gnt_o           (c_gnt),
        .snp_valid_o     (snp_valid),
        .snp_cmd_o       (snp_cmd),
        .snp_line_o      (snp_line),
        .snp_isme_o      (c_isme),
        .snp_commit_o    (snp_commit),
        .snp_hit_i       (c_hit),
        .snp_dirty_i     (c_dirty),
        .snp_data_i      (c_snpdata),
        .fill_valid_o    (c_fillv),
        .fill_data_o     (fill_data),
        .fill_shared_o   (c_shared),
        .done_o          (c_done),
        .mem_req_o       (mem_req_o),
        .mem_we_o        (mem_we_o),
        .mem_line_o      (mem_line_o),
        .mem_wdata_o     (mem_wdata_o),
        .mem_ready_i     (mem_ready_i),
        .mem_rvalid_i    (mem_rvalid_i),
        .mem_rdata_i     (mem_rdata_i),
        .dbg_bus_state_o (bus_state_o),
        .dbg_owner_o     (bus_owner_o),
        .perf_busrd_o    (perf_busrd_o),
        .perf_busrdx_o   (perf_busrdx_o),
        .perf_busupgr_o  (perf_busupgr_o),
        .perf_wb_o       (perf_wb_o),
        .perf_c2c_o      (perf_c2c_o),
        .perf_mem_rd_o   (perf_mem_rd_o),
        .perf_mem_wr_o   (perf_mem_wr_o),
        .perf_inval_o    (perf_inval_o),
        .perf_downgrade_o(perf_downgrade_o)
    );

    always_comb begin
        bus_active_o = snp_valid;
        bus_cmd_o    = snp_cmd;
        bus_line_o   = snp_line;
        bus_commit_o = snp_commit;
        bus_gnt_o    = c_gnt;
        snp_hit_o    = c_hit;
        snp_dirty_o  = c_dirty;

        perf_hits_o        = '0;
        perf_misses_o      = '0;
        perf_silent_upgr_o = '0;
        perf_upgr_race_o   = '0;
        perf_wb_cancel_o   = '0;
        for (int c = 0; c < NUM_CORES; c++) begin
            perf_hits_o        = perf_hits_o        + p_hits[c*32 +: 32];
            perf_misses_o      = perf_misses_o      + p_miss[c*32 +: 32];
            perf_silent_upgr_o = perf_silent_upgr_o + p_sil [c*32 +: 32];
            perf_upgr_race_o   = perf_upgr_race_o   + p_race[c*32 +: 32];
            perf_wb_cancel_o   = perf_wb_cancel_o   + p_wbc [c*32 +: 32];
        end
    end

endmodule
