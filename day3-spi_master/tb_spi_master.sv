// -----------------------------------------------------------------------------
// Day 3 : tb_spi_master  --  self-checking testbench for spi_master
// -----------------------------------------------------------------------------
// Strategy
//   A behavioural SPI *slave* is wired back-to-back with the DUT (MOSI->slave,
//   slave->MISO), so every transfer is a real full-duplex exchange on the bus.
//   Because SPI just swaps words verbatim, the golden model is trivial and
//   completely independent of the DUT's internals:
//
//       expected value received by the master  ==  word the slave shifted out
//       expected value received by the slave   ==  word the master shifted out
//
//   Both expected values are known constants for every transfer, so the
//   scoreboard never derives anything from the DUT -- it compares DUT outputs
//   against pre-computed truth.  The suite sweeps all four SPI modes, corner-
//   case data patterns, several clock dividers, and a long randomized burst.
//   Protocol invariants (cs_n framing, single-cycle 'done', and exactly
//   2*DATA_WIDTH SCLK edges per word) are checked continuously.
//
//   The testbench dumps spi_master.vcd and prints "RESULT: *** PASS ***" iff
//   every check passed.
//
// Note: the behavioural slave samples SCLK synchronously in the system-clock
// domain, so it requires clk_div >= 1 (SCLK half-period >= 2 clocks).  All
// stimulus below honours that; the DUT itself has no such restriction.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps

module tb_spi_master;

    // ------------------------------------------------------------- parameters
    localparam int DATA_WIDTH = 8;
    localparam int DIV_WIDTH  = 16;
    localparam int EDGES      = 2 * DATA_WIDTH;

    localparam time CLK_PERIOD = 10ns;
    localparam int  TIMEOUT_CYCLES = 200000;

    // --------------------------------------------------------------- DUT I/O
    logic                    clk;
    logic                    rst_n;
    logic                    cpol;
    logic                    cpha;
    logic [DIV_WIDTH-1:0]    clk_div;
    logic                    start;
    logic [DATA_WIDTH-1:0]   tx_data;
    logic [DATA_WIDTH-1:0]   rx_data;
    logic                    busy;
    logic                    done;
    logic                    sclk;
    logic                    mosi;
    logic                    miso;
    logic                    cs_n;

    // ----------------------------------------------------------- scoreboard
    integer checks;
    integer errors;

    // ------------------------------------------------------------------- DUT
    spi_master #(
        .DATA_WIDTH (DATA_WIDTH),
        .DIV_WIDTH  (DIV_WIDTH)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpol    (cpol),
        .cpha    (cpha),
        .clk_div (clk_div),
        .start   (start),
        .tx_data (tx_data),
        .rx_data (rx_data),
        .busy    (busy),
        .done    (done),
        .sclk    (sclk),
        .mosi    (mosi),
        .miso    (miso),
        .cs_n    (cs_n)
    );

    // ------------------------------------------------------------ clock/reset
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Behavioural SPI slave model (independent of the DUT implementation)
    // =========================================================================
    logic [DATA_WIDTH-1:0]   slave_tx_data;   // word the slave will shift out
    logic [DATA_WIDTH-1:0]   slv_tx_shift;
    logic [DATA_WIDTH-1:0]   slv_rx_shift;    // word the slave captures from MOSI
    logic                    sclk_d;
    logic                    cs_d;
    integer                  sedge_cnt;

    // MISO is the top bit of the slave's transmit register.
    assign miso = slv_tx_shift[DATA_WIDTH-1];

    // A "leading" edge drives SCLK to its active level (~cpol); evaluated at the
    // instant an SCLK transition is detected below.
    wire slv_leading = (sclk == ~cpol);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            slv_tx_shift <= '0;
            slv_rx_shift <= '0;
            sclk_d       <= 1'b0;
            cs_d         <= 1'b1;
            sedge_cnt    <= 0;
        end else begin
            sclk_d <= sclk;
            cs_d   <= cs_n;

            if (cs_d && !cs_n) begin
                // Falling chip-select: load the outgoing word, arm the slave.
                slv_tx_shift <= slave_tx_data;
                slv_rx_shift <= '0;
                sedge_cnt    <= 0;
            end else if (!cs_n && (sclk != sclk_d)) begin
                // An SCLK edge occurred while selected.
                if (cpha == 1'b0) begin
                    // sample MOSI on leading, present next MISO bit on trailing
                    if (slv_leading)
                        slv_rx_shift <= {slv_rx_shift[DATA_WIDTH-2:0], mosi};
                    else
                        slv_tx_shift <= {slv_tx_shift[DATA_WIDTH-2:0], 1'b0};
                end else begin
                    // present next MISO bit on leading (after the first),
                    // sample MOSI on trailing
                    if (slv_leading) begin
                        if (sedge_cnt != 0)
                            slv_tx_shift <= {slv_tx_shift[DATA_WIDTH-2:0], 1'b0};
                    end else begin
                        slv_rx_shift <= {slv_rx_shift[DATA_WIDTH-2:0], mosi};
                    end
                end
                sedge_cnt <= sedge_cnt + 1;
            end
        end
    end

    // =========================================================================
    // Continuous protocol monitors
    // =========================================================================
    integer sclk_edges;   // SCLK edges counted during the current frame
    logic   done_seen;    // guards against a multi-cycle 'done'

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_edges <= 0;
        end else begin
            // Count SCLK edges only while a frame is active.
            if (cs_d && !cs_n)
                sclk_edges <= 0;                        // new frame
            else if (!cs_n && (sclk != sclk_d))
                sclk_edges <= sclk_edges + 1;

            // 'busy' must exactly bracket an asserted chip-select.
            if (busy && cs_n && !done)
                report_err("busy asserted with cs_n high");
            if (!busy && !cs_n)
                report_err("cs_n low while not busy");

            // 'done' must be a single-cycle strobe.
            if (done && done_seen)
                report_err("'done' asserted for more than one cycle");
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) done_seen <= 1'b0;
        else        done_seen <= done;
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

    // Drive one full-duplex transfer and score both directions.
    task automatic do_transfer(input logic              t_cpol,
                               input logic              t_cpha,
                               input [DIV_WIDTH-1:0]     t_div,
                               input [DATA_WIDTH-1:0]    m_tx,   // master -> slave
                               input [DATA_WIDTH-1:0]    s_tx);  // slave  -> master
        begin
            // Present configuration/data while idle.
            @(negedge clk);
            cpol          = t_cpol;
            cpha          = t_cpha;
            clk_div       = t_div;
            tx_data       = m_tx;
            slave_tx_data = s_tx;
            start         = 1'b1;
            @(negedge clk);
            start         = 1'b0;

            // Wait for completion (with a hard timeout backstop below).
            @(posedge done);
            @(posedge clk);      // let the last slave capture settle

            checks = checks + 1;

            // --- direction 1: master received exactly what the slave sent ---
            if (rx_data !== s_tx)
                report_err($sformatf(
                    "mode(cpol=%0b,cpha=%0b) div=%0d : master RX=0x%02x exp=0x%02x",
                    t_cpol, t_cpha, t_div, rx_data, s_tx));

            // --- direction 2: slave received exactly what the master sent ---
            if (slv_rx_shift !== m_tx)
                report_err($sformatf(
                    "mode(cpol=%0b,cpha=%0b) div=%0d : slave  RX=0x%02x exp=0x%02x",
                    t_cpol, t_cpha, t_div, slv_rx_shift, m_tx));

            // --- protocol: exactly 2*DATA_WIDTH SCLK edges per word ----------
            if (sclk_edges !== EDGES)
                report_err($sformatf(
                    "mode(cpol=%0b,cpha=%0b) div=%0d : saw %0d SCLK edges, exp %0d",
                    t_cpol, t_cpha, t_div, sclk_edges, EDGES));

            // A short idle gap between frames.
            repeat (3) @(negedge clk);
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer m, i;
    logic [1:0] mode;
    logic [DATA_WIDTH-1:0] rdata, rslv;
    logic [DIV_WIDTH-1:0]  rdiv;

    initial begin
        $dumpfile("spi_master.vcd");
        $dumpvars(0, tb_spi_master);

        // init
        checks   = 0;
        errors   = 0;
        rst_n    = 1'b0;
        cpol     = 1'b0;
        cpha     = 1'b0;
        clk_div  = 16'd1;
        start    = 1'b0;
        tx_data  = '0;
        slave_tx_data = '0;

        // reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("Day3 spi_master : self-checking testbench");
        $display("-------------------------------------------------------------");

        // ---- 1) clean mode-0 transfer (this is the window rendered to PNG) --
        do_transfer(1'b0, 1'b0, 16'd1, 8'hB5, 8'h93);

        // ---- 2) every SPI mode with a couple of patterns -------------------
        for (m = 0; m < 4; m = m + 1) begin
            mode = m[1:0];
            do_transfer(mode[1], mode[0], 16'd2, 8'hA5, 8'h3C);
            do_transfer(mode[1], mode[0], 16'd2, 8'hFF, 8'h00);
            do_transfer(mode[1], mode[0], 16'd2, 8'h00, 8'hFF);
            do_transfer(mode[1], mode[0], 16'd1, 8'h80, 8'h01);
            do_transfer(mode[1], mode[0], 16'd3, 8'h01, 8'h80);
        end

        // ---- 3) a few different clock dividers on mode 0 -------------------
        do_transfer(1'b0, 1'b0, 16'd1, 8'h5A, 8'hC3);
        do_transfer(1'b0, 1'b0, 16'd4, 8'h5A, 8'hC3);
        do_transfer(1'b0, 1'b0, 16'd7, 8'h5A, 8'hC3);

        // ---- 4) randomized burst across all modes/patterns/dividers --------
        for (i = 0; i < 300; i = i + 1) begin
            mode  = $random;
            rdata = $random;
            rslv  = $random;
            rdiv  = ($random & 32'h3) + 1;   // 1 .. 4  (slave model needs div >= 1)
            do_transfer(mode[1], mode[0], rdiv, rdata, rslv);
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
