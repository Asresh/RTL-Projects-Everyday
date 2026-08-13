// =============================================================================
// Day 12 : booth_multiplier
// -----------------------------------------------------------------------------
// A fully-pipelined, parameterizable RADIX-4 (modified) BOOTH MULTIPLIER with a
// carry-save (Wallace-style) reduction tree.
//
// A straight WIDTH x WIDTH multiply builds WIDTH partial products and adds them
// all.  Radix-4 Booth recoding scans the multiplier two bits at a time (with a
// 1-bit overlap), collapsing every pair of bits into a single signed digit
//
//        d_i  in  {-2, -1, 0, +1, +2}
//
// so the number of partial products is HALVED to ~WIDTH/2.  Each partial product
// is then just 0, +/-M or +/-2M (a shift + optional two's-complement negate of the
// multiplicand M) placed at weight 2^(2i).
//
// The partial products are summed with a tree of 3:2 carry-save adders
// (a Wallace/Dadda-style reduction) that squashes N addends down to a redundant
// {sum, carry} pair in O(log N) full-adder delays with NO carry propagation, and
// a single carry-propagate adder (CPA) at the very end resolves the final result.
// This is the classic high-speed multiplier microarchitecture.
//
// Pipeline (throughput = 1 multiply / clock, fixed latency = 4):
//
//   stage 0 : register the operands                         (a_r, b_r)
//   stage 1 : Booth-recode b_r + generate the partial       (pp_r[])
//             products from a_r  (combinational)
//   stage 2 : carry-save reduction tree  -> {sum, carry}     (sum_r, carry_r)
//   stage 3 : final carry-propagate add  -> product          (out_data)
//
// A valid bit is shifted alongside the data so out_valid marks the multiply that
// produced it.  Supports SIGNED (two's-complement) or unsigned operands.
//
// The whole network (# partial products, tree shape) is derived from WIDTH at
// elaboration by constant functions -- no hand-wired tables.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module booth_multiplier #(
    parameter int WIDTH  = 16,     // operand width in bits, MUST be >= 2
    parameter bit SIGNED = 1'b1    // 1 = two's-complement operands, 0 = unsigned
) (
    input  wire                    clk,
    input  wire                    rst_n,     // active-low async reset

    input  wire                    in_valid,  // a/b carry a fresh operand pair
    input  wire  [WIDTH-1:0]       a,         // multiplicand
    input  wire  [WIDTH-1:0]       b,         // multiplier

    output wire                    out_valid, // product is valid this cycle
    output wire  [2*WIDTH-1:0]     product    // a * b  (full double-width result)
);

    // -------------------------------------------------------------------------
    // Elaboration-time geometry.
    //   MW  : internal signed operand width, rounded UP to an even number so the
    //         Booth grouping tiles perfectly (unsigned operands are widened by an
    //         extra zero MSB so their top bit is a magnitude bit, not a sign).
    //   G   : number of radix-4 partial products  = MW/2
    //   PW  : internal (redundant) product width   = 2*MW
    //   OW  : external product width               = 2*WIDTH
    // -------------------------------------------------------------------------
    localparam int MW0 = SIGNED ? WIDTH : (WIDTH + 1);
    localparam int MW  = (MW0 % 2 == 0) ? MW0 : (MW0 + 1);
    localparam int G   = MW / 2;
    localparam int PW  = 2 * MW;
    localparam int OW  = 2 * WIDTH;

    // synthesis-time sanity check
    initial begin
        if (WIDTH < 2)
            $error("booth_multiplier: WIDTH (%0d) must be >= 2", WIDTH);
    end

    // =========================================================================
    // Stage 0 : operand registers
    // =========================================================================
    logic [WIDTH-1:0] a_r, b_r;
    logic             v0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_r <= '0;  b_r <= '0;  v0 <= 1'b0;
        end else begin
            a_r <= a;   b_r <= b;   v0 <= in_valid;
        end
    end

    // -------------------------------------------------------------------------
    // Sign/zero-extend the operands to MW bits, then the multiplicand to the full
    // PW-bit product width.  Everything after this is exact modulo-2^PW arithmetic
    // and, because the true product fits in OW <= PW bits, the low OW bits are the
    // exact answer for both signed and unsigned operands.
    // -------------------------------------------------------------------------
    wire signed [MW-1:0] a_ext = SIGNED ? $signed(a_r) : $signed({1'b0, a_r});
    wire signed [MW-1:0] b_ext = SIGNED ? $signed(b_r) : $signed({1'b0, b_r});

    wire [PW-1:0] M    = a_ext;      // multiplicand, sign-extended to PW bits
    wire [PW-1:0] M2   = M << 1;     // 2 * multiplicand

    // -------------------------------------------------------------------------
    // Stage 1 (combinational) : radix-4 Booth partial-product generation.
    //   Group i inspects the overlapping triple {b[2i+1], b[2i], b[2i-1]}
    //   (b[-1] := 0) and emits one signed digit in {-2,-1,0,+1,+2}:
    //       two = |d| == 2      one = |d| == 1      neg = d < 0
    //   The partial product is 0 / +/-M / +/-2M, negated via unary minus (two's
    //   complement), then shifted left by 2i to its column weight.
    // -------------------------------------------------------------------------
    wire [PW-1:0] pp_w [0:G-1];

    genvar gi;
    generate
        for (gi = 0; gi < G; gi = gi + 1) begin : g_pp
            localparam int LO  = 2 * gi;
            localparam int LOM = (gi == 0) ? 0 : (LO - 1);  // avoid b[-1] select

            wire s2  = b_ext[LO + 1];
            wire s1  = b_ext[LO];
            wire s0  = (gi == 0) ? 1'b0 : b_ext[LOM];

            wire two = ( s2 & ~s1 & ~s0) | (~s2 &  s1 &  s0);  // 100 or 011
            wire one = s1 ^ s0;                                 // 001/010/101/110
            wire neg = s2;                                      // d < 0

            wire [PW-1:0] mag = two ? M2 : (one ? M : {PW{1'b0}});
            wire [PW-1:0] ppv = neg ? (-mag) : mag;             // two's-comp negate

            assign pp_w[gi] = ppv << (2 * gi);
        end
    endgenerate

    // flatten to a packed bus so it can travel through the pipeline / a function
    wire [G*PW-1:0] pp_flat;
    generate
        for (gi = 0; gi < G; gi = gi + 1) begin : g_flat
            assign pp_flat[gi*PW +: PW] = pp_w[gi];
        end
    endgenerate

    logic [G*PW-1:0] pp_r;
    logic            v1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pp_r <= '0;  v1 <= 1'b0;
        end else begin
            pp_r <= pp_flat;  v1 <= v0;
        end
    end

    // =========================================================================
    // Stage 2 (combinational) : Wallace-style 3:2 carry-save reduction.
    //   Repeatedly compress triples of addends into a {sum, carry} pair until
    //   only two vectors remain.  A 3:2 compressor is a column of full adders:
    //       sum   = a ^ b ^ c
    //       carry = ((a&b) | (a&c) | (b&c)) << 1   (carry has weight 2)
    //   The reduction schedule depends only on the elaboration constant G, so a
    //   synthesizer unrolls it into a fixed adder tree.
    // =========================================================================
    typedef struct packed {
        logic [PW-1:0] carry;
        logic [PW-1:0] sum;
    } cs_t;

    localparam int GA = (G < 2) ? 2 : G;   // >=2 entries so lvl[1] always exists

    function automatic cs_t csa_reduce(input logic [G*PW-1:0] flat);
        logic [PW-1:0] lvl [0:GA-1];
        logic [PW-1:0] nxt [0:GA-1];
        logic [PW-1:0] x, y, z;
        int cnt, w, i, t;
        cs_t r;
        // load the partial products
        for (i = 0; i < G; i = i + 1) lvl[i] = flat[i*PW +: PW];
        cnt = G;
        // reduce until two redundant vectors remain
        while (cnt > 2) begin
            w = 0;
            i = 0;
            while (i + 3 <= cnt) begin
                x = lvl[i]; y = lvl[i+1]; z = lvl[i+2];
                nxt[w]   = x ^ y ^ z;                          w = w + 1;
                nxt[w]   = ((x & y) | (x & z) | (y & z)) << 1; w = w + 1;
                i = i + 3;
            end
            while (i < cnt) begin nxt[w] = lvl[i]; w = w + 1; i = i + 1; end
            for (t = 0; t < w; t = t + 1) lvl[t] = nxt[t];
            cnt = w;
        end
        r.sum   = lvl[0];
        r.carry = (cnt == 2) ? lvl[1] : '0;
        return r;
    endfunction

    wire cs_t cs_comb = csa_reduce(pp_r);

    logic [PW-1:0] sum_r, carry_r;
    logic          v2;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r <= '0;  carry_r <= '0;  v2 <= 1'b0;
        end else begin
            sum_r <= cs_comb.sum;  carry_r <= cs_comb.carry;  v2 <= v1;
        end
    end

    // =========================================================================
    // Stage 3 : final carry-propagate add of the redundant {sum, carry} pair.
    // =========================================================================
    wire [PW-1:0] full = sum_r + carry_r;

    logic [OW-1:0] prod_r;
    logic          v3;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prod_r <= '0;  v3 <= 1'b0;
        end else begin
            prod_r <= full[OW-1:0];  v3 <= v2;
        end
    end

    assign product   = prod_r;
    assign out_valid = v3;

endmodule

`default_nettype wire
