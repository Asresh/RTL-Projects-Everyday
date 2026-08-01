// ---------------------------------------------------------------------------
// Day 28 : Redundant A/B Market-Data Feed Arbitrator (line arbitration)
//          + reorder window + deterministic gap detection / skip
// ---------------------------------------------------------------------------
// The *very front door* of the HFT tick-to-trade path — the stage that sits in
// front of Day 25's feed parser. Every major exchange publishes each market-
// data multicast feed TWICE, on two independent network paths ("A" and "B"),
// for redundancy: a packet dropped on line A is (usually) still delivered on
// line B. This block is the FPGA "line arbiter" / "feed arbitrator" that:
//
//   * DEDUPLICATES the two identical streams by sequence number  (forward each
//     seq exactly once — the second copy is silently suppressed),
//   * REORDERS the merged stream back into strict ascending sequence order
//     using a small direct-mapped reorder window (a packet that arrives early
//     on one line waits for its in-order predecessors),
//   * DETECTS GAPS — a sequence number missing on BOTH lines — and, after a
//     bounded, DETERMINISTIC timeout, emits a `gap` event (the trigger a real
//     handler uses to request a retransmit / snapshot) and skips the hole so
//     the pipe can never wedge.
//
// The output is a single, clean, gap-free-or-flagged, strictly in-order stream
// that Day 25's parser can consume at one message per clock.
//
// -- Why this is the ultra-low-latency lesson ------------------------------
// In software, A/B arbitration is a hash set of "seen" sequence numbers plus a
// reorder priority-queue — allocation, hashing, pointer chases, lock/park on
// the socket threads: microseconds of jittery, GC-/cache-dependent work on the
// hottest packet on the wire. Here EVERY per-message decision — is this a
// duplicate? is it in the reorder window? does it fill the hole we are waiting
// on? — is a fixed combinational cone over a tiny direct-mapped window, and
// every output is REGISTERED: exactly one clock, occupancy-independent, worst-
// case == typical. The gap timeout is a fixed cycle count, so even packet LOSS
// resolves in bounded, budgetable time instead of stalling the strategy.
//
//   * Direct-mapped window slot  = seq mod WIN   -> no search, no CAM, O(1).
//   * Duplicate suppression      = "slot already filled" test, combinational.
//   * In-order drain             = one look at the `expected` slot per clock.
//   * Gap skip                   = fixed GAP_TIMEOUT cycles, then advance.
//
// Fully parameterized, latch-free, synchronous active-high reset.
// ---------------------------------------------------------------------------
`default_nettype none

module ab_feed_arbiter #(
    parameter int SEQ_W       = 16,   // sequence-number width
    parameter int DATA_W      = 32,   // opaque payload width (a raw feed message)
    parameter int WIN_LOG2    = 3,    // reorder window depth = 2**WIN_LOG2 slots
    parameter int GAP_TIMEOUT = 4,    // cycles to wait for a missing seq before skipping
    parameter int STAT_W      = 32    // saturating perf-counter width
) (
    input  wire                 clk,
    input  wire                 rst,       // synchronous, active-high

    // ---- Redundant input line A -----------------------------------------
    input  wire                 a_valid,
    input  wire  [SEQ_W-1:0]    a_seq,
    input  wire  [DATA_W-1:0]   a_data,
    // ---- Redundant input line B -----------------------------------------
    input  wire                 b_valid,
    input  wire  [SEQ_W-1:0]    b_seq,
    input  wire  [DATA_W-1:0]   b_data,

    // ---- Arbitrated output: dedup'd, strictly in ascending seq order -----
    output reg                  out_valid, // 1-cycle strobe, <= 1 message / clock
    output reg   [SEQ_W-1:0]    out_seq,
    output reg   [DATA_W-1:0]   out_data,

    // ---- Gap / recovery -------------------------------------------------
    output reg                  gap_o,     // 1-cycle: seq `gap_seq_o` was skipped (lost on A&B)
    output reg   [SEQ_W-1:0]    gap_seq_o,
    output reg                  far_o,     // 1-cycle: a message beyond the window was dropped

    // ---- Status ---------------------------------------------------------
    output wire  [SEQ_W-1:0]    expected_o, // next seq the arbiter still owes downstream
    output reg   [STAT_W-1:0]   stat_fwd_o, // messages forwarded
    output reg   [STAT_W-1:0]   stat_dup_o, // duplicates suppressed (the A/B win)
    output reg   [STAT_W-1:0]   stat_gap_o  // gaps skipped
);

    localparam int WIN = (1 << WIN_LOG2);

    // ---- Architectural state --------------------------------------------
    reg [SEQ_W-1:0]  expected;                 // next in-order seq to emit
    reg              buf_v [0:WIN-1];           // window slot occupied?
    reg [SEQ_W-1:0]  buf_s [0:WIN-1];           // its sequence number
    reg [DATA_W-1:0] buf_d [0:WIN-1];           // its payload
    reg [31:0]       gap_timer;                 // cycles stalled on a hole

    assign expected_o = expected;

    // ---- Combinational next-state ---------------------------------------
    // Working copies of the window we mutate this cycle.
    reg              nv [0:WIN-1];
    reg [SEQ_W-1:0]  ns [0:WIN-1];
    reg [DATA_W-1:0] nd [0:WIN-1];

    reg [SEQ_W-1:0]  nxt_expected;
    reg [31:0]       nxt_timer;

    reg              out_valid_n;
    reg [SEQ_W-1:0]  out_seq_n;
    reg [DATA_W-1:0] out_data_n;
    reg              gap_n;
    reg [SEQ_W-1:0]  gap_seq_n;
    reg              far_n;

    reg [STAT_W-1:0] fwd_n, dup_n, gap_cnt_n;

    // Per-feed scratch (packed so we can process line A then line B uniformly)
    reg              fv [0:1];
    reg [SEQ_W-1:0]  fs [0:1];
    reg [DATA_W-1:0] fd [0:1];

    integer          i, f;
    reg [SEQ_W-1:0]  off;         // seq - expected, modulo 2**SEQ_W
    reg [WIN_LOG2-1:0] idx;       // direct-mapped slot for this seq
    reg [WIN_LOG2-1:0] eidx;      // slot for `expected`
    reg              any_ahead;   // is anything buffered past the hole?

    always @* begin
        // start from current state
        for (i = 0; i < WIN; i = i + 1) begin
            nv[i] = buf_v[i];
            ns[i] = buf_s[i];
            nd[i] = buf_d[i];
        end
        nxt_expected = expected;
        nxt_timer    = gap_timer;

        out_valid_n = 1'b0;
        out_seq_n   = {SEQ_W{1'b0}};
        out_data_n  = {DATA_W{1'b0}};
        gap_n       = 1'b0;
        gap_seq_n   = {SEQ_W{1'b0}};
        far_n       = 1'b0;

        fwd_n     = 1'b0;   // per-cycle increments (0/1/2), added to saturating counters below
        dup_n     = 1'b0;
        gap_cnt_n = 1'b0;

        fv[0] = a_valid; fs[0] = a_seq; fd[0] = a_data;
        fv[1] = b_valid; fs[1] = b_seq; fd[1] = b_data;

        // ---- INGEST: classify each line's message against `expected` ------
        // Processing line 0 (A) before line 1 (B) makes the same-seq A/B pair
        // resolve as "A written, B duplicate" — that is the redundancy win.
        for (f = 0; f < 2; f = f + 1) begin
            if (fv[f]) begin
                off = fs[f] - expected;            // wraps mod 2**SEQ_W
                idx = fs[f][WIN_LOG2-1:0];
                if (off < WIN) begin
                    // in the reorder window
                    if (nv[idx]) begin
                        dup_n = dup_n + 1'b1;      // already have this seq (A/B dup or replay)
                    end else begin
                        nv[idx] = 1'b1;
                        ns[idx] = fs[f];
                        nd[idx] = fd[f];
                    end
                end else if (off[SEQ_W-1]) begin
                    // seq is "behind" expected (top half of the modular circle)
                    // => a stale duplicate we already emitted; suppress it.
                    dup_n = dup_n + 1'b1;
                end else begin
                    // ahead of the window but not behind => beyond reorder depth
                    far_n = 1'b1;                  // dropped; feed jumped too far
                end
            end
        end

        // ---- DRAIN / GAP: at most one `expected` advance per clock --------
        eidx = nxt_expected[WIN_LOG2-1:0];
        if (nv[eidx]) begin
            // the in-order message is present -> forward it, free the slot
            out_valid_n  = 1'b1;
            out_seq_n    = ns[eidx];
            out_data_n   = nd[eidx];
            nv[eidx]     = 1'b0;
            nxt_expected = nxt_expected + 1'b1;
            nxt_timer    = 32'd0;
            fwd_n        = fwd_n + 1'b1;
        end else begin
            // hole at `expected`. Only a *real* gap if we already hold a later
            // message (we have positive evidence the seq exists and was lost).
            any_ahead = 1'b0;
            for (i = 0; i < WIN; i = i + 1)
                if (nv[i]) any_ahead = 1'b1;

            if (any_ahead) begin
                if (nxt_timer >= (GAP_TIMEOUT - 1)) begin
                    // waited long enough on both lines -> declare + skip the gap
                    gap_n        = 1'b1;
                    gap_seq_n    = nxt_expected;
                    nxt_expected = nxt_expected + 1'b1;
                    nxt_timer    = 32'd0;
                    gap_cnt_n    = gap_cnt_n + 1'b1;
                end else begin
                    nxt_timer = nxt_timer + 32'd1;
                end
            end else begin
                // nothing buffered ahead: just idle, no gap yet
                nxt_timer = 32'd0;
            end
        end
    end

    // ---- Registers -------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            expected  <= {SEQ_W{1'b0}};
            gap_timer <= 32'd0;
            out_valid <= 1'b0;
            out_seq   <= {SEQ_W{1'b0}};
            out_data  <= {DATA_W{1'b0}};
            gap_o     <= 1'b0;
            gap_seq_o <= {SEQ_W{1'b0}};
            far_o     <= 1'b0;
            stat_fwd_o <= {STAT_W{1'b0}};
            stat_dup_o <= {STAT_W{1'b0}};
            stat_gap_o <= {STAT_W{1'b0}};
            for (i = 0; i < WIN; i = i + 1)
                buf_v[i] <= 1'b0;
        end else begin
            expected  <= nxt_expected;
            gap_timer <= nxt_timer;
            for (i = 0; i < WIN; i = i + 1) begin
                buf_v[i] <= nv[i];
                buf_s[i] <= ns[i];
                buf_d[i] <= nd[i];
            end
            out_valid <= out_valid_n;
            out_seq   <= out_seq_n;
            out_data  <= out_data_n;
            gap_o     <= gap_n;
            gap_seq_o <= gap_seq_n;
            far_o     <= far_n;

            // saturating perf counters
            if (fwd_n != 0)
                stat_fwd_o <= (&stat_fwd_o[STAT_W-1:1]) ? stat_fwd_o : stat_fwd_o + fwd_n;
            if (dup_n != 0)
                stat_dup_o <= (&stat_dup_o[STAT_W-1:1]) ? stat_dup_o : stat_dup_o + dup_n;
            if (gap_cnt_n != 0)
                stat_gap_o <= (&stat_gap_o[STAT_W-1:1]) ? stat_gap_o : stat_gap_o + gap_cnt_n;
        end
    end

endmodule

`default_nettype wire
