// ============================================================================
// Day 32 : Self-checking testbench for rs_encoder
// ----------------------------------------------------------------------------
// Independent golden model.  Nothing here reuses the DUT's LFSR structure:
//
//   1. SCHOOLBOOK REMAINDER  -- the parity is recomputed by textbook GF(2^M)
//      polynomial long division of  m(x)*x^(2T)  by an independently generated
//      g(x).  The DUT computes the same remainder with an LFSR; if the two
//      disagree, one is wrong.
//
//   2. SYSTEMATIC PROPERTY   -- the first K emitted symbols must equal the
//      message, symbol for symbol, with cw_is_parity == 0.
//
//   3. SYNDROME-ZERO PROPERTY (the real teeth) -- the defining algebraic fact
//      of a Reed-Solomon codeword: c(alpha^(FCR+s)) == 0 for every one of the
//      2T parity roots.  Evaluated by Horner's method, sharing no code path with
//      either the DUT or the schoolbook divider.
//
//   4. ERROR-INJECTION SANITY -- flipping any codeword symbol must make at least
//      one syndrome non-zero, proving the syndrome check is not vacuous.
//
// Directed corners (all-zero / all-ones / unit / ramp / known message) plus a
// randomized soak, every block checked on all properties, a cycle timeout
// watchdog, and a VCD dump for the waveform.  Prints RESULT: *** PASS ***.
//
// (Icarus note: subroutine ports may not carry unpacked arrays, so message /
//  parity / codeword vectors live at module scope and the tasks read them.)
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_rs_encoder;

    // ---- DUT configuration (shortened RS(16,8) over GF(256), corrects T=4) ---
    localparam int unsigned M    = 8;
    localparam int unsigned T    = 4;
    localparam int unsigned K    = 8;
    localparam int unsigned PRIM = 'h11D;
    localparam int unsigned FCR  = 0;
    localparam int unsigned ALG  = 2;

    localparam int unsigned P = 2*T;        // parity symbols
    localparam int unsigned N = K + P;      // codeword length

    // ---- clock / reset ------------------------------------------------------
    reg clk = 1'b0;
    always #5 clk = ~clk;                    // 100 MHz

    reg               rst;
    reg               start_i;
    reg               msg_valid_i;
    reg  [M-1:0]      msg_data_i;

    wire              msg_ready_o;
    wire              cw_valid_o;
    wire [M-1:0]      cw_data_o;
    wire              cw_is_parity_o;
    wire              cw_last_o;
    wire [P*M-1:0]    par_flat_o;
    wire              par_valid_o;
    wire              busy_o;
    wire              done_o;

    rs_encoder #(
        .M(M), .T(T), .K(K), .PRIM(PRIM), .FCR(FCR), .ALG(ALG)
    ) dut (
        .clk(clk), .rst(rst),
        .start_i(start_i), .msg_valid_i(msg_valid_i), .msg_data_i(msg_data_i),
        .msg_ready_o(msg_ready_o),
        .cw_valid_o(cw_valid_o), .cw_data_o(cw_data_o),
        .cw_is_parity_o(cw_is_parity_o), .cw_last_o(cw_last_o),
        .par_flat_o(par_flat_o), .par_valid_o(par_valid_o),
        .busy_o(busy_o), .done_o(done_o)
    );

    // ---- module-level working vectors (shared with tasks) -------------------
    reg [M-1:0] msg     [0:K-1];    // current message block
    reg [M-1:0] par_exp [0:P-1];    // golden parity
    reg [M-1:0] gc      [0:P];      // generator coeffs, gc[t] = coeff of x^t
    reg [M-1:0] cw_mem  [0:N-1];    // collected codeword symbols
    reg         cw_ispar[0:N-1];    // per-symbol parity flag
    reg [M-1:0] cw_work [0:N-1];    // scratch codeword for syndrome eval
    integer     cw_n;

    // ---- bookkeeping --------------------------------------------------------
    integer checks = 0;
    integer errors = 0;

    task automatic expect_eq(input [63:0] got, input [63:0] exp, input [255:0] what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s]: got 0x%0h  exp 0x%0h  (t=%0t)",
                         what, got, exp, $time);
            end
        end
    endtask

    task automatic expect_true(input cond, input [255:0] what);
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("  ASSERT-FAIL [%0s] (t=%0t)", what, $time);
            end
        end
    endtask

    // ========================================================================
    // Independent GF(2^M) golden arithmetic + generator polynomial
    // ========================================================================
    function automatic [M-1:0] g_mul(input [M-1:0] a, input [M-1:0] b);
        integer i; reg [M-1:0] p, aa;
        begin
            p = '0; aa = a;
            for (i = 0; i < M; i = i + 1) begin
                if (b[i]) p = p ^ aa;
                if (aa[M-1]) aa = (aa << 1) ^ PRIM[M-1:0];
                else         aa = (aa << 1);
            end
            g_mul = p;
        end
    endfunction

    function automatic [M-1:0] g_pow(input [M-1:0] base, input integer e);
        integer i; reg [M-1:0] r;
        begin
            r = {{(M-1){1'b0}}, 1'b1};
            for (i = 0; i < e; i = i + 1) r = g_mul(r, base);
            g_pow = r;
        end
    endfunction

    // generator coefficients gc[t] = coeff of x^t ; gc[P] == 1
    task automatic build_generator;
        integer i, j; reg [M-1:0] root;
        begin
            for (i = 0; i <= P; i = i + 1) gc[i] = '0;
            gc[0] = {{(M-1){1'b0}}, 1'b1};
            for (i = 0; i < P; i = i + 1) begin
                root = g_pow(ALG[M-1:0], FCR + i);
                for (j = i + 1; j > 0; j = j - 1)
                    gc[j] = gc[j-1] ^ g_mul(gc[j], root);
                gc[0] = g_mul(gc[0], root);
            end
        end
    endtask

    // schoolbook parity of module-level msg[] -> module-level par_exp[]
    // (rem = (m(x)*x^P) mod g(x); parity high-degree first)
    task automatic golden_parity;
        integer i, k; reg [M-1:0] coef;
        begin
            for (i = 0; i < K; i = i + 1) cw_work[i] = msg[i];
            for (i = K; i < N; i = i + 1) cw_work[i] = '0;
            for (i = 0; i < K; i = i + 1) begin
                coef = cw_work[i];
                if (coef != 0)
                    for (k = 0; k <= P; k = k + 1)
                        cw_work[i+k] = cw_work[i+k] ^ g_mul(coef, gc[P-k]);
            end
            for (i = 0; i < P; i = i + 1) par_exp[i] = cw_work[K+i];
        end
    endtask

    // syndrome s = c(alpha^(FCR+s)) over module-level cw_work[] via Horner
    function automatic [M-1:0] syndrome_work(input integer s);
        integer i; reg [M-1:0] r, root;
        begin
            root = g_pow(ALG[M-1:0], FCR + s);
            r = '0;
            for (i = 0; i < N; i = i + 1) r = g_mul(r, root) ^ cw_work[i];
            syndrome_work = r;
        end
    endfunction

    // ========================================================================
    // Drive one block (from module-level msg[]) and run all checks
    // ----------------------------------------------------------------------
    // Collection is done inline (not in a parallel always) and every DUT signal
    // is sampled at #1 past the rising edge, after the registered outputs have
    // settled -- so there is no cross-process race on cw_n at block boundaries.
    // ========================================================================
    task automatic encode_and_check(input [255:0] tag);
        integer i, s, guard;
        reg     any_nonzero;
        begin
            // pulse start: two settled clocks take S_IDLE -> S_MSG
            @(posedge clk); #1;
            start_i = 1'b1; msg_valid_i = 1'b0;
            @(posedge clk); #1;
            start_i = 1'b0;

            // drive K message symbols and collect the full N-symbol codeword;
            // the registered stream lags acceptance by one clock, so we simply
            // keep sampling until N beats have arrived.
            cw_n  = 0;
            i     = 0;
            guard = 0;
            while (cw_n < N && guard < 4*N + 16) begin
                if (i < K) begin
                    msg_valid_i = 1'b1;
                    msg_data_i  = msg[i];
                end else begin
                    msg_valid_i = 1'b0;
                end
                @(posedge clk); #1;
                if (i < K) i = i + 1;
                if (cw_valid_o) begin
                    cw_mem[cw_n]   = cw_data_o;
                    cw_ispar[cw_n] = cw_is_parity_o;
                    cw_n           = cw_n + 1;
                end
                guard = guard + 1;
            end
            msg_valid_i = 1'b0;

            // ---- (1) collected exactly N symbols --------------------------
            expect_eq(cw_n, N, {tag, ":count"});

            // ---- (2) systematic passthrough of the message ----------------
            for (i = 0; i < K; i = i + 1) begin
                expect_eq(cw_mem[i], msg[i], {tag, ":sysdata"});
                expect_true(cw_ispar[i] === 1'b0, {tag, ":sysflag"});
            end

            // ---- (3) parity == schoolbook remainder -----------------------
            golden_parity();
            for (i = 0; i < P; i = i + 1) begin
                expect_eq(cw_mem[K+i], par_exp[i],           {tag, ":paritydata"});
                expect_true(cw_ispar[K+i] === 1'b1,          {tag, ":parityflag"});
                // parallel par_flat_o carries the same block (low index = x^0)
                expect_eq(par_flat_o[(P-1-i)*M +: M], par_exp[i], {tag, ":parflat"});
            end

            // ---- (4) the whole codeword is a valid RS codeword ------------
            for (i = 0; i < N; i = i + 1) cw_work[i] = cw_mem[i];
            for (s = 0; s < P; s = s + 1)
                expect_eq(syndrome_work(s), {M{1'b0}}, {tag, ":syndrome"});

            // ---- (5) error-injection sanity: a flip breaks a syndrome -----
            cw_work[N/2] = cw_work[N/2] ^ 8'hA5;     // corrupt one symbol
            any_nonzero = 1'b0;
            for (s = 0; s < P; s = s + 1)
                if (syndrome_work(s) != 0) any_nonzero = 1'b1;
            expect_true(any_nonzero, {tag, ":errdetect"});
        end
    endtask

    // ========================================================================
    // Stimulus
    // ========================================================================
    integer r, c;

    // watchdog
    initial begin
        #200000;
        $display("RESULT: *** TIMEOUT *** watchdog fired");
        $finish;
    end

    initial begin
        $dumpfile("rs_encoder.vcd");
        $dumpvars(0, tb_rs_encoder);

        build_generator();
        rst         = 1'b1;
        start_i     = 1'b0;
        msg_valid_i = 1'b0;
        msg_data_i  = '0;
        cw_n        = 0;
        repeat (4) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);

        $display("Day 32 RS encoder: RS(%0d,%0d) over GF(2^%0d), corrects T=%0d symbols",
                 N, K, M, T);

        // ---- Directed corner cases -------------------------------------
        // D1: all-zero message -> parity must also be all zero
        for (c = 0; c < K; c = c + 1) msg[c] = 8'h00;
        encode_and_check("all-zero");
        for (c = 0; c < P; c = c + 1)
            expect_eq(cw_mem[K+c], 8'h00, "all-zero:parity0");

        // D2: all-ones message
        for (c = 0; c < K; c = c + 1) msg[c] = 8'hFF;
        encode_and_check("all-ones");

        // D3: single non-zero symbol at the head
        for (c = 0; c < K; c = c + 1) msg[c] = 8'h00;
        msg[0] = 8'h01;
        encode_and_check("unit-head");

        // D4: single non-zero symbol at the tail
        for (c = 0; c < K; c = c + 1) msg[c] = 8'h00;
        msg[K-1] = 8'h80;
        encode_and_check("unit-tail");

        // D5: walking pattern / ramp
        for (c = 0; c < K; c = c + 1) msg[c] = c[7:0] + 8'h10;
        encode_and_check("ramp");

        // D6: a fixed, human-checkable message
        msg[0]=8'h48; msg[1]=8'h45; msg[2]=8'h4C; msg[3]=8'h4C;
        msg[4]=8'h4F; msg[5]=8'h21; msg[6]=8'hDE; msg[7]=8'hAD;
        encode_and_check("known-msg");
        $display("known-msg parity =");
        for (c = 0; c < P; c = c + 1)
            $display("    parity[%0d] = 0x%0h", c, cw_mem[K+c]);

        // ---- Randomized soak -------------------------------------------
        for (r = 0; r < 400; r = r + 1) begin
            for (c = 0; c < K; c = c + 1) msg[c] = $random;
            encode_and_check("rand");
        end

        // ---- verdict ----------------------------------------------------
        $display("--------------------------------------------------------");
        $display("Total checks : %0d", checks);
        $display("Total errors : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

endmodule

`default_nettype wire
