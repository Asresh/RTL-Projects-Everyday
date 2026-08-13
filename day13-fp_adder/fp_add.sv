// -----------------------------------------------------------------------------
// Day 13 : fp_add
// Pipelined IEEE-754 binary32 floating-point adder / subtractor
//
// A 3-stage pipeline that computes  result = a + b  (or a - b) for
// IEEE-754 single-precision numbers, fully rounded to nearest-even and with
// correct handling of the hard cases real hardware must get right:
//
//   * gradual underflow  (subnormal inputs AND subnormal results)
//   * signed zeros       (x + (-x) -> +0 ; -0 + -0 -> -0)
//   * infinities         (Inf + Inf, Inf - Inf -> NaN, etc.)
//   * NaN propagation    (any NaN input -> canonical quiet NaN)
//   * guard / round / sticky bit rounding (round-to-nearest, ties-to-even)
//   * overflow to Inf and mantissa carry-out on rounding
//
// Throughput : 1 add / clock.   Latency : 3 clocks.
//
// The datapath is written width-generically (EXP_W / MAN_W parameters) so the
// same code elaborates a bfloat16 or a binary64 adder; the defaults are the
// binary32 fields (8 exponent, 23 fraction).
// -----------------------------------------------------------------------------
`default_nettype none

module fp_add #(
    parameter int EXP_W = 8,                 // exponent width  (binary32 = 8)
    parameter int MAN_W = 23                 // fraction width  (binary32 = 23)
) (
    input  wire                       clk,
    input  wire                       rst_n,      // active-low sync reset
    input  wire                       in_valid,   // a/b are a fresh operand pair
    input  wire                       sub,        // 0: a+b   1: a-b
    input  wire  [EXP_W+MAN_W:0]      a,          // operand A (IEEE bit pattern)
    input  wire  [EXP_W+MAN_W:0]      b,          // operand B (IEEE bit pattern)
    output logic                      out_valid,  // result is valid this cycle
    output logic [EXP_W+MAN_W:0]      result      // a (+/-) b, IEEE bit pattern
);

    // ---- derived constants --------------------------------------------------
    localparam int W      = 1 + EXP_W + MAN_W;   // total width
    localparam int SIG    = MAN_W + 1;           // significand incl. hidden bit
    localparam int AW     = SIG + 3;             // significand + guard/round/sticky
    localparam int EXPMAX = (1 << EXP_W) - 1;    // all-ones exponent (Inf/NaN)
    localparam int EW     = EXP_W + 2;           // signed working-exponent width

    // canonical quiet NaN : sign 0, exp all-ones, MSB of fraction set
    localparam logic [W-1:0] QNAN = {1'b0, {EXP_W{1'b1}}, 1'b1, {(MAN_W-1){1'b0}}};

    // -------------------------------------------------------------------------
    // count-leading-zeros over an AW-bit vector (0..AW)
    // -------------------------------------------------------------------------
    function int clz(input logic [AW-1:0] v);
        int   i;
        logic found;
        begin
            clz   = AW;                     // all-zero => AW
            found = 1'b0;
            for (i = AW-1; i >= 0; i--)
                if (!found && v[i]) begin
                    clz   = AW-1 - i;
                    found = 1'b1;
                end
        end
    endfunction

    // =========================================================================
    // Stage 1 : unpack, classify specials, select big/small, align mantissas
    // =========================================================================
    // packed field views of the inputs
    logic                 sa, sb;            // effective signs (sub flips b)
    logic [EXP_W-1:0]     ea, eb;
    logic [MAN_W-1:0]     ma, mb;

    assign sa = a[W-1];
    assign sb = b[W-1] ^ sub;               // subtract == add with b negated
    assign ea = a[W-2 -: EXP_W];
    assign eb = b[W-2 -: EXP_W];
    assign ma = a[MAN_W-1:0];
    assign mb = b[MAN_W-1:0];

    // classification
    logic a_zero, b_zero, a_inf, b_inf, a_nan, b_nan;
    assign a_zero = (ea == 0)      && (ma == 0);
    assign b_zero = (eb == 0)      && (mb == 0);
    assign a_inf  = (ea == EXPMAX) && (ma == 0);
    assign b_inf  = (eb == EXPMAX) && (mb == 0);
    assign a_nan  = (ea == EXPMAX) && (ma != 0);
    assign b_nan  = (eb == EXPMAX) && (mb != 0);

    // special (non-arithmetic) result and its valid flag
    logic [W-1:0] s1_special;
    logic         s1_is_special;
    always_comb begin
        s1_is_special = 1'b1;
        s1_special    = QNAN;
        if (a_nan || b_nan) begin
            s1_special = QNAN;                                  // NaN propagates
        end else if (a_inf && b_inf) begin
            s1_special = (sa != sb) ? QNAN                      // Inf - Inf
                                    : {sa, {EXP_W{1'b1}}, {MAN_W{1'b0}}};
        end else if (a_inf) begin
            s1_special = {sa, {EXP_W{1'b1}}, {MAN_W{1'b0}}};
        end else if (b_inf) begin
            s1_special = {sb, {EXP_W{1'b1}}, {MAN_W{1'b0}}};
        end else begin
            s1_is_special = 1'b0;                               // arithmetic path
        end
    end

    // effective (unbiased-in-place) exponent and full significand of each operand
    logic [EXP_W-1:0] eea, eeb;                 // 0-exp subnormals read as exp 1
    logic [SIG-1:0]   siga, sigb;
    assign eea  = (ea == 0) ? {{(EXP_W-1){1'b0}}, 1'b1} : ea;
    assign eeb  = (eb == 0) ? {{(EXP_W-1){1'b0}}, 1'b1} : eb;
    assign siga = {(ea != 0), ma};             // hidden bit = (exp != 0)
    assign sigb = {(eb != 0), mb};

    // choose the operand with the larger magnitude as "big"
    logic a_is_big;
    assign a_is_big = (eea > eeb) || ((eea == eeb) && (siga >= sigb));

    logic             big_sign, small_sign;
    logic [EXP_W-1:0] big_exp;
    logic [SIG-1:0]   big_sig, small_sig;
    logic [EXP_W-1:0] exp_diff;

    always_comb begin
        if (a_is_big) begin
            big_sign = sa; small_sign = sb;
            big_exp  = eea;
            big_sig  = siga; small_sig = sigb;
            exp_diff = eea - eeb;
        end else begin
            big_sign = sb; small_sign = sa;
            big_exp  = eeb;
            big_sig  = sigb; small_sig = siga;
            exp_diff = eeb - eea;
        end
    end

    // align: big keeps 3 low guard bits; small is shifted right, OR-ing every
    // bit that falls off the bottom into the sticky bit (bit 0).
    logic [AW-1:0] a_big_al, a_small_al;
    always_comb begin
        logic [AW-1:0] small_ext;
        logic          sticky;
        small_ext = {small_sig, 3'b000};
        a_big_al  = {big_sig, 3'b000};
        if (exp_diff >= AW) begin
            a_small_al = '0;
            a_small_al[0] = |small_ext;                 // everything -> sticky
        end else begin
            sticky      = |(small_ext & ((AW'(1) << exp_diff) - 1'b1));
            a_small_al  = small_ext >> exp_diff;
            a_small_al[0] = a_small_al[0] | sticky;
        end
    end

    // effective operation on the significands: 0 = add, 1 = subtract
    logic eff_op;
    assign eff_op = big_sign ^ small_sign;

    // ---- stage-1 registers --------------------------------------------------
    logic                s1_v;
    logic [AW-1:0]       s1_big, s1_small;
    logic                s1_eop, s1_rsign;
    logic [EW-1:0]       s1_exp;
    logic [W-1:0]        s1_spec;
    logic                s1_spec_v;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s1_v <= 1'b0;
        end else begin
            s1_v      <= in_valid;
            s1_big    <= a_big_al;
            s1_small  <= a_small_al;
            s1_eop    <= eff_op;
            s1_rsign  <= big_sign;
            s1_exp    <= {{(EW-EXP_W){1'b0}}, big_exp};
            s1_spec   <= s1_special;
            s1_spec_v <= s1_is_special;
        end
    end

    // =========================================================================
    // Stage 2 : add / subtract the aligned significands, then normalize
    // =========================================================================
    logic [AW:0]   sum_ext;       // one extra bit for add carry-out
    logic [AW-1:0] mag;           // magnitude after carry fix-up
    logic [EW-1:0] exp2;
    logic          zero2;

    always_comb begin
        logic [AW-1:0] shifted;
        int            lz, sh;
        exp2  = s1_exp;
        zero2 = 1'b0;

        if (s1_eop == 1'b0) begin
            // ---- like signs : add ----
            sum_ext = {1'b0, s1_big} + {1'b0, s1_small};
            if (sum_ext[AW]) begin
                // carry-out : shift right 1, preserve sticky, bump exponent
                mag  = sum_ext[AW:1];
                mag[0] = mag[0] | sum_ext[0];
                exp2 = s1_exp + 1'b1;
            end else begin
                mag = sum_ext[AW-1:0];
            end
        end else begin
            // ---- unlike signs : subtract (big >= small, so non-negative) ----
            sum_ext = {1'b0, s1_big} - {1'b0, s1_small};
            mag     = sum_ext[AW-1:0];
            if (mag == '0) begin
                zero2 = 1'b1;                       // exact cancellation
            end else begin
                // left-normalize, but never push the exponent below 1
                lz = clz(mag);
                sh = (lz <= (exp2 - 1)) ? lz : (exp2 - 1);
                mag  = mag << sh;
                exp2 = exp2 - sh;
            end
        end
    end

    // ---- stage-2 registers --------------------------------------------------
    logic          s2_v;
    logic [AW-1:0] s2_mag;
    logic [EW-1:0] s2_exp;
    logic          s2_rsign, s2_eop, s2_zero;
    logic [W-1:0]  s2_spec;
    logic          s2_spec_v;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s2_v <= 1'b0;
        end else begin
            s2_v      <= s1_v;
            s2_mag    <= mag;
            s2_exp    <= exp2;
            s2_rsign  <= s1_rsign;
            s2_eop    <= s1_eop;
            s2_zero   <= zero2;
            s2_spec   <= s1_spec;
            s2_spec_v <= s1_spec_v;
        end
    end

    // =========================================================================
    // Stage 3 : round-to-nearest-even, handle over/underflow, repack
    // =========================================================================
    logic [W-1:0] arith_res;
    always_comb begin
        logic [SIG:0]  mant;       // one extra bit for rounding carry
        logic          g, r, st, round_up;
        logic [EW-1:0] e;
        logic          zsign;

        e    = s2_exp;
        mant = {1'b0, s2_mag[AW-1 -: SIG]};   // top SIG bits (hidden + fraction)
        g    = s2_mag[2];
        r    = s2_mag[1];
        st   = s2_mag[0];

        // round to nearest, ties to even
        round_up = g & (r | st | mant[0]);
        mant     = mant + round_up;

        // rounding may carry the significand from 1.111.. to 10.000..
        if (mant[SIG]) begin
            mant = mant >> 1;                 // renormalize
            e    = e + 1'b1;
        end

        if (s2_zero) begin
            // exact cancellation : +0 (RNE) ; -0 only for (-0)+(-0)
            zsign     = (s2_eop == 1'b0) ? s2_rsign : 1'b0;
            arith_res = {zsign, {EXP_W{1'b0}}, {MAN_W{1'b0}}};
        end else if ($signed(e) >= EXPMAX) begin
            arith_res = {s2_rsign, {EXP_W{1'b1}}, {MAN_W{1'b0}}};   // overflow -> Inf
        end else if (mant[SIG-1]) begin
            // normalized normal result (this also covers subnormal->normal
            // promotion by rounding, where e == 1 and the hidden bit is now set)
            arith_res = {s2_rsign, e[EXP_W-1:0], mant[MAN_W-1:0]};
        end else begin
            // subnormal (or zero) : stored exponent 0, hidden bit clear
            arith_res = {s2_rsign, {EXP_W{1'b0}}, mant[MAN_W-1:0]};
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
        end else begin
            out_valid <= s2_v;
            result    <= s2_spec_v ? s2_spec : arith_res;
        end
    end

endmodule

`default_nettype wire
