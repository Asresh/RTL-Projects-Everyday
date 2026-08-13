// ===========================================================================
// gpu_coalescer.sv  --  Warp Global-Memory Coalescing Unit (GPU LSU front-end)
// ---------------------------------------------------------------------------
// A SIMT load/store unit takes a *warp* of per-lane byte addresses and must
// turn them into the MINIMUM number of aligned memory transactions before
// they hit the L2 / DRAM.  All lanes that fall inside the same SEG_BYTES-
// aligned segment (a "cache line" / "sector") are served by a single
// transaction; this is exactly the "memory coalescing" that dominates the
// achievable DRAM bandwidth of a GPU kernel (and, in an HFT market-data
// gather, the tail latency of a scattered read).
//
// Microarchitecture (single-pass parallel leader detection -- NOT an
// iterative retire loop):
//
//   1. seg[i]      = addr[i] >> log2(SEG_BYTES)             (segment id / lane)
//   2. leader[i]   = active[i] & ~( OR_{j<i} active[j] & seg[j]==seg[i] )
//                    -> the lowest-indexed lane of each distinct segment.
//      num_txn      = popcount(leader)   (== number of distinct segments).
//   3. Sequenced emit: one transaction / cycle, in ascending leader order.
//      For the selected leader p:
//         txn_base       = seg[p] << log2(SEG_BYTES)   (aligned segment base)
//         txn_lane_mask  = { k : active[k] & seg[k]==seg[p] }  (lanes served)
//      The masks form an exact partition of the active lanes.
//
// Perf counters expose the coalescing efficiency of the stream:
//      perf_lanes / perf_txns  == average lanes served per transaction
//      (1.0 = fully uncoalesced worst case, LANES = perfectly coalesced).
//
// Parameterized, reset-safe, lint-friendly. Verified with Icarus Verilog
// against an independent golden set-partition model (see testbench).
// ===========================================================================
`default_nettype none

module gpu_coalescer #(
    parameter int LANES     = 8,    // warp width (lanes presented per request)
    parameter int ADDRW     = 32,   // byte-address width
    parameter int SEG_BYTES = 32,   // coalescing granularity (power of two)
    // ---- derived widths (do NOT override) -------------------------------
    parameter int LOG2_SEG  = $clog2(SEG_BYTES),  // low bits = intra-seg offset
    parameter int SEGW      = ADDRW - LOG2_SEG,   // segment-id width
    parameter int CNTW      = $clog2(LANES + 1)   // holds 0..LANES
) (
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- request: one warp of lane addresses ----------------------------
    input  wire                    in_valid,   // a warp is being presented
    output wire                    in_ready,   // unit is idle / can accept
    input  wire  [LANES-1:0]       req_mask,   // per-lane active bit
    input  wire  [LANES*ADDRW-1:0] addr,       // lane i = addr[i*ADDRW +: ADDRW]

    // ---- coalesced transaction stream (one per cycle) -------------------
    output logic                   txn_valid,     // a coalesced txn is valid
    output logic [ADDRW-1:0]       txn_base,      // aligned segment base addr
    output logic [LANES-1:0]       txn_lane_mask, // lanes served by this txn
    output logic [CNTW-1:0]        txn_index,     // 0 .. num_txn-1
    output logic                   txn_last,      // last txn of this warp
    output logic [CNTW-1:0]        num_txn,       // total txns for the warp
    output logic                   warp_done,     // 1-cyc pulse: warp retired
    output wire                    busy,

    // ---- performance counters -------------------------------------------
    output logic [31:0]            perf_lanes,    // total active lanes accepted
    output logic [31:0]            perf_txns      // total transactions emitted
);

    // ---- FSM ------------------------------------------------------------
    // IDLE   : accept a warp, register its mask + per-lane segment ids
    // DECODE : from the REGISTERED request, mark segment leaders (1 cycle)
    // EMIT   : stream one coalesced transaction per cycle
    // Registering the request first makes the leader detection read only
    // stable, latched values -- no combinational-at-the-clock-edge races.
    localparam logic [1:0] S_IDLE   = 2'd0;
    localparam logic [1:0] S_DECODE = 2'd1;
    localparam logic [1:0] S_EMIT   = 2'd2;
    logic [1:0] state;

    assign in_ready = (state == S_IDLE);
    assign busy     = (state != S_IDLE);

    // ---- latched request ------------------------------------------------
    logic [LANES-1:0]  reqm_q;              // active mask of the latched warp
    logic [SEGW-1:0]   seg_q   [LANES];     // segment id per lane (registered)
    logic [LANES-1:0]  pending_q;           // leaders not yet emitted
    logic [CNTW-1:0]   idx_q;               // transactions emitted so far

    // =====================================================================
    // Leader detection over the REGISTERED request (stable during DECODE).
    // leader_q[i] == the lowest-indexed active lane of each distinct segment.
    // =====================================================================
    logic [LANES-1:0] leader_q;
    logic [CNTW-1:0]  ncount_q;

    always_comb begin
        for (int i = 0; i < LANES; i = i + 1) begin
            leader_q[i] = reqm_q[i];
            for (int j = 0; j < LANES; j = j + 1)
                if (j < i && reqm_q[j] && (seg_q[j] == seg_q[i]))
                    leader_q[i] = 1'b0;
        end

        // number of distinct segments == number of coalesced transactions
        ncount_q = '0;
        for (int i = 0; i < LANES; i = i + 1)
            ncount_q = ncount_q + {{(CNTW-1){1'b0}}, leader_q[i]};
    end

    // popcount of a lane-wide mask (used for the perf counter at accept time,
    // evaluated inside the sequential block so it reads only stable inputs)
    function automatic [CNTW-1:0] popcount(input logic [LANES-1:0] m);
        popcount = '0;
        for (int i = 0; i < LANES; i = i + 1)
            popcount = popcount + {{(CNTW-1){1'b0}}, m[i]};
    endfunction

    // =====================================================================
    // Combinational select of the next transaction during EMIT
    // =====================================================================
    logic [$clog2(LANES>1?LANES:2)-1:0] sel_p;   // chosen leader lane index
    logic                sel_found;
    logic [LANES-1:0]    sel_group;               // lanes sharing sel_p's seg
    logic [ADDRW-1:0]    sel_base;                // aligned base of sel_p
    logic [LANES-1:0]    pending_next;
    logic                sel_last;

    always_comb begin
        // lowest-index pending leader
        sel_p     = '0;
        sel_found = 1'b0;
        for (int k = 0; k < LANES; k = k + 1)
            if (!sel_found && pending_q[k]) begin
                sel_p     = k[$clog2(LANES>1?LANES:2)-1:0];
                sel_found = 1'b1;
            end

        // all active lanes sharing the selected segment
        for (int k = 0; k < LANES; k = k + 1)
            sel_group[k] = reqm_q[k] && (seg_q[k] == seg_q[sel_p]);

        // aligned segment base = seg << log2(SEG_BYTES)
        sel_base     = {seg_q[sel_p], {LOG2_SEG{1'b0}}};

        // clear the leader we are emitting; last when none remain
        pending_next = pending_q & ~(({{(LANES-1){1'b0}}, 1'b1}) << sel_p);
        sel_last     = (pending_next == '0);
    end

    // =====================================================================
    // Sequential control / datapath
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            reqm_q        <= '0;
            pending_q     <= '0;
            idx_q         <= '0;
            txn_valid     <= 1'b0;
            txn_base      <= '0;
            txn_lane_mask <= '0;
            txn_index     <= '0;
            txn_last      <= 1'b0;
            num_txn       <= '0;
            warp_done     <= 1'b0;
            perf_lanes    <= 32'd0;
            perf_txns     <= 32'd0;
            for (int i = 0; i < LANES; i = i + 1)
                seg_q[i] <= '0;
        end else begin
            // one-cycle strobes default low
            txn_valid <= 1'b0;
            txn_last  <= 1'b0;
            warp_done <= 1'b0;

            case (state)
                // -------------------------------------------------- IDLE
                S_IDLE: begin
                    if (in_valid) begin
                        // register the warp: mask + per-lane segment id.
                        // seg is a pure slice of the (stable) address bus.
                        reqm_q     <= req_mask;
                        idx_q      <= '0;
                        perf_lanes <= perf_lanes + {{(32-CNTW){1'b0}}, popcount(req_mask)};
                        for (int i = 0; i < LANES; i = i + 1)
                            seg_q[i] <= addr[i*ADDRW + LOG2_SEG +: SEGW];
                        state <= S_DECODE;
                    end
                end

                // ------------------------------------------------ DECODE
                S_DECODE: begin
                    // leader_q / ncount_q are settled from the registered warp
                    num_txn <= ncount_q;
                    if (leader_q == '0) begin
                        // no active lanes -> zero-transaction warp
                        pending_q <= '0;
                        warp_done <= 1'b1;
                        state     <= S_IDLE;
                    end else begin
                        pending_q <= leader_q;
                        state     <= S_EMIT;
                    end
                end

                // -------------------------------------------------- EMIT
                S_EMIT: begin
                    txn_valid     <= 1'b1;
                    txn_base      <= sel_base;
                    txn_lane_mask <= sel_group;
                    txn_index     <= idx_q;
                    txn_last      <= sel_last;
                    perf_txns     <= perf_txns + 32'd1;
                    idx_q         <= idx_q + 1'b1;
                    pending_q     <= pending_next;

                    if (sel_last) begin
                        warp_done <= 1'b1;
                        state     <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
