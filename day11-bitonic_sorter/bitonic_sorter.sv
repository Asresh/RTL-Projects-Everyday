// =============================================================================
// Day 11 : bitonic_sorter
// -----------------------------------------------------------------------------
// A fully-pipelined, parameterizable BITONIC SORTING NETWORK.
//
// A sorting network sorts a fixed-size vector of N keys using a data-independent
// arrangement of compare-exchange (CE) elements.  The bitonic construction is
// the classic parallel-hardware sorter: it has
//
//        S = L*(L+1)/2   pipeline stages           (L = log2(N))
//        (N/2) * S        compare-exchange elements
//
// e.g. N = 8  ->  L = 3, S = 6 stages, 24 CE elements.
//
// This implementation:
//   * is fully unrolled and pipelined -- one CE stage per pipeline register,
//     so it accepts a brand-new input vector every clock and produces a sorted
//     vector every clock after the fixed fill latency LATENCY = S + 1;
//   * is data-independent (no data-dependent control -> constant latency, no
//     stalls, trivially timing-closable);
//   * supports SIGNED or unsigned keys and ASCENDING or descending order;
//   * derives the whole network from N at elaboration time via constant
//     functions -- no hand-drawn wiring tables.
//
// The classic bitonic recurrence (0-indexed, ascending) is:
//
//   for (k = 2; k <= N; k <<= 1)             // size of bitonic sub-sequence
//     for (j = k >> 1; j > 0; j >>= 1)       // CE distance  -> one stage each
//       for (i = 0; i < N; i++)
//         l = i ^ j;                         // CE partner
//         if (l > i)
//           ascending_pair = ((i & k) == 0);
//           compare_exchange(a[i], a[l], ascending_pair);
//
// Each (k, j) pair is exactly one pipeline stage of this module.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module bitonic_sorter #(
    parameter int  N         = 8,     // # of keys, MUST be a power of two, >= 2
    parameter int  DW        = 16,    // key width in bits
    parameter bit  SIGNED    = 1'b0,  // 1 = interpret keys as two's-complement
    parameter bit  ASCENDING = 1'b1   // 1 = smallest key ends up at index 0
) (
    input  wire                  clk,
    input  wire                  rst_n,      // active-low synchronous-ish reset

    input  wire                  in_valid,   // in_data is a fresh vector this cycle
    input  wire  [N-1:0][DW-1:0] in_data,    // unsorted input vector

    output wire                  out_valid,  // out_data is a valid sorted vector
    output wire  [N-1:0][DW-1:0] out_data    // sorted output vector
);

    // -------------------------------------------------------------------------
    // Network geometry (all resolved at elaboration).
    // -------------------------------------------------------------------------
    localparam int L = $clog2(N);        // number of comparator "levels"
    localparam int S = (L * (L + 1)) / 2; // total pipeline stages (CE columns)

    // Stage s belongs to group p (the outer bitonic size k = 2^(p+1)).
    // Group p contains (p+1) stages; group start index = p*(p+1)/2.
    function automatic int p_of_stage(input int s);
        int p;
        p = 0;
        while (((p + 1) * (p + 2)) / 2 <= s) p = p + 1;
        return p;
    endfunction

    // k for a stage = 2^(p+1); j for a stage = 2^(p - m), m = position in group.
    function automatic int k_of_stage(input int s);
        int p;
        p = p_of_stage(s);
        return (1 << (p + 1));
    endfunction

    function automatic int j_of_stage(input int s);
        int p, m;
        p = p_of_stage(s);
        m = s - ((p * (p + 1)) / 2);
        return (1 << (p - m));
    endfunction

    // -------------------------------------------------------------------------
    // Elaboration-time sanity check: N must be a power of two.
    // -------------------------------------------------------------------------
    initial begin
        if ((1 << L) != N)
            $error("bitonic_sorter: N (%0d) must be a power of two", N);
        if (N < 2)
            $error("bitonic_sorter: N (%0d) must be >= 2", N);
    end

    // -------------------------------------------------------------------------
    // Pipeline storage.
    //   stg[0]      = registered input vector
    //   stg[s+1]    = registered output of network stage s
    //   comb[s]     = combinational output of network stage s (fed from stg[s])
    // -------------------------------------------------------------------------
    logic [N-1:0][DW-1:0] stg  [0:S];
    logic [N-1:0][DW-1:0] comb [0:S-1];
    logic [S:0]           vpipe;   // valid bit travelling alongside the data

    // -------------------------------------------------------------------------
    // Combinational compare-exchange fabric, generated stage by stage.
    // -------------------------------------------------------------------------
    genvar gs, gi;
    generate
        for (gs = 0; gs < S; gs = gs + 1) begin : g_stage
            localparam int KK = k_of_stage(gs);
            localparam int JJ = j_of_stage(gs);

            for (gi = 0; gi < N; gi = gi + 1) begin : g_ce
                localparam int  PARTNER  = gi ^ JJ;
                // Am I the lower-indexed lane of my CE pair?
                localparam bit  IS_LOW   = ((gi & JJ) == 0);
                // Ascending direction for THIS pair (fold in ASCENDING knob).
                localparam bit  WANT_ASC = ASCENDING ? ((gi & KK) == 0)
                                                      : ((gi & KK) != 0);

                wire [DW-1:0] a = stg[gs][gi];
                wire [DW-1:0] b = stg[gs][PARTNER];

                // key comparison (signed or unsigned)
                wire a_gt_b = SIGNED ? ($signed(a) > $signed(b))
                                     : (a > b);

                wire [DW-1:0] hi = a_gt_b ? a : b;   // larger key
                wire [DW-1:0] lo = a_gt_b ? b : a;   // smaller key

                // A lane that wants the smaller key keeps `lo`, else `hi`.
                // "wants smaller" == (WANT_ASC && IS_LOW) || (!WANT_ASC && !IS_LOW)
                //                 == (WANT_ASC == IS_LOW)
                assign comb[gs][gi] = (WANT_ASC == IS_LOW) ? lo : hi;
            end
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Pipeline registers.
    // -------------------------------------------------------------------------
    integer s;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe <= '0;
            for (s = 0; s <= S; s = s + 1)
                stg[s] <= '0;
        end else begin
            // input stage
            stg[0]   <= in_data;
            vpipe[0] <= in_valid;
            // network stages
            for (s = 0; s < S; s = s + 1) begin
                stg[s+1]   <= comb[s];
                vpipe[s+1] <= vpipe[s];
            end
        end
    end

    assign out_data  = stg[S];
    assign out_valid = vpipe[S];

endmodule

`default_nettype wire
