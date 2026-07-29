// =============================================================================
// Day 12 : tb_booth_multiplier
// -----------------------------------------------------------------------------
// Self-checking testbench for the pipelined radix-4 Booth multiplier.
//
// Strategy
//   * The DUT is fully pipelined with a fixed latency, so every valid operand
//     pair yields exactly one valid product, in order.
//   * On each cycle we drive an operand pair (directed corner cases first, then
//     constrained-random) with a randomly gapped in_valid to exercise the valid
//     pipeline and back-to-back throughput.
//   * When in_valid is asserted we compute the GOLDEN product in software
//     (a plain SystemVerilog multiply of the same operands, honouring SIGNED)
//     and push it into a scoreboard queue.  This is an INDEPENDENT oracle: the
//     DUT builds the product from Booth digits + a carry-save tree, the golden
//     model just uses the language `*` operator.
//   * When out_valid is seen we pop the expected product and compare with `!==`
//     (so X/Z also fail).  A spurious output (empty queue) or a dropped output
//     (queue non-empty at the end) is an error.  A watchdog aborts a hung run.
//
// The DUT is instantiated SIGNED here; a second unsigned configuration is left
// as a one-line change.  The golden model tracks whatever SIGNED the DUT uses.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_booth_multiplier;

    // ---- DUT configuration --------------------------------------------------
    localparam int WIDTH  = 16;
    localparam bit SIGNED = 1'b1;
    localparam int OW     = 2 * WIDTH;

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;                    // 100 MHz

    // ---- DUT I/O ------------------------------------------------------------
    logic              in_valid;
    logic [WIDTH-1:0]  a, b;
    logic              out_valid;
    logic [OW-1:0]     product;

    booth_multiplier #(
        .WIDTH(WIDTH), .SIGNED(SIGNED)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .a         (a),
        .b         (b),
        .out_valid (out_valid),
        .product   (product)
    );

    // ---- scoreboard ---------------------------------------------------------
    logic [OW-1:0] exp_q [$];

    int sent    = 0;
    int checked = 0;
    int errors  = 0;

    // Reference (software) product of a pair, honouring the SIGNED knob.
    function automatic logic [OW-1:0] golden_mul(input logic [WIDTH-1:0] x,
                                                 input logic [WIDTH-1:0] y);
        logic signed [OW-1:0] sp;
        logic        [OW-1:0] up;
        if (SIGNED) begin
            sp = $signed(x) * $signed(y);
            return sp;
        end else begin
            up = x * y;
            return up;
        end
    endfunction

    // Drive one operand pair for exactly one cycle.  Inputs are launched on the
    // NEGEDGE via non-blocking assignment so they are rock-stable at the posedge
    // the DUT samples -- no clock-edge race, so the captured waveform is clean.
    task automatic drive(input logic [WIDTH-1:0] x,
                         input logic [WIDTH-1:0] y,
                         input bit vld);
        @(negedge clk);
        a        <= x;
        b        <= y;
        in_valid <= vld;
        if (vld) begin
            exp_q.push_back(golden_mul(x, y));
            sent++;
        end
    endtask

    // signed/unsigned pretty-print
    function automatic string vshow(input logic [OW-1:0] p);
        if (SIGNED) return $sformatf("%0d", $signed(p));
        else        return $sformatf("%0d", p);
    endfunction

    // ---- output checker: fires on every valid output ------------------------
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            logic [OW-1:0] exp;
            if (exp_q.size() == 0) begin
                errors++;
                $error("[%0t] out_valid with EMPTY scoreboard -> spurious output",
                       $time);
            end else begin
                exp = exp_q.pop_front();
                checked++;
                if (product !== exp) begin
                    errors++;
                    $error("[%0t] MISMATCH #%0d  got=%s  exp=%s (0x%0h vs 0x%0h)",
                           $time, checked, vshow(product), vshow(exp),
                           product, exp);
                end
            end
        end
    end

    // ---- stimulus -----------------------------------------------------------
    localparam logic [WIDTH-1:0] SMIN = {1'b1, {(WIDTH-1){1'b0}}};   // -2^(W-1)
    localparam logic [WIDTH-1:0] SMAX = {1'b0, {(WIDTH-1){1'b1}}};   //  2^(W-1)-1
    localparam logic [WIDTH-1:0] UMAX = {WIDTH{1'b1}};               //  2^W - 1

    logic [WIDTH-1:0] ra, rb;
    int coin;

    initial begin
        // ---- reset ----
        rst_n    = 1'b0;
        in_valid = 1'b0;
        a        = '0;
        b        = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- DIRECTED corner cases (streamed back-to-back) ----
        drive(16'd0,   16'd0,   1'b1);   // 0 * 0
        drive(16'd1,   16'd1,   1'b1);   // 1 * 1
        drive(16'd12345, 16'd7, 1'b1);   // small * small
        drive(SMAX,    SMAX,    1'b1);   // max * max
        drive(SMIN,    SMIN,    1'b1);   // min * min  (largest magnitude)
        drive(SMIN,    SMAX,    1'b1);   // min * max
        drive(UMAX,    UMAX,    1'b1);   // all-ones * all-ones (-1*-1 signed)
        drive(UMAX,    16'd1,   1'b1);   // -1 * 1  (signed)
        drive(SMIN,    16'd1,   1'b1);   // min * 1
        drive(16'hFFFE, 16'd3,  1'b1);   // -2 * 3  (signed)
        drive(SMAX,    UMAX,    1'b1);   // max * -1 (signed)

        // gap in the stream (in_valid low) -> exercises the valid pipeline
        drive('0, '0, 1'b0);
        drive('0, '0, 1'b0);

        // ---- RANDOMIZED stimulus with random valid gaps ----
        for (int t = 0; t < 500; t++) begin
            ra   = $urandom;
            rb   = $urandom;
            coin = $urandom_range(0, 3);        // ~75% duty -> some bubbles
            drive(ra, rb, (coin != 0));
        end

        // ---- drain the pipeline ----
        drive('0, '0, 1'b0);
        repeat (8) @(posedge clk);

        // ---- report ----
        $display("-----------------------------------------------------------");
        $display(" booth_multiplier  WIDTH=%0d SIGNED=%0d", WIDTH, SIGNED);
        $display(" products sent    = %0d", sent);
        $display(" products checked = %0d", checked);
        $display(" mismatches       = %0d", errors);
        if (exp_q.size() != 0) begin
            errors++;
            $display(" ERROR: %0d expected products never came out", exp_q.size());
        end
        if (errors == 0 && checked == sent && sent > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (errors=%0d)", errors);
        $display("-----------------------------------------------------------");
        $finish;
    end

    // ---- watchdog -----------------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL ***  (TIMEOUT)");
        $finish;
    end

    // ---- waveform dump ------------------------------------------------------
    initial begin
        $dumpfile("booth_multiplier.vcd");
        $dumpvars(0, tb_booth_multiplier);
    end

endmodule

`default_nettype wire
