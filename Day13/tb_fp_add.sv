// -----------------------------------------------------------------------------
// Day 13 : tb_fp_add
// Self-checking testbench for the pipelined IEEE-754 binary32 adder.
//
// Golden reference : the host FPU, reached through Icarus' $bitstoshortreal /
// $shortrealtobits system functions.  Because a double holds the exact sum of
// two singles, `a + b` computed in shortreal and rounded back to 32 bits is the
// correctly-rounded IEEE single result - a genuinely independent oracle (it
// shares no logic with the DUT).
//
//   * directed vectors  : hand-computed expected hex (independent of the FPU),
//                         covering 3.0, signed zero, a round-to-even tie,
//                         Inf +/- Inf, NaN propagation, overflow to Inf.
//   * randomized vectors : thousands of operand pairs biased toward the
//                         interesting exponent ranges (near-cancellation,
//                         subnormals, overflow) plus occasional Inf/NaN.
//
// A scoreboard FIFO absorbs the 3-cycle pipeline latency; NaN results compare
// NaN-equal (any NaN == any NaN), everything else compares bit-exact.
// Prints  RESULT: *** PASS ***  only if every check passed.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_fp_add;

    localparam int W = 32;

    // ---- DUT I/O ------------------------------------------------------------
    logic          clk = 1'b0, rst_n;
    logic          in_valid, sub;
    logic [W-1:0]  a, b;
    logic          out_valid;
    logic [W-1:0]  result;

    fp_add #(.EXP_W(8), .MAN_W(23)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .sub(sub), .a(a), .b(b),
        .out_valid(out_valid), .result(result)
    );

    always #5 clk = ~clk;                     // 100 MHz

    // ---- golden model : host FPU -------------------------------------------
    function logic [W-1:0] golden(input logic [W-1:0] x,
                                            input logic [W-1:0] y,
                                            input logic         s);
        shortreal fx, fy, fr;
        begin
            fx = $bitstoshortreal(x);
            fy = $bitstoshortreal(y);
            fr = s ? (fx - fy) : (fx + fy);
            golden = $shortrealtobits(fr);
        end
    endfunction

    function logic is_nan(input logic [W-1:0] v);
        is_nan = (v[30:23] == 8'hFF) && (v[22:0] != 0);
    endfunction

    // ---- scoreboard FIFO (holds expected value + originating stimulus) ------
    logic [W-1:0] exp_q[$];
    logic [W-1:0] ain_q[$], bin_q[$];
    logic         sub_q[$];

    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic drive(input logic [W-1:0] x, input logic [W-1:0] y, input logic s);
        begin
            @(posedge clk);
            in_valid <= 1'b1;
            a        <= x;
            b        <= y;
            sub      <= s;
            exp_q.push_back(golden(x, y, s));
            ain_q.push_back(x);
            bin_q.push_back(y);
            sub_q.push_back(s);
        end
    endtask

    task automatic idle(input int n);
        begin
            repeat (n) begin
                @(posedge clk);
                in_valid <= 1'b0;
            end
        end
    endtask

    // ---- checker : compares every valid output against the FIFO head --------
    logic [W-1:0] want, xin, yin;
    logic         sin, ok;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            want = exp_q.pop_front();
            xin  = ain_q.pop_front();
            yin  = bin_q.pop_front();
            sin  = sub_q.pop_front();
            checks++;
            // NaN == NaN (any payload); otherwise bit-exact (incl. sign of zero)
            ok = (is_nan(want) && is_nan(result)) || (want === result);
            if (!ok) begin
                errors++;
                if (errors <= 20)
                    $display("  MISMATCH  a=%h b=%h %s  got=%h  exp=%h  (a=%g b=%g)",
                             xin, yin, sin ? "-" : "+", result, want,
                             $bitstoshortreal(xin), $bitstoshortreal(yin));
            end
        end
    end

    // ---- directed vectors with INDEPENDENT hand-computed expected values ----
    // {a, b, sub, expected}
    task automatic directed_checks;
        begin
            // 1.0 + 2.0 = 3.0
            check_direct(32'h3F800000, 32'h40000000, 1'b0, 32'h40400000, "1+2=3");
            // 3.5 + 0.5 = 4.0
            check_direct(32'h40600000, 32'h3F000000, 1'b0, 32'h40800000, "3.5+0.5=4");
            // 1.0 - 1.0 = +0
            check_direct(32'h3F800000, 32'h3F800000, 1'b1, 32'h00000000, "1-1=+0");
            // (-0) + (-0) = -0
            check_direct(32'h80000000, 32'h80000000, 1'b0, 32'h80000000, "-0 + -0 = -0");
            // 2.0 - 3.0 = -1.0
            check_direct(32'h40000000, 32'h40400000, 1'b1, 32'hBF800000, "2-3=-1");
            // round-to-even tie : 1.0 + 2^-24 -> 1.0 (even)
            check_direct(32'h3F800000, 32'h33800000, 1'b0, 32'h3F800000, "1+2^-24 tie->1.0");
            // 1.0 + 3*2^-24 -> 1.0000002 (rounds up), 3*2^-24 = 0x34400000
            check_direct(32'h3F800000, 32'h34400000, 1'b0, 32'h3F800002, "1+3*2^-24 round up");
            // +Inf + 1.0 = +Inf
            check_direct(32'h7F800000, 32'h3F800000, 1'b0, 32'h7F800000, "Inf+1=Inf");
            // +Inf - +Inf = NaN
            check_direct(32'h7F800000, 32'h7F800000, 1'b1, 32'h7FC00000, "Inf-Inf=NaN");
            // overflow : max_normal + max_normal = +Inf
            check_direct(32'h7F7FFFFF, 32'h7F7FFFFF, 1'b0, 32'h7F800000, "ovf->Inf");
            // subnormal + subnormal (no promotion) : 2^-149 + 2^-149 = 2^-148
            check_direct(32'h00000001, 32'h00000001, 1'b0, 32'h00000002, "denorm add");
            // largest subnormal + smallest subnormal -> smallest normal (promotion)
            check_direct(32'h007FFFFF, 32'h00000001, 1'b0, 32'h00800000, "denorm->normal");
        end
    endtask

    // enqueue a directed pair whose expected value is supplied explicitly
    task automatic check_direct(input logic [W-1:0] x, input logic [W-1:0] y,
                                input logic s, input logic [W-1:0] want,
                                input string name);
        begin
            @(posedge clk);
            in_valid <= 1'b1;
            a <= x; b <= y; sub <= s;
            exp_q.push_back(want);            // hand-computed, not from FPU
            ain_q.push_back(x);
            bin_q.push_back(y);
            sub_q.push_back(s);
            // sanity: the FPU must agree with our hand math (NaN-aware)
            if (!((is_nan(want) && is_nan(golden(x,y,s))) || (golden(x,y,s) === want)))
                $display("  NOTE directed '%s': FPU=%h hand=%h", name, golden(x,y,s), want);
        end
    endtask

    // ---- pseudo-random float generator biased to interesting ranges ---------
    logic [63:0] seed = 64'hDEAD_BEEF_1234_5678;
    function logic [31:0] rnd32;
        begin
            seed  = seed * 64'd6364136223846793005 + 64'd1442695040888963407;
            rnd32 = seed[47:16];
        end
    endfunction

    function logic [31:0] rand_float(input int mode);
        logic [31:0] r1, r2;
        logic        s;
        logic [7:0]  e;
        logic [22:0] m;
        begin
            r1 = rnd32();
            r2 = rnd32();
            s  = r1[0];
            m  = r2[22:0];
            case (mode)
                0: e = 8'(126 + (r1 % 5));      // exps 126..130 : heavy cancellation
                1: e = 8'(100 + (r1 % 60));     // wide normal range
                2: e = 8'((r1 % 3));            // 0..2 : subnormals & tiny
                3: e = 8'(250 + (r1 % 6));      // near overflow (250..255)
                default: e = r1[30:23];         // fully random (incl Inf/NaN)
            endcase
            rand_float = {s, e, m};
        end
    endfunction

    // ---- timeout watchdog ---------------------------------------------------
    initial begin
        repeat (200000) @(posedge clk);
        $display("RESULT: *** TIMEOUT ***");
        $fatal(1, "timeout");
    end

    // ---- VCD dump -----------------------------------------------------------
    initial begin
        $dumpfile("fp_add.vcd");
        $dumpvars(0, tb_fp_add);
    end

    // ---- main stimulus ------------------------------------------------------
    int i;
    logic [31:0] xa, xb, sb;
    initial begin
        in_valid = 1'b0; sub = 1'b0; a = '0; b = '0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // 1) directed corner cases
        directed_checks();

        // 2) randomized streams across the biased modes (back-to-back)
        for (i = 0; i < 4000; i++) begin
            sb = rnd32();
            xa = rand_float(i % 5);
            xb = rand_float((i/5) % 5);
            drive(xa, xb, sb[0]);
        end

        // 3) a burst with valid gaps to exercise in_valid gating
        for (i = 0; i < 200; i++) begin
            sb = rnd32();
            xa = rand_float(1);
            xb = rand_float(0);
            drive(xa, xb, sb[0]);
            if (i % 3 == 0) idle(1);
        end

        // drain the pipeline (extra edge so the final driven op isn't squashed)
        @(posedge clk);
        in_valid <= 1'b0;
        repeat (10) @(posedge clk);

        // ---- report ----
        if (exp_q.size() != 0)
            $display("  ERROR: %0d expected results never came out", exp_q.size());
        $display("checks = %0d   errors = %0d", checks, errors);
        if (errors == 0 && exp_q.size() == 0 && checks > 4000)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule

`default_nettype wire
