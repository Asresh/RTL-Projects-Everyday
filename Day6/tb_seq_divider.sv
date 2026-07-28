// -----------------------------------------------------------------------------
// Day 6 : tb_seq_divider  --  self-checking testbench for seq_divider
// -----------------------------------------------------------------------------
// Strategy
//   The golden model is the language's own integer `/` and `%` operators, which
//   are completely independent of the DUT's shift-subtract datapath.  For every
//   (dividend, divisor) pair the testbench precomputes the expected quotient and
//   remainder and, after the DUT's `done` strobe, checks:
//
//       quotient   == dividend / divisor
//       remainder  == dividend % divisor
//       div_by_zero == (divisor == 0)
//
//   For the divide-by-zero case the golden model uses the documented policy
//   (quotient = all-ones, remainder = dividend).  A continuous monitor verifies
//   that `done` is a single-cycle strobe and that `busy` brackets the run.
//
//   Directed corners cover divide-by-1, divide-by-self, zero dividend, maximum
//   operands and divide-by-zero; then 320 randomized pairs are run.  The first
//   division (200 / 7) is the window rendered to the waveform PNG.  The
//   testbench dumps seq_divider.vcd and prints "RESULT: *** PASS ***" iff every
//   check passed.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps

module tb_seq_divider;

    // ------------------------------------------------------------- parameters
    localparam int  WIDTH = 8;
    localparam time CLK_PERIOD = 10ns;
    localparam int  TIMEOUT_CYCLES = 200000;

    // --------------------------------------------------------------- DUT I/O
    logic              clk;
    logic              rst_n;
    logic              start;
    logic [WIDTH-1:0]  dividend;
    logic [WIDTH-1:0]  divisor;
    logic [WIDTH-1:0]  quotient;
    logic [WIDTH-1:0]  remainder;
    logic              busy;
    logic              done;
    logic              div_by_zero;

    // ----------------------------------------------------------- scoreboard
    integer checks;
    integer errors;

    // ------------------------------------------------------------------- DUT
    seq_divider #(.WIDTH(WIDTH)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .dividend    (dividend),
        .divisor     (divisor),
        .quotient    (quotient),
        .remainder   (remainder),
        .busy        (busy),
        .done        (done),
        .div_by_zero (div_by_zero)
    );

    // ------------------------------------------------------------ clock/reset
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Continuous protocol monitor: 'done' must be a single-cycle strobe
    // =========================================================================
    logic done_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_d <= 1'b0;
        else begin
            done_d <= done;
            if (done && done_d)
                report_err("'done' asserted for more than one cycle");
            if (done && busy)
                report_err("'busy' still high when 'done' strobed");
        end
    end

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic report_err(input string msg);
        begin
            errors = errors + 1;
            $display("  [%0t] ERROR: %s", $time, msg);
        end
    endtask

    // Drive one division and score it against the golden model.
    task automatic do_div(input [WIDTH-1:0] a, input [WIDTH-1:0] b);
        logic [WIDTH-1:0] q_exp, r_exp;
        begin
            // ---- golden model (independent of the DUT) ---------------------
            if (b == '0) begin
                q_exp = {WIDTH{1'b1}};   // policy: x/0 -> all ones
                r_exp = a;               // ...     remainder = x
            end else begin
                q_exp = a / b;
                r_exp = a % b;
            end

            // ---- drive the transfer ----------------------------------------
            wait (!busy);
            @(negedge clk);
            dividend = a;
            divisor  = b;
            start    = 1'b1;
            @(negedge clk);
            start    = 1'b0;

            // ---- wait for completion ---------------------------------------
            @(posedge done);
            @(negedge clk);      // let the registered outputs settle

            // ---- score -----------------------------------------------------
            checks = checks + 1;
            if (quotient !== q_exp)
                report_err($sformatf(
                    "%0d / %0d : quotient=%0d exp=%0d", a, b, quotient, q_exp));

            checks = checks + 1;
            if (remainder !== r_exp)
                report_err($sformatf(
                    "%0d %% %0d : remainder=%0d exp=%0d", a, b, remainder, r_exp));

            checks = checks + 1;
            if (div_by_zero !== (b == '0))
                report_err($sformatf(
                    "%0d / %0d : div_by_zero=%0b exp=%0b",
                    a, b, div_by_zero, (b == '0)));
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer i;
    logic [WIDTH-1:0] ra, rb;
    localparam logic [WIDTH-1:0] MAXV = {WIDTH{1'b1}};

    initial begin
        $dumpfile("seq_divider.vcd");
        $dumpvars(0, tb_seq_divider);

        // init
        checks   = 0;
        errors   = 0;
        rst_n    = 1'b0;
        start    = 1'b0;
        dividend = '0;
        divisor  = '0;

        // reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("Day6 seq_divider : self-checking testbench");
        $display("-------------------------------------------------------------");

        // ---- reset-state checks --------------------------------------------
        checks = checks + 1;
        if (busy !== 1'b0) report_err("busy not low after reset");
        checks = checks + 1;
        if (done !== 1'b0) report_err("done high after reset");

        // ---- 1) the division rendered to PNG: 200 / 7 = 28 r 4 -------------
        do_div(8'd200, 8'd7);

        // ---- 2) directed corner cases --------------------------------------
        // divide by 1
        do_div(8'd0,   8'd1);
        do_div(8'd1,   8'd1);
        do_div(8'd200, 8'd1);
        do_div(MAXV,   8'd1);
        // divide by self
        do_div(8'd1,   8'd1);
        do_div(8'd7,   8'd7);
        do_div(8'd200, 8'd200);
        do_div(MAXV,   MAXV);
        // zero dividend
        do_div(8'd0,   8'd3);
        do_div(8'd0,   MAXV);
        // maximum operands
        do_div(MAXV,   8'd2);
        do_div(MAXV,   MAXV - 1);
        do_div(MAXV,   8'd16);
        do_div(8'd128, 8'd3);
        // exact multiples / remainders
        do_div(8'd100, 8'd10);
        do_div(8'd99,  8'd10);
        do_div(8'd15,  8'd4);
        // divide-by-zero policy
        do_div(8'd0,   8'd0);
        do_div(8'd1,   8'd0);
        do_div(8'd200, 8'd0);
        do_div(MAXV,   8'd0);

        // ---- 3) randomized pairs -------------------------------------------
        for (i = 0; i < 320; i = i + 1) begin
            ra = $random;
            rb = $random;
            do_div(ra, rb);
        end

        // ------------------------------------------------------------- report
        $display("-------------------------------------------------------------");
        $display("Checks performed : %0d", checks);
        $display("Errors           : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

    // ------------------------------------------------------------- timeout
    initial begin
        repeat (TIMEOUT_CYCLES) @(posedge clk);
        $display("  [%0t] ERROR: global timeout -- DUT never finished", $time);
        $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule

`default_nettype wire
