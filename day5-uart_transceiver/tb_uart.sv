// -----------------------------------------------------------------------------
// Day 5 : tb_uart  --  self-checking testbench for the configurable UART
// -----------------------------------------------------------------------------
// Strategy
//   The DUT's own transmit line is wired straight back to its own receive line
//   (`tx_serial -> rx_serial`), so every byte is really shifted out one bit at a
//   time and re-assembled by the receiver over the actual serial wire.  Because
//   a UART just moves a byte verbatim, the golden model is trivial and fully
//   independent of the DUT internals:
//
//       byte received by RX  ==  byte handed to TX
//
//   The suite sends the directed patterns 0x00, 0xFF, 0xA5, 0x01, 0x80, 0x55,
//   0x7E, 0xC3 at several baud dividers, then 210 randomized bytes across a set
//   of dividers.  For every byte it checks: (1) the received byte equals the
//   sent byte, (2) no framing error (stop bit was high), and (3) `tx_busy`
//   asserted for the frame.  Continuous monitors verify that `rx_valid` and
//   `tx_done` are single-cycle strobes.
//
//   The testbench dumps uart.vcd and prints "RESULT: *** PASS ***" iff every
//   check passed.  The very first byte (0xA5 at clks_per_bit=16) is the window
//   rendered to the waveform PNG.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps

module tb_uart;

    // ------------------------------------------------------------- parameters
    localparam int  DATA_BITS = 8;
    localparam int  DIV_WIDTH = 16;
    localparam time CLK_PERIOD = 10ns;
    localparam int  TIMEOUT_CYCLES = 2_000_000;

    // --------------------------------------------------------------- DUT I/O
    logic                  clk;
    logic                  rst_n;
    logic [DIV_WIDTH-1:0]  clks_per_bit;
    logic                  tx_start;
    logic [DATA_BITS-1:0]  tx_data;
    wire                   serial_line;   // TX out looped back to RX in
    wire                   tx_busy;
    wire                   tx_done;
    wire  [DATA_BITS-1:0]  rx_data;
    wire                   rx_valid;
    wire                   rx_frame_err;

    // ----------------------------------------------------------- scoreboard
    integer checks;
    integer errors;

    // ------------------------------------------------------------------- DUT
    uart #(
        .DATA_BITS (DATA_BITS),
        .DIV_WIDTH (DIV_WIDTH)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .clks_per_bit (clks_per_bit),
        .tx_start     (tx_start),
        .tx_data      (tx_data),
        .tx_serial    (serial_line),   // loopback: drive the wire
        .tx_busy      (tx_busy),
        .tx_done      (tx_done),
        .rx_serial    (serial_line),   // loopback: sample the same wire
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_err (rx_frame_err)
    );

    // ------------------------------------------------------------ clock/reset
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Continuous protocol monitors (single-cycle strobe checks)
    // =========================================================================
    logic rx_valid_d, tx_done_d;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_valid_d <= 1'b0;
            tx_done_d  <= 1'b0;
        end else begin
            rx_valid_d <= rx_valid;
            tx_done_d  <= tx_done;
            if (rx_valid && rx_valid_d)
                report_err("rx_valid asserted for more than one cycle");
            if (tx_done && tx_done_d)
                report_err("tx_done asserted for more than one cycle");
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

    // Transmit one byte and score the loopback reception.
    task automatic send_byte(input [DATA_BITS-1:0] data);
        begin
            // wait for the transmitter to be free
            wait (!tx_busy);
            @(negedge clk);
            tx_data  = data;
            tx_start = 1'b1;
            @(negedge clk);
            tx_start = 1'b0;

            // the transmitter must now be busy
            checks = checks + 1;
            if (!tx_busy)
                report_err($sformatf(
                    "tx_busy did not assert after start (data=0x%02x, cpb=%0d)",
                    data, clks_per_bit));

            // wait until the receiver reports a byte
            @(posedge rx_valid);
            @(negedge clk);      // let rx_data / rx_frame_err settle

            // --- data integrity: RX byte == TX byte -------------------------
            checks = checks + 1;
            if (rx_data !== data)
                report_err($sformatf(
                    "loopback mismatch: sent 0x%02x, got 0x%02x (cpb=%0d)",
                    data, rx_data, clks_per_bit));

            // --- framing: stop bit was high ---------------------------------
            checks = checks + 1;
            if (rx_frame_err !== 1'b0)
                report_err($sformatf(
                    "framing error flagged on byte 0x%02x (cpb=%0d)",
                    data, clks_per_bit));
        end
    endtask

    // Send the full directed pattern set at a given baud divider.
    task automatic send_directed(input [DIV_WIDTH-1:0] cpb);
        begin
            clks_per_bit = cpb;
            send_byte(8'h00);
            send_byte(8'hFF);
            send_byte(8'hA5);
            send_byte(8'h01);
            send_byte(8'h80);
            send_byte(8'h55);
            send_byte(8'h7E);
            send_byte(8'hC3);
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer i;
    logic [DATA_BITS-1:0] rbyte;

    initial begin
        $dumpfile("uart.vcd");
        $dumpvars(0, tb_uart);

        // init
        checks       = 0;
        errors       = 0;
        rst_n        = 1'b0;
        clks_per_bit = 16'd16;
        tx_start     = 1'b0;
        tx_data      = '0;

        // reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("Day5 uart : self-checking testbench");
        $display("-------------------------------------------------------------");

        // ---- reset-state checks --------------------------------------------
        checks = checks + 1;
        if (serial_line !== 1'b1) report_err("tx line not idle-high after reset");
        checks = checks + 1;
        if (tx_busy !== 1'b0)     report_err("tx_busy not low after reset");
        checks = checks + 1;
        if (rx_valid !== 1'b0)    report_err("rx_valid high after reset");

        // ---- 1) the byte rendered to PNG: 0xA5 at clks_per_bit = 16 --------
        clks_per_bit = 16'd16;
        send_byte(8'hA5);

        // ---- 2) directed patterns across several baud dividers -------------
        send_directed(16'd16);
        send_directed(16'd8);
        send_directed(16'd12);
        send_directed(16'd10);

        // ---- 3) randomized bytes across several baud dividers --------------
        for (i = 0; i < 210; i = i + 1) begin
            case ($random & 32'h3)
                0: clks_per_bit = 16'd8;
                1: clks_per_bit = 16'd10;
                2: clks_per_bit = 16'd12;
                3: clks_per_bit = 16'd16;
            endcase
            rbyte = $random;
            send_byte(rbyte);
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
