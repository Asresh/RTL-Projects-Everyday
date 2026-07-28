//==============================================================================
// Module      : round_robin_arbiter
// Description : Parameterized N-way round-robin arbiter.
//               - Grants one requester per cycle (one-hot `grant`).
//               - Fair rotation: after granting requester g, priority on the
//                 next cycle starts at g+1 (wrapping), so no requester can be
//                 starved by a higher-priority neighbour.
//               - Purely combinational grant; a single registered priority
//                 mask holds the rotation state.
//               - Overflow/underflow-free: `grant` is all-zero when no request
//                 is asserted (`grant_valid` deasserted).
// Author      : Asresh Kuricheti
//==============================================================================
module round_robin_arbiter #(
    parameter int N = 4   // number of requesters (>= 2)
) (
    input  logic                   clk,          // system clock
    input  logic                   rst_n,        // active-low asynchronous reset
    input  logic [N-1:0]           req,          // request lines, one bit per requester
    output logic [N-1:0]           grant,        // one-hot grant (0 when idle)
    output logic                   grant_valid,  // high when a grant is issued
    output logic [$clog2(N)-1:0]   grant_index   // binary index of the granted requester
);

    // Priority mask: bits set here are "ahead" of the last-granted requester
    // and therefore have priority this cycle. Reset to all-ones so the first
    // arbitration is plain lowest-index priority.
    logic [N-1:0] mask;

    //--------------------------------------------------------------------------
    // Arbitration (combinational)
    //  - Prefer requesters inside the priority region (req & mask).
    //  - If none are pending there, wrap around and consider all requests.
    //  - "Isolate lowest set bit" trick picks a single winner: x & (~x + 1).
    //--------------------------------------------------------------------------
    logic [N-1:0] masked_req;
    logic [N-1:0] grant_masked;
    logic [N-1:0] grant_unmasked;

    assign masked_req     = req & mask;
    assign grant_masked   = masked_req & (~masked_req + 1'b1);
    assign grant_unmasked = req        & (~req + 1'b1);

    assign grant       = (|masked_req) ? grant_masked : grant_unmasked;
    assign grant_valid = |req;

    //--------------------------------------------------------------------------
    // One-hot -> binary encode of the granted requester.
    //--------------------------------------------------------------------------
    always_comb begin
        grant_index = '0;
        for (int i = 0; i < N; i++)
            if (grant[i])
                grant_index = $clog2(N)'(i);
    end

    //--------------------------------------------------------------------------
    // Rotation state update.
    // After granting one-hot bit g, set the mask so that only bits strictly
    // greater than g are prioritised next cycle:
    //     mask_next = ~((grant << 1) - 1)
    // Hold the mask on idle cycles (no request => no rotation).
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            mask <= '1;
        else if (grant_valid)
            mask <= ~((grant << 1) - 1'b1);
    end

endmodule
