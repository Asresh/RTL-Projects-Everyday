// ============================================================================
// sparse_dot2of4.sv -- Pipelined 2:4 Structured-Sparsity Dot-Product Engine
// ============================================================================
// Each group contains four dense activations but only two non-zero weights.
// Two 2-bit metadata indices select the activations paired with the compressed
// weights.  The engine accepts one complete fragment every cycle and implements
// a three-cycle decode/select -> multiply -> reduction pipeline.
//
// Invalid metadata (duplicate indices) is reported and that group's numerical
// contribution is forced to zero so malformed work cannot silently double-count
// an activation.  All arithmetic is signed two's-complement.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module sparse_dot2of4 #(
    parameter int GROUPS = 4,
    parameter int DW     = 8,
    parameter int PROD_W = 2 * DW,
    parameter int SUM_W  = PROD_W + $clog2(2 * GROUPS) + 1
) (
    input  wire                           clk,
    input  wire                           rst_n,
    input  wire                           in_valid,
    input  wire [GROUPS*4*DW-1:0]         dense_a,
    input  wire [GROUPS*2*DW-1:0]         sparse_w,
    input  wire [GROUPS*4-1:0]            meta,
    output logic                          out_valid,
    output logic signed [SUM_W-1:0]       dot_product,
    output logic                          meta_error
);

    localparam int TERMS = 2 * GROUPS;

    // Stage 0: metadata decode and dense-activation selection.
    logic signed [DW-1:0] act_s0 [0:TERMS-1];
    logic signed [DW-1:0] wgt_s0 [0:TERMS-1];
    logic                  valid_s0;
    logic                  error_s0;

    // Stage 1: one signed multiplier per stored non-zero weight.
    logic signed [PROD_W-1:0] prod_s1 [0:TERMS-1];
    logic                      valid_s1;
    logic                      error_s1;

    // Stage 2: local reduction per 2:4 group.
    logic signed [PROD_W:0] group_sum_s2 [0:GROUPS-1];
    logic                     valid_s2;
    logic                     error_s2;
    logic signed [SUM_W-1:0] final_sum;

    integer g;
    integer t;

    function automatic signed [DW-1:0] select4(
        input logic [4*DW-1:0] values,
        input logic [1:0]      index
    );
        select4 = values[index*DW +: DW];
    endfunction

    always_comb begin
        final_sum = '0;
        for (int rg = 0; rg < GROUPS; rg = rg + 1)
            final_sum = final_sum +
                {{(SUM_W-(PROD_W+1)){group_sum_s2[rg][PROD_W]}},
                 group_sum_s2[rg]};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_s0   <= 1'b0;
            valid_s1   <= 1'b0;
            valid_s2   <= 1'b0;
            out_valid  <= 1'b0;
            error_s0   <= 1'b0;
            error_s1   <= 1'b0;
            error_s2   <= 1'b0;
            meta_error <= 1'b0;
            dot_product <= '0;
            for (t = 0; t < TERMS; t = t + 1) begin
                act_s0[t]  <= '0;
                wgt_s0[t]  <= '0;
                prod_s1[t] <= '0;
            end
            for (g = 0; g < GROUPS; g = g + 1)
                group_sum_s2[g] <= '0;
        end else begin
            // Valid and error bits travel alongside their data stages.
            valid_s0   <= in_valid;
            valid_s1   <= valid_s0;
            valid_s2   <= valid_s1;
            out_valid  <= valid_s2;
            error_s1   <= error_s0;
            error_s2   <= error_s1;
            meta_error <= error_s2;

            // Stage 0 -- select the two dense operands named by each group.
            error_s0 <= 1'b0;
            for (g = 0; g < GROUPS; g = g + 1) begin
                wgt_s0[2*g]   <= sparse_w[(2*g)*DW +: DW];
                wgt_s0[2*g+1] <= sparse_w[(2*g+1)*DW +: DW];

                if (meta[g*4 +: 2] == meta[g*4+2 +: 2]) begin
                    // Containment policy for malformed 2:4 metadata.
                    act_s0[2*g]   <= '0;
                    act_s0[2*g+1] <= '0;
                    if (in_valid)
                        error_s0 <= 1'b1;
                end else begin
                    act_s0[2*g] <= select4(
                        dense_a[g*4*DW +: 4*DW], meta[g*4 +: 2]);
                    act_s0[2*g+1] <= select4(
                        dense_a[g*4*DW +: 4*DW], meta[g*4+2 +: 2]);
                end
            end

            // Stage 1 -- signed parallel products.
            for (t = 0; t < TERMS; t = t + 1)
                prod_s1[t] <= act_s0[t] * wgt_s0[t];

            // Stage 2 -- pairwise local sums, widened by one bit.
            for (g = 0; g < GROUPS; g = g + 1)
                group_sum_s2[g] <=
                    {{1{prod_s1[2*g][PROD_W-1]}}, prod_s1[2*g]} +
                    {{1{prod_s1[2*g+1][PROD_W-1]}}, prod_s1[2*g+1]};

            // Stage 3 -- final cross-group reduction. SUM_W is sized so the
            // complete dot product cannot overflow for legal DW/GROUPS values.
            dot_product <= final_sum;
        end
    end

endmodule

`default_nettype wire
