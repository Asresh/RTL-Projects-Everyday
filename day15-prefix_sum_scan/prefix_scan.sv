// ===========================================================================
// prefix_scan.sv  --  Pipelined Kogge-Stone parallel prefix-sum (scan) engine
// ---------------------------------------------------------------------------
// A warp-level SIMD scan primitive of the kind GPUs use to accelerate stream
// compaction, radix-sort digit histograms and sparse (segmented) reductions.
//
//   * N lanes processed in parallel, one input vector accepted every clock.
//   * Kogge-Stone network: shallow log2(N)-deep chain of combine stages, each
//     stage separated by a pipeline register -> latency = log2(N) cycles,
//     throughput = 1 vector / cycle.
//   * SEGMENTED inclusive scan: each lane carries a "segment head" flag; the
//     running sum restarts at every segment boundary.  With all head flags 0
//     this degenerates to an ordinary full-vector inclusive prefix sum, so the
//     one datapath serves both plain and segmented scan.
//   * SIGNED or UNSIGNED elements.  The result lanes are widened to
//     WACC = W + clog2(N) bits so a full N-element sum never overflows.
//
// Segmented-scan combine operator (left = earlier lane, right = current lane):
//     value = flag_right ? value_right : value_left + value_right
//     flag  = flag_left | flag_right
// Applying this across Kogge-Stone distances 1,2,4,... gives, for lane i, the
// inclusive sum of all lanes j<=i that lie in the same segment as lane i.
// ===========================================================================
`timescale 1ns/1ps

module prefix_scan #(
    parameter int N      = 8,   // number of parallel lanes (power of two, >=2)
    parameter int W      = 12,  // element width (bits)
    parameter bit SIGNED = 1    // 1 = signed elements, 0 = unsigned
) (
    input  logic                       clk,
    input  logic                       rst_n,

    input  logic                       in_valid,   // input vector is valid
    input  logic [N*W-1:0]             in_data,    // N packed elements, lane 0 = LSBs
    input  logic [N-1:0]               in_seg,     // per-lane segment-head flag

    output logic                       out_valid,  // scan result is valid
    output logic [N*(W+$clog2(N))-1:0] out_data,   // N packed prefix sums
    output logic [N-1:0]               out_seg     // per-lane segment flag (post-scan)
);

    // ---- derived parameters ------------------------------------------------
    localparam int S    = $clog2(N);       // number of Kogge-Stone stages
    localparam int WACC = W + $clog2(N);   // widened accumulator width

    // ---- sign/zero extend one raw lane to the accumulator width ------------
    // A function (not a continuous-assign net) so the stage-1 flip-flops sample
    // the live input at the clock edge with no delta-cycle skew.
    function automatic logic signed [WACC-1:0] extend(input logic [W-1:0] r);
        extend = SIGNED ? {{(WACC-W){r[W-1]}}, r}    // sign-extend
                        : {{(WACC-W){1'b0}},   r};   // zero-extend
    endfunction

    // ---- registered Kogge-Stone pipeline (stages 1..S) ---------------------
    // pv[k]/pf[k] hold the value/flag after the k-th combine step.
    logic signed [WACC-1:0] pv [1:S][0:N-1];
    logic                   pf [1:S][0:N-1];
    logic [S:1]             vpipe;

    genvar gs, gl;
    generate
        for (gs = 1; gs <= S; gs++) begin : g_stage
            localparam int DIST = (1 << (gs-1));   // combine distance for this stage
            for (gl = 0; gl < N; gl++) begin : g_lane
                if (gs == 1) begin : g_from_in
                    // stage 1 reads the module inputs directly (through extend()).
                    always_ff @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            pv[gs][gl] <= '0;
                            pf[gs][gl] <= 1'b0;
                        end else if ((gl >= DIST) && !in_seg[gl]) begin
                            pv[gs][gl] <= extend(in_data[gl*W +: W])
                                        + extend(in_data[(gl-DIST)*W +: W]);
                            pf[gs][gl] <= in_seg[gl] | in_seg[gl-DIST];
                        end else begin
                            pv[gs][gl] <= extend(in_data[gl*W +: W]);
                            pf[gs][gl] <= in_seg[gl];
                        end
                    end
                end else begin : g_from_reg
                    // later stages read the previous registered stage.
                    always_ff @(posedge clk or negedge rst_n) begin
                        if (!rst_n) begin
                            pv[gs][gl] <= '0;
                            pf[gs][gl] <= 1'b0;
                        end else if ((gl >= DIST) && !pf[gs-1][gl]) begin
                            pv[gs][gl] <= pv[gs-1][gl] + pv[gs-1][gl-DIST];
                            pf[gs][gl] <= pf[gs-1][gl] | pf[gs-1][gl-DIST];
                        end else begin
                            pv[gs][gl] <= pv[gs-1][gl];
                            pf[gs][gl] <= pf[gs-1][gl];
                        end
                    end
                end
            end
        end
    endgenerate

    // ---- valid shift register ----------------------------------------------
    integer k;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe <= '0;
        end else begin
            vpipe[1] <= in_valid;
            for (k = 2; k <= S; k = k + 1)
                vpipe[k] <= vpipe[k-1];
        end
    end

    // ---- pack outputs from the final registered stage ----------------------
    genvar go;
    generate
        for (go = 0; go < N; go++) begin : g_pack
            assign out_data[go*WACC +: WACC] = pv[S][go];
            assign out_seg[go]               = pf[S][go];
        end
    endgenerate

    assign out_valid = vpipe[S];

endmodule
