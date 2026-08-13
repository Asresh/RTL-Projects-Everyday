// ============================================================================
//  tb_i2c_master.sv
//  Self-checking testbench for the Day 8 I2C master.
//
//  A behavioral, open-drain I2C *slave* model sits on a pulled-up two-wire bus
//  (tri1 scl/sda).  It detects START/STOP, ACKs a matching 7-bit address,
//  captures written bytes, and returns programmed bytes on reads.  The
//  testbench is the golden reference: for every write it checks the slave
//  actually captured the expected byte; for every read it checks the master
//  returned the byte the slave sent; it also checks ACK-error reporting on an
//  unaddressed transfer.  Directed + randomized stimulus, a global timeout,
//  and a VCD dump are all included.
//
//  Author: Asresh Kuricheti
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_i2c_master;

    // ---- parameters (small divider keeps the sim fast) ---------------------
    localparam int CLK_FREQ_HZ = 2_000_000;
    localparam int SCL_FREQ_HZ =   100_000;   // -> QUARTER = 5 clocks
    localparam [6:0] SLAVE_ADDR = 7'h2A;

    // ---- clock / reset -----------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;            // 100 MHz sim clock

    // ---- DUT command interface ---------------------------------------------
    logic       start, rw;
    logic [6:0] addr;
    logic [7:0] wr_data;
    logic [7:0] rd_data;
    logic       busy, done, ack_error;

    // ---- open-drain bus ----------------------------------------------------
    tri1  scl;      // pulled-up clock line
    tri1  sda;      // pulled-up data line
    logic scl_oe, sda_oe;
    assign scl = scl_oe ? 1'b0 : 1'bz;   // master: pull low or release
    assign sda = sda_oe ? 1'b0 : 1'bz;

    // ---- DUT ---------------------------------------------------------------
    i2c_master #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .SCL_FREQ_HZ(SCL_FREQ_HZ)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .rw        (rw),
        .addr      (addr),
        .wr_data   (wr_data),
        .rd_data   (rd_data),
        .busy      (busy),
        .done      (done),
        .ack_error (ack_error),
        .scl_i     (scl),
        .scl_oe    (scl_oe),
        .sda_i     (sda),
        .sda_oe    (sda_oe)
    );

    // ---- slave model -------------------------------------------------------
    logic [7:0] slave_read_byte;   // byte the slave returns on a read
    logic [7:0] slave_last_wr;     // last byte the slave captured on a write
    logic       slave_wr_valid;

    i2c_slave_model #(.SADDR(SLAVE_ADDR)) slave (
        .scl          (scl),
        .sda          (sda),
        .read_byte    (slave_read_byte),
        .last_wr_data (slave_last_wr),
        .wr_valid     (slave_wr_valid)
    );

    // ---- scoreboard --------------------------------------------------------
    int errors = 0;
    int checks = 0;

    task automatic expect_eq(input logic [7:0] got, input logic [7:0] exp,
                             input string tag);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  [FAIL] %-22s got=0x%02h exp=0x%02h @%0t",
                     tag, got, exp, $time);
        end else begin
            $display("  [ok]   %-22s = 0x%02h", tag, got);
        end
    endtask

    task automatic expect_bit(input logic got, input logic exp, input string tag);
        checks++;
        if (got !== exp) begin
            errors++;
            $display("  [FAIL] %-22s got=%b exp=%b @%0t", tag, got, exp, $time);
        end else begin
            $display("  [ok]   %-22s = %b", tag, got);
        end
    endtask

    // Issue one transaction and wait for completion.
    task automatic do_txn(input logic r, input logic [6:0] a,
                          input logic [7:0] d);
        @(posedge clk);
        rw      <= r;
        addr    <= a;
        wr_data <= d;
        start   <= 1'b1;
        @(posedge clk);
        start   <= 1'b0;
        // wait for the done pulse
        wait (done == 1'b1);
        @(posedge clk);
    endtask

    // ------------------------------------------------------------------------
    //  Stimulus
    // ------------------------------------------------------------------------
    initial begin
        $dumpfile("i2c_master.vcd");
        $dumpvars(0, tb_i2c_master);

        start = 0; rw = 0; addr = 0; wr_data = 0; slave_read_byte = 8'h00;
        rst_n = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        $display("========================================================");
        $display(" I2C master self-checking test (slave addr = 0x%02h)", SLAVE_ADDR);
        $display("========================================================");

        // ---- directed WRITE ------------------------------------------------
        $display("\n-- directed write 0xA5 --");
        do_txn(1'b0, SLAVE_ADDR, 8'hA5);
        expect_bit(ack_error, 1'b0, "write ack_error");
        expect_eq (slave_last_wr, 8'hA5, "slave captured write");

        // ---- directed READ -------------------------------------------------
        $display("\n-- directed read 0x3C --");
        slave_read_byte = 8'h3C;
        do_txn(1'b1, SLAVE_ADDR, 8'h00);
        expect_bit(ack_error, 1'b0, "read ack_error");
        expect_eq (rd_data, 8'h3C, "master read data");

        // ---- ACK-error (unaddressed slave) ---------------------------------
        $display("\n-- write to wrong address (expect NACK) --");
        do_txn(1'b0, 7'h55, 8'hFF);   // != SLAVE_ADDR
        expect_bit(ack_error, 1'b1, "unaddressed ack_error");

        // ---- randomized write/read mix -------------------------------------
        $display("\n-- randomized write+read pairs --");
        for (int i = 0; i < 8; i++) begin
            logic [7:0] wd, rd;
            wd = $urandom_range(0, 255);
            rd = $urandom_range(0, 255);

            do_txn(1'b0, SLAVE_ADDR, wd);           // write
            expect_bit(ack_error, 1'b0, $sformatf("rand[%0d] wr ack", i));
            expect_eq (slave_last_wr, wd, $sformatf("rand[%0d] wr byte", i));

            slave_read_byte = rd;
            do_txn(1'b1, SLAVE_ADDR, 8'h00);        // read
            expect_bit(ack_error, 1'b0, $sformatf("rand[%0d] rd ack", i));
            expect_eq (rd_data, rd, $sformatf("rand[%0d] rd byte", i));
        end

        // ---- report --------------------------------------------------------
        $display("\n========================================================");
        $display(" checks run : %0d", checks);
        $display(" errors     : %0d", errors);
        if (errors == 0)
            $display(" RESULT: *** PASS ***");
        else
            $display(" RESULT: *** FAIL ***");
        $display("========================================================");
        $finish;
    end

    // ---- global timeout ----------------------------------------------------
    initial begin
        #2_000_000;   // 2 ms of sim time
        $display(" RESULT: *** FAIL *** (timeout)");
        $fatal(1, "timeout");
    end

endmodule


// ============================================================================
//  Behavioral open-drain I2C slave model (verification only, not synthesizable)
// ============================================================================
module i2c_slave_model #(
    parameter [6:0] SADDR = 7'h2A
) (
    input  wire        scl,
    inout  wire        sda,
    input  wire [7:0]  read_byte,
    output logic [7:0] last_wr_data,
    output logic       wr_valid
);
    logic drive_low;
    assign sda = drive_low ? 1'b0 : 1'bz;

    // sample one bit on the rising SCL edge
    task automatic sample_bit(output logic b);
        @(posedge scl);
        b = (sda === 1'b0) ? 1'b0 : 1'b1;
    endtask

    initial begin
        logic [7:0] a;      // address byte
        logic [7:0] d;      // data byte
        logic       b;      // scratch bit
        int         i;

        drive_low    = 1'b0;
        last_wr_data = 8'h00;
        wr_valid     = 1'b0;

        forever begin
            // ---- wait for START: SDA falls while SCL is high ---------------
            @(negedge sda);
            if (scl !== 1'b1) continue;

            // ---- receive 8-bit address (MSB first) -------------------------
            a = 8'h00;
            for (i = 0; i < 8; i++) begin
                sample_bit(b);
                a = {a[6:0], b};
            end

            // ---- ACK phase (drive during 9th high if the address matches) --
            @(negedge scl);
            drive_low = (a[7:1] == SADDR);
            @(posedge scl);                    // master samples ACK here
            if (a[7:1] != SADDR) begin
                @(negedge scl);
                drive_low = 1'b0;
                continue;                      // not addressed to us
            end

            if (a[0] == 1'b0) begin
                // ---- master WRITE: release, receive data, then ACK ---------
                @(negedge scl);
                drive_low = 1'b0;
                d = 8'h00;
                for (i = 0; i < 8; i++) begin
                    sample_bit(b);
                    d = {d[6:0], b};
                end
                @(negedge scl);
                drive_low = 1'b1;              // ACK the data byte
                @(posedge scl);
                @(negedge scl);
                drive_low    = 1'b0;
                last_wr_data = d;
                wr_valid     = 1'b1;
            end else begin
                // ---- master READ: drive read_byte MSB first ----------------
                for (i = 7; i >= 0; i--) begin
                    @(negedge scl);
                    drive_low = (read_byte[i] == 1'b0);
                    @(posedge scl);           // master samples this bit
                end
                @(negedge scl);
                drive_low = 1'b0;             // release for the master NACK
                @(posedge scl);
            end
        end
    end

endmodule

`default_nettype wire
