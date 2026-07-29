// -----------------------------------------------------------------------------
// Day 9 : cordic_sincos  --  pipelined CORDIC sine/cosine engine
// -----------------------------------------------------------------------------
// A fully-pipelined, fixed-point **CORDIC** (COordinate Rotation DIgital
// Computer) rotation-mode engine that computes cos(theta) and sin(theta) for an
// input angle in radians, one result per clock after a fixed pipeline latency.
// No multipliers are used -- only adders and hard-wired shifts -- which is the
// whole point of CORDIC and what makes it a classic building block for DSP,
// SDR, motor control and graphics hardware.
//
// FIXED-POINT FORMAT (signed two's complement, WIDTH bits):
//   Q(2.FRAC) with FRAC = WIDTH-3, i.e. 1 sign bit + 2 integer bits + FRAC
//   fractional bits, representing the range [-4.0, +4.0).  This holds angles up
//   to +/-pi (3.14159...) and the [-1,1] sine/cosine outputs with head-room.
//
// ALGORITHM (rotation mode) -- drive z toward 0 by micro-rotations:
//   d_i = (z_i >= 0) ? +1 : -1
//   x_{i+1} = x_i - d_i * (y_i >> i)
//   y_{i+1} = y_i + d_i * (x_i >> i)
//   z_{i+1} = z_i - d_i * atan(2^-i)
// After ITER iterations z_i -> 0 and, seeding x_0 = 1/K, y_0 = 0, z_0 = theta:
//   x_N -> cos(theta),   y_N -> sin(theta)
// where K = prod( sqrt(1 + 2^-2i) ) ~= 1.6467602581 is the CORDIC gain; we
// pre-scale the seed by 1/K = 0.6072529350 so no output rescale is needed.
//
// CONVERGENCE / QUADRANT FOLDING:
//   Rotation-mode CORDIC only converges for |z_0| <= ~1.7433 rad (99.9 deg).
//   To accept the full [-pi, pi] input range, a pre-rotation stage folds the
//   angle into [-pi/2, +pi/2]:
//     theta >  pi/2 : z0 = theta - pi,  negate = 1
//     theta < -pi/2 : z0 = theta + pi,  negate = 1
//     otherwise     : z0 = theta,       negate = 0
//   cos/sin of the folded angle are then negated when `negate` is set, since
//   cos(a +/- pi) = -cos(a) and sin(a +/- pi) = -sin(a).
//
// MICRO-ARCHITECTURE:
//   Fully-unrolled feed-forward pipeline: 1 load/fold stage + ITER rotation
//   stages.  A `negate` flag and a `valid` flag ride alongside the datapath, so
//   the block accepts a new angle every clock and produces a matching result
//   OUT_LATENCY = ITER+1 cycles later.  Magnitude stays within [1/K, 1.0]
//   throughout, so WIDTH bits suffice with no accumulator growth.
//
//   atan(2^-i) constants are materialised from exact real values into the
//   fixed-point format at elaboration (constant function + round-to-nearest),
//   so the LUT tracks any WIDTH/FRAC choice automatically.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module cordic_sincos #(
    parameter int WIDTH = 16,      // fixed-point word width (>= 8)
    parameter int ITER  = 12       // pipeline / rotation stages (<= 24, <= FRAC)
) (
    input  wire                     clk,
    input  wire                     rst_n,      // active-low synchronous reset

    input  wire                     in_valid,   // assert with a new angle
    input  wire signed [WIDTH-1:0]  theta,      // Q2.FRAC radians, [-pi, pi]

    output wire                     out_valid,  // result valid (pipeline aligned)
    output wire signed [WIDTH-1:0]  cos_o,      // Q2.FRAC cos(theta)
    output wire signed [WIDTH-1:0]  sin_o       // Q2.FRAC sin(theta)
);
    // ------------------------------------------------------------------ format
    localparam int FRAC = WIDTH - 3;               // fractional bits

    // real -> fixed-point (round to nearest, ties away from zero)
    function automatic signed [WIDTH-1:0] to_fx(input real r);
        to_fx = $rtoi(r * (2.0 ** FRAC) + (r >= 0.0 ? 0.5 : -0.5));
    endfunction

    // exact atan(2^-i) in radians (25 entries: covers ITER up to 24)
    function automatic real atan_r(input int i);
        case (i)
            0 : atan_r = 0.78539816339744830961;  1 : atan_r = 0.46364760900080611621;
            2 : atan_r = 0.24497866312686415417;  3 : atan_r = 0.12435499454676143503;
            4 : atan_r = 0.06241880999595734847;  5 : atan_r = 0.03123983343026827633;
            6 : atan_r = 0.01562372862047683080;  7 : atan_r = 0.00781234106010111111;
            8 : atan_r = 0.00390623013196697182;  9 : atan_r = 0.00195312251647881870;
            10: atan_r = 0.00097656218955931946;  11: atan_r = 0.00048828121119489828;
            12: atan_r = 0.00024414062014936177;  13: atan_r = 0.00012207031189367021;
            14: atan_r = 0.00006103515617420877;  15: atan_r = 0.00003051757811552610;
            16: atan_r = 0.00001525878906131576;  17: atan_r = 0.00000762939453110197;
            18: atan_r = 0.00000381469726560650;  19: atan_r = 0.00000190734863281019;
            20: atan_r = 0.00000095367431640596;  21: atan_r = 0.00000047683715820309;
            22: atan_r = 0.00000023841857910156;  23: atan_r = 0.00000011920928955078;
            default: atan_r = 0.0;
        endcase
    endfunction

    // ---------------------------------------------------------------- constants
    localparam signed [WIDTH-1:0] KINV    = to_fx(0.60725293500888125616); // 1/K
    localparam signed [WIDTH-1:0] HALF_PI = to_fx(1.57079632679489661923); // pi/2
    localparam signed [WIDTH-1:0] PI_FX   = to_fx(3.14159265358979323846); // pi

    // atan LUT in fixed-point, generated from the exact reals above
    wire signed [WIDTH-1:0] atan_lut [0:ITER-1];
    genvar gi;
    generate
        for (gi = 0; gi < ITER; gi = gi + 1) begin : g_lut
            assign atan_lut[gi] = to_fx(atan_r(gi));
        end
    endgenerate

    // ------------------------------------------------------ pipeline registers
    // index 0 = seeded/folded stage, index k = after k rotations, ITER = output
    reg signed [WIDTH-1:0] x_p   [0:ITER];
    reg signed [WIDTH-1:0] y_p   [0:ITER];
    reg signed [WIDTH-1:0] z_p   [0:ITER];
    reg                    neg_p [0:ITER];
    reg                    vld_p [0:ITER];

    // -------------------------------------------------- input quadrant folding
    reg signed [WIDTH-1:0] z0;
    reg                    neg0;
    always @* begin
        if (theta > HALF_PI) begin              // 2nd quadrant -> fold by -pi
            z0   = theta - PI_FX;
            neg0 = 1'b1;
        end else if (theta < -HALF_PI) begin    // 3rd quadrant -> fold by +pi
            z0   = theta + PI_FX;
            neg0 = 1'b1;
        end else begin                          // already in [-pi/2, pi/2]
            z0   = theta;
            neg0 = 1'b0;
        end
    end

    // --------------------------------------------------------- pipeline update
    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            for (k = 0; k <= ITER; k = k + 1) vld_p[k] <= 1'b0;
        end else begin
            // stage 0 : seed the rotator with the folded angle
            x_p[0]   <= KINV;
            y_p[0]   <= '0;
            z_p[0]   <= z0;
            neg_p[0] <= neg0;
            vld_p[0] <= in_valid;

            // stages 1..ITER : one CORDIC micro-rotation each
            for (k = 0; k < ITER; k = k + 1) begin
                if (!z_p[k][WIDTH-1]) begin     // z >= 0 : rotate by -atan (d=+1)
                    x_p[k+1] <= x_p[k] - (y_p[k] >>> k);
                    y_p[k+1] <= y_p[k] + (x_p[k] >>> k);
                    z_p[k+1] <= z_p[k] - atan_lut[k];
                end else begin                  // z <  0 : rotate by +atan (d=-1)
                    x_p[k+1] <= x_p[k] + (y_p[k] >>> k);
                    y_p[k+1] <= y_p[k] - (x_p[k] >>> k);
                    z_p[k+1] <= z_p[k] + atan_lut[k];
                end
                neg_p[k+1] <= neg_p[k];
                vld_p[k+1] <= vld_p[k];
            end
        end
    end

    // ---------------------------------------------------- output sign fold-back
    assign cos_o     = neg_p[ITER] ? -x_p[ITER] : x_p[ITER];
    assign sin_o     = neg_p[ITER] ? -y_p[ITER] : y_p[ITER];
    assign out_valid = vld_p[ITER];

endmodule

`default_nettype wire
