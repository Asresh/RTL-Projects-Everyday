// ============================================================================
// Day 36 : Hard-Decision Viterbi Decoder
// ----------------------------------------------------------------------------
// Maximum-likelihood decoder for a rate-1/2, constraint-length K=3
// convolutional code (the textbook (7,5)_8 code).  One received 2-bit symbol
// is consumed per valid clock; one decoded message bit is produced per valid
// clock after a fixed decode latency of TB_LEN symbols.
//
// Architecture (fully pipelined, one trellis stage per cycle):
//
//   * 2^(K-1) = 4 trellis states.  Each state keeps
//       - a path metric  pm[s]   (accumulated Hamming distance, PM_W bits)
//       - a survivor word surv[s] (TB_LEN-deep register-exchange history).
//   * Branch metrics are the Hamming distance between the received symbol and
//     the expected 2-bit codeword of every trellis edge, derived at elaboration
//     time from the generator polynomials G0/G1.
//   * Add-Compare-Select (ACS): for every next-state the two incoming edges are
//     added to their source path metrics, compared, and the smaller is kept.
//   * Survivor memory uses the register-exchange method: the winning source's
//     history is shifted left and the edge's input bit appended, so the decoded
//     bit falls out of the MSB after exactly TB_LEN stages.
//   * Per-cycle metric normalisation (subtract the running minimum) keeps the
//     path metrics bounded so PM_W never overflows on long streams.
//
// The decoder self-synchronises: reset biases all survivor paths into state 0,
// and the output is taken from whichever state currently holds the minimum
// path metric, so no explicit trellis termination is required.
//
// Fully synthesizable, reset-safe, lint-clean SystemVerilog-2012.
// ============================================================================
`default_nettype none

module viterbi_decoder #(
    parameter int unsigned G0     = 3'o7,  // generator poly 0 (octal 7 = 111)
    parameter int unsigned G1     = 3'o5,  // generator poly 1 (octal 5 = 101)
    parameter int unsigned TB_LEN = 16,    // survivor / traceback depth (symbols)
    parameter int unsigned PM_W   = 8      // path-metric register width (bits)
)(
    input  wire             clk,
    input  wire             rst_n,       // active-low synchronous reset

    input  wire             in_valid,    // received symbol is valid this cycle
    input  wire  [1:0]      sym_in,      // received 2-bit channel symbol {c0,c1}

    output reg              out_valid,   // decoded bit is valid this cycle
    output reg              bit_out,     // decoded message bit (TB_LEN-delayed)
    output wire  [1:0]      state_min    // current minimum-metric trellis state
);
    // ------------------------------------------------------------------------
    // Trellis constants derived from K=3 : 4 states, 2 edges leaving each.
    // State s encodes the two most recent input bits {sr1, sr0} = {s[1], s[0]}.
    // On input u the encoder shifts: next = {sr0, u} = {s[0], u}.
    // ------------------------------------------------------------------------
    localparam int unsigned NST = 4;   // number of states = 2^(K-1)

    // Expected 2-bit codeword produced on edge (state s, input u).
    // out0 uses G0, out1 uses G1 ; poly bit2=tap on current input, bit1=tap on
    // sr0, bit0=tap on sr1.
    function automatic [1:0] enc_out(input [1:0] s, input logic u);
        logic sr0, sr1, o0, o1;
        begin
            sr0 = s[0];
            sr1 = s[1];
            o0  = (G0[2] & u) ^ (G0[1] & sr0) ^ (G0[0] & sr1);
            o1  = (G1[2] & u) ^ (G1[1] & sr0) ^ (G1[0] & sr1);
            enc_out = {o0, o1};
        end
    endfunction

    // Hamming distance between two 2-bit symbols (0..2).
    function automatic [1:0] hdist(input [1:0] a, input [1:0] b);
        logic [1:0] x;
        begin
            x     = a ^ b;
            hdist = {1'b0, x[1]} + {1'b0, x[0]};
        end
    endfunction

    // Next-state ns = {a,b} has predecessors p = {0,a} and {1,a}, both driven by
    // input bit u = b (= ns[0]).
    function automatic [1:0] pred_of(input [1:0] ns, input logic hi);
        // hi selects sr1' (the upper predecessor bit); sr0' = ns[1].
        pred_of = {hi, ns[1]};
    endfunction

    // ------------------------------------------------------------------------
    // Registers : path metrics and survivor histories.
    // ------------------------------------------------------------------------
    reg  [PM_W-1:0]     pm   [NST];
    reg  [TB_LEN-1:0]   surv [NST];

    // Combinational next-state values.
    logic [PM_W-1:0]    npm   [NST];
    logic [TB_LEN-1:0]  nsurv [NST];

    // Startup ramp counter : output becomes valid after TB_LEN valid symbols.
    localparam int unsigned RAMP_W = (TB_LEN <= 1) ? 1 : $clog2(TB_LEN);
    reg  [RAMP_W:0]     ramp;
    wire                warmed = (ramp >= TB_LEN[RAMP_W:0]);

    // ------------------------------------------------------------------------
    // ACS : compute next path metrics and survivor words for every state.
    // ------------------------------------------------------------------------
    logic [PM_W:0]      cand0 [NST];   // one extra bit for add before compare
    logic [PM_W:0]      cand1 [NST];
    logic [1:0]         p0    [NST];
    logic [1:0]         p1    [NST];
    logic               ubit  [NST];   // input bit of the two incoming edges

    always_comb begin
        // running minimum for normalisation
        logic [PM_W-1:0] minpm;

        for (int ns = 0; ns < NST; ns++) begin
            logic [1:0] pa, pb;
            logic       u;
            logic [1:0] bm_a, bm_b;

            u  = ns[0];                       // input bit of both incoming edges
            pa = pred_of(ns[1:0], 1'b0);      // predecessor with sr1'=0
            pb = pred_of(ns[1:0], 1'b1);      // predecessor with sr1'=1

            bm_a = hdist(sym_in, enc_out(pa, u));
            bm_b = hdist(sym_in, enc_out(pb, u));

            cand0[ns] = {1'b0, pm[pa]} + {{(PM_W-1){1'b0}}, bm_a};
            cand1[ns] = {1'b0, pm[pb]} + {{(PM_W-1){1'b0}}, bm_b};
            p0[ns]    = pa;
            p1[ns]    = pb;
            ubit[ns]  = u;

            // compare-select
            if (cand1[ns] < cand0[ns]) begin
                npm[ns]   = cand1[ns][PM_W-1:0];
                nsurv[ns] = {surv[pb][TB_LEN-2:0], u};
            end else begin
                npm[ns]   = cand0[ns][PM_W-1:0];
                nsurv[ns] = {surv[pa][TB_LEN-2:0], u};
            end
        end

        // find running minimum path metric across the 4 next states
        minpm = npm[0];
        for (int s = 1; s < NST; s++)
            if (npm[s] < minpm) minpm = npm[s];

        // normalise (subtract the minimum) to keep metrics bounded
        for (int s = 0; s < NST; s++)
            npm[s] = npm[s] - minpm;
    end

    // ------------------------------------------------------------------------
    // Minimum-metric state selection for the survivor read-out.
    // ------------------------------------------------------------------------
    logic [1:0] argmin;
    always_comb begin
        logic [PM_W-1:0] best;
        argmin = 2'd0;
        best   = pm[0];
        for (int s = 1; s < NST; s++)
            if (pm[s] < best) begin
                best   = pm[s];
                argmin = s[1:0];
            end
    end
    assign state_min = argmin;

    // ------------------------------------------------------------------------
    // Sequential update.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int s = 0; s < NST; s++) begin
                // bias state 0 to metric 0, all others to a large metric so the
                // trellis starts (and stays) anchored at the encoder's init state
                pm[s]   <= (s == 0) ? '0 : {PM_W{1'b1}};
                surv[s] <= '0;
            end
            ramp      <= '0;
            out_valid <= 1'b0;
            bit_out   <= 1'b0;
        end else if (in_valid) begin
            for (int s = 0; s < NST; s++) begin
                pm[s]   <= npm[s];
                surv[s] <= nsurv[s];
            end
            // ramp saturates at TB_LEN
            if (!warmed) ramp <= ramp + 1'b1;

            out_valid <= warmed;
            bit_out   <= surv[argmin][TB_LEN-1];  // oldest bit of the best path
        end else begin
            out_valid <= 1'b0;                    // no new symbol -> no new bit
        end
    end
endmodule

`default_nettype wire
