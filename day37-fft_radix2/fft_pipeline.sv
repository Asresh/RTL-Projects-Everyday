// ---------------------------------------------------------------------------
// Day 37 : Fully-pipelined parallel Radix-2 DIT FFT  (fixed-point Q1.15 complex)
// ---------------------------------------------------------------------------
// A streaming, fully-unrolled N-point Fast Fourier Transform. Every clock it
// accepts one complete N-sample complex vector (all N samples in parallel) and,
// after a fixed LOG2N+1-cycle pipeline latency, emits the full N-bin complex
// spectrum -- one transform per clock, back-to-back, with no stalls.
//
//   * Decimation-in-time (DIT) radix-2 butterfly network:
//       - input is consumed in NATURAL order and internally bit-reversed
//         (pure wiring) so the output emerges in NATURAL bin order 0..N-1;
//       - LOG2N combinational butterfly stages, each followed by a pipeline
//         register bank, give one registered stage per FFT stage.
//   * The whole butterfly network is built with generate loops whose bounds are
//     ALL elaboration-time constants (group size, span and twiddle stride are
//     powers of two derived from the stage index), so the unrolled dataflow is
//     directly synthesizable -- no variable-bound procedural loops.
//   * The twiddle-factor ROM  W_N^k = e^(-j*2*pi*k/N)  is DERIVED AT ELABORATION
//     from cos/sin by a constant SystemVerilog function -- no hand-typed tables.
//   * Fixed-point Q1.15 (signed 1.15) data and twiddles. Each butterfly divides
//     its sum/difference by two, so the whole network scales the result by 1/N:
//     the output is the mathematically-exact DFT divided by N ("scaled FFT",
//     exactly the convention Xilinx/Intel streaming FFT cores use to guarantee
//     the datapath never overflows). Provided |input| <= 0.5 full-scale there is
//     no internal overflow.
//   * Complex multiply uses round-half-up on the Q1.15 re-quantisation.
//
// Latency  : LOG2N + 1 clocks (input register bank + LOG2N butterfly banks).
// Throughput: 1 complete N-point FFT per clock.
//
// Clean, reset-safe, lint-friendly SystemVerilog-2012; `default_nettype none`.
// ---------------------------------------------------------------------------
`default_nettype none

module fft_pipeline #(
    parameter int N     = 16,          // transform size (power of two)
    parameter int DW    = 16,          // sample word width (Q1.(DW-1) signed)
    parameter int LOG2N = 4            // = log2(N); keep consistent with N
)(
    input  wire                     clk,
    input  wire                     rst_n,      // active-low synchronous reset
    input  wire                     in_valid,   // 1 => a fresh vector this clock
    input  wire signed [N*DW-1:0]   in_re,      // packed real parts, sample n = [n*DW +: DW]
    input  wire signed [N*DW-1:0]   in_im,      // packed imag parts
    output wire                     out_valid,  // aligned with out_re/out_im
    output wire signed [N*DW-1:0]   out_re,     // packed real spectrum (natural bin order)
    output wire signed [N*DW-1:0]   out_im      // packed imag spectrum
);

    // Q1.(DW-1): +1.0 maps to (2^(DW-1)-1); shift amount for the twiddle multiply.
    localparam int TWSCALE = (1 << (DW-1)) - 1;   // 32767 for DW=16
    localparam int FRAC    = DW - 1;              // 15 fractional bits

    // -----------------------------------------------------------------------
    // Arithmetic helpers.
    //   cmul_* : complex multiply (wc+j*ws)*(br+j*bi) re-quantised to Q1.15
    //            with round-half-up.
    //   half   : divide a (DW+1)-bit sum by two with round-half-up.
    // -----------------------------------------------------------------------
    function automatic signed [DW-1:0] cmul_re
        (input signed [DW-1:0] wc, ws, br, bi);
        logic signed [2*DW:0] acc;
        acc = wc*br - ws*bi;                          // Q(2.30)-ish, +1 guard bit
        cmul_re = (acc + (1 <<< (FRAC-1))) >>> FRAC;  // round-half-up, >>15
    endfunction
    function automatic signed [DW-1:0] cmul_im
        (input signed [DW-1:0] wc, ws, br, bi);
        logic signed [2*DW:0] acc;
        acc = wc*bi + ws*br;
        cmul_im = (acc + (1 <<< (FRAC-1))) >>> FRAC;
    endfunction
    function automatic signed [DW-1:0] half(input signed [DW:0] x);
        half = (x + 1) >>> 1;                         // /2, round-half-up
    endfunction

    // -----------------------------------------------------------------------
    // Twiddle ROM  W_N^k = cos(-2*pi*k/N) + j*sin(-2*pi*k/N),  k = 0 .. N/2-1
    // Built at elaboration by a constant function (cos/sin folded by the tool at
    // compile time). Synthesis flows that cannot fold real system functions can
    // instead $readmemh an equivalent generated hex table -- the ROM is a pure
    // constant either way.
    // -----------------------------------------------------------------------
    function automatic signed [DW-1:0] tw_cos(input int k);
        real ang; ang = -2.0 * 3.141592653589793 * k / N;
        tw_cos = $rtoi($cos(ang) * TWSCALE);
    endfunction
    function automatic signed [DW-1:0] tw_sin(input int k);
        real ang; ang = -2.0 * 3.141592653589793 * k / N;
        tw_sin = $rtoi($sin(ang) * TWSCALE);
    endfunction

    wire signed [DW-1:0] romc [0:N/2-1];
    wire signed [DW-1:0] roms [0:N/2-1];
    genvar gk;
    generate
        for (gk = 0; gk < N/2; gk++) begin : g_twrom
            localparam signed [DW-1:0] CV = tw_cos(gk);
            localparam signed [DW-1:0] SV = tw_sin(gk);
            assign romc[gk] = CV;
            assign roms[gk] = SV;
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Bit-reversal of a LOG2N-bit index (natural -> DIT input order).
    // -----------------------------------------------------------------------
    function automatic int bitrev(input int idx);
        int r, i, x;
        begin
            r = 0; x = idx;
            for (i = 0; i < LOG2N; i++) begin r = (r << 1) | (x & 1); x = x >> 1; end
            bitrev = r;
        end
    endfunction

    // -----------------------------------------------------------------------
    // Pipeline register banks: sr/si[stage][sample].
    //   stage 0        : bit-reversed input (register bank 0)
    //   stage 1..LOG2N : butterfly outputs  (register banks 1..LOG2N)
    // -----------------------------------------------------------------------
    logic signed [DW-1:0] sr [0:LOG2N][0:N-1];
    logic signed [DW-1:0] si [0:LOG2N][0:N-1];
    logic                 vpipe [0:LOG2N];

    // ---- stage 0: register the input, permuted to bit-reversed order ------
    genvar gn0;
    generate
        for (gn0 = 0; gn0 < N; gn0++) begin : g_in
            localparam int SRC = bitrev(gn0);
            always_ff @(posedge clk) begin
                if (!rst_n) begin
                    sr[0][gn0] <= '0;
                    si[0][gn0] <= '0;
                end else begin
                    sr[0][gn0] <= in_re[SRC*DW +: DW];
                    si[0][gn0] <= in_im[SRC*DW +: DW];
                end
            end
        end
    endgenerate

    always_ff @(posedge clk)
        if (!rst_n) vpipe[0] <= 1'b0; else vpipe[0] <= in_valid;

    // -----------------------------------------------------------------------
    // Stages 1..LOG2N : radix-2 DIT butterflies. All loop bounds below are
    // elaboration-time constants (HALF/GRP/STEP are powers of two), so the
    // network fully unrolls into synthesizable structural logic.
    // -----------------------------------------------------------------------
    genvar gm, gb, gj;
    generate
        for (gm = 1; gm <= LOG2N; gm++) begin : g_stage
            localparam int HALF = 1 << (gm-1);   // butterfly span
            localparam int GRP  = 1 << gm;       // group size
            localparam int STEP = N >> gm;       // twiddle index stride

            for (gb = 0; gb < N; gb = gb + GRP) begin : g_group
                for (gj = 0; gj < HALF; gj++) begin : g_bf
                    localparam int TOP = gb + gj;
                    localparam int BOT = TOP + HALF;
                    localparam int TWI = gj * STEP;

                    // t = W_N^TWI * b   (b = lower input of this butterfly)
                    wire signed [DW-1:0] tr =
                        cmul_re(romc[TWI], roms[TWI], sr[gm-1][BOT], si[gm-1][BOT]);
                    wire signed [DW-1:0] ti =
                        cmul_im(romc[TWI], roms[TWI], sr[gm-1][BOT], si[gm-1][BOT]);

                    always_ff @(posedge clk) begin
                        if (!rst_n) begin
                            sr[gm][TOP] <= '0; si[gm][TOP] <= '0;
                            sr[gm][BOT] <= '0; si[gm][BOT] <= '0;
                        end else begin
                            // butterfly with /2 scaling (sign-extend to DW+1 bits)
                            sr[gm][TOP] <= half({sr[gm-1][TOP][DW-1], sr[gm-1][TOP]} + {tr[DW-1], tr});
                            si[gm][TOP] <= half({si[gm-1][TOP][DW-1], si[gm-1][TOP]} + {ti[DW-1], ti});
                            sr[gm][BOT] <= half({sr[gm-1][TOP][DW-1], sr[gm-1][TOP]} - {tr[DW-1], tr});
                            si[gm][BOT] <= half({si[gm-1][TOP][DW-1], si[gm-1][TOP]} - {ti[DW-1], ti});
                        end
                    end
                end
            end

            always_ff @(posedge clk)
                if (!rst_n) vpipe[gm] <= 1'b0; else vpipe[gm] <= vpipe[gm-1];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Pack the final stage into the output buses (natural bin order).
    // -----------------------------------------------------------------------
    genvar gn;
    generate
        for (gn = 0; gn < N; gn++) begin : g_pack
            assign out_re[gn*DW +: DW] = sr[LOG2N][gn];
            assign out_im[gn*DW +: DW] = si[LOG2N][gn];
        end
    endgenerate
    assign out_valid = vpipe[LOG2N];

endmodule

`default_nettype wire
