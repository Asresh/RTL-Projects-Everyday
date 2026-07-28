// -----------------------------------------------------------------------------
// Day 7 : tb_axi4lite_regs  --  self-checking testbench for axi4lite_regs
// -----------------------------------------------------------------------------
// Strategy
//   A small task-based AXI4-Lite *master* BFM drives all five channels with
//   correct VALID/READY handshakes (axi_write / axi_read).  A golden reference
//   model -- a plain SystemVerilog array with the same reset values and the same
//   RW / RO / W1C / unmapped semantics -- is updated in lock-step with every
//   accepted write, and every read/response is scoreboarded against it:
//
//       read data      == golden model value for that address (RO/const/0)
//       write response  == OKAY for mapped, SLVERR for unmapped
//       read  response  == OKAY for mapped, SLVERR for unmapped
//
//   Directed tests cover write-then-read, strobe-masked partial writes, the
//   read-only register (writes ignored, reads return the constant), the
//   write-1-to-clear register, unmapped-address errors and a zero-strobe write;
//   then 240 randomized read/write transactions (with a mix of mapped and
//   unmapped addresses and random strobes) are run.  If the slave ever violated
//   a handshake the BFM would stall and the global timeout would fire.
//
//   The first two transactions (write REG1 = 0x12345678, then read it back) are
//   the window rendered to the waveform PNG.  The testbench dumps
//   axi4lite_regs.vcd and prints "RESULT: *** PASS ***" iff every check passed.
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns / 1ps

module tb_axi4lite_regs;

    // ------------------------------------------------------------- parameters
    localparam int  ADDR_WIDTH = 8;
    localparam int  DATA_WIDTH = 32;
    localparam int  NUM_REGS   = 8;
    localparam int  NBYTES     = DATA_WIDTH/8;
    localparam int  REG_SEL_W  = $clog2(NUM_REGS);

    localparam int  RO_IDX  = 3;
    localparam int  W1C_IDX = 5;
    localparam logic [DATA_WIDTH-1:0] RO_CONST  = 32'hDEAD_BEEF;
    localparam logic [DATA_WIDTH-1:0] W1C_RESET = 32'hA5A5_A5A5;

    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    localparam time CLK_PERIOD = 10ns;
    localparam int  TIMEOUT_CYCLES = 200000;

    // --------------------------------------------------------------- DUT I/O
    logic                    clk;
    logic                    rst_n;
    logic [ADDR_WIDTH-1:0]   awaddr;
    logic                    awvalid;
    wire                     awready;
    logic [DATA_WIDTH-1:0]   wdata;
    logic [NBYTES-1:0]       wstrb;
    logic                    wvalid;
    wire                     wready;
    wire  [1:0]              bresp;
    wire                     bvalid;
    logic                    bready;
    logic [ADDR_WIDTH-1:0]   araddr;
    logic                    arvalid;
    wire                     arready;
    wire  [DATA_WIDTH-1:0]   rdata;
    wire  [1:0]              rresp;
    wire                     rvalid;
    logic                    rready;

    // ----------------------------------------------------------- scoreboard
    integer checks;
    integer errors;

    // ------------------------------------------------- golden register model
    logic [DATA_WIDTH-1:0] model [0:NUM_REGS-1];

    // ------------------------------------------------------------------- DUT
    axi4lite_regs #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .NUM_REGS   (NUM_REGS)
    ) dut (
        .clk (clk), .rst_n (rst_n),
        .awaddr (awaddr), .awvalid (awvalid), .awready (awready),
        .wdata (wdata), .wstrb (wstrb), .wvalid (wvalid), .wready (wready),
        .bresp (bresp), .bvalid (bvalid), .bready (bready),
        .araddr (araddr), .arvalid (arvalid), .arready (arready),
        .rdata (rdata), .rresp (rresp), .rvalid (rvalid), .rready (rready)
    );

    // ------------------------------------------------------------ clock/reset
    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // =========================================================================
    // Helpers
    // =========================================================================
    task automatic report_err(input string msg);
        begin
            errors = errors + 1;
            $display("  [%0t] ERROR: %s", $time, msg);
        end
    endtask

    // ---- AXI4-Lite master BFM: WRITE (AW + W -> B) --------------------------
    task automatic axi_write(input  [ADDR_WIDTH-1:0] addr,
                             input  [DATA_WIDTH-1:0]  data,
                             input  [NBYTES-1:0]      strb,
                             output [1:0]             resp);
        reg aw_ok, w_ok;
        begin
            aw_ok = 1'b0; w_ok = 1'b0;
            @(negedge clk);
            awaddr = addr; awvalid = 1'b1;
            wdata  = data; wstrb   = strb; wvalid = 1'b1;
            bready = 1'b1;
            // wait for both the AW and W handshakes
            do begin
                @(posedge clk);
                if (awvalid && awready) aw_ok = 1'b1;
                if (wvalid  && wready ) w_ok  = 1'b1;
            end while (!(aw_ok && w_ok));
            @(negedge clk);
            awvalid = 1'b0; wvalid = 1'b0;
            // wait for the B response
            do @(posedge clk); while (!(bvalid && bready));
            resp = bresp;
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    // ---- AXI4-Lite master BFM: READ (AR -> R) -------------------------------
    task automatic axi_read(input  [ADDR_WIDTH-1:0] addr,
                            output [DATA_WIDTH-1:0]  data,
                            output [1:0]             resp);
        begin
            @(negedge clk);
            araddr = addr; arvalid = 1'b1;
            rready = 1'b1;
            do @(posedge clk); while (!(arvalid && arready));   // AR handshake
            @(negedge clk);
            arvalid = 1'b0;
            do @(posedge clk); while (!(rvalid && rready));     // R handshake
            data = rdata; resp = rresp;
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    // ---- scored write: drive + update golden model + check response ---------
    task automatic do_write(input [ADDR_WIDTH-1:0] addr,
                            input [DATA_WIDTH-1:0]  data,
                            input [NBYTES-1:0]      strb);
        logic [1:0]           resp, exp_resp;
        logic                 mapped;
        logic [REG_SEL_W-1:0] idx;
        integer               b;
        begin
            axi_write(addr, data, strb, resp);

            mapped = (addr < (NUM_REGS << 2));
            idx    = addr[2 +: REG_SEL_W];
            if (!mapped) begin
                exp_resp = RESP_SLVERR;                 // unmapped: model unchanged
            end else begin
                exp_resp = RESP_OKAY;
                if (idx == RO_IDX) begin
                    /* read-only: model unchanged */
                end else if (idx == W1C_IDX) begin
                    for (b = 0; b < NBYTES; b = b + 1)
                        if (strb[b])
                            model[W1C_IDX][8*b +: 8] =
                                model[W1C_IDX][8*b +: 8] & ~data[8*b +: 8];
                end else begin
                    for (b = 0; b < NBYTES; b = b + 1)
                        if (strb[b])
                            model[idx][8*b +: 8] = data[8*b +: 8];
                end
            end

            checks = checks + 1;
            if (resp !== exp_resp)
                report_err($sformatf(
                    "WRITE addr=0x%02x data=0x%08x strb=%b : bresp=%02b exp=%02b",
                    addr, data, strb, resp, exp_resp));
        end
    endtask

    // ---- scored read: drive + check data & response vs golden model ---------
    task automatic do_read(input [ADDR_WIDTH-1:0] addr);
        logic [DATA_WIDTH-1:0] data, exp_data;
        logic [1:0]            resp, exp_resp;
        logic                  mapped;
        logic [REG_SEL_W-1:0]  idx;
        begin
            axi_read(addr, data, resp);

            mapped = (addr < (NUM_REGS << 2));
            idx    = addr[2 +: REG_SEL_W];
            if (!mapped) begin
                exp_data = '0;         exp_resp = RESP_SLVERR;
            end else if (idx == RO_IDX) begin
                exp_data = RO_CONST;   exp_resp = RESP_OKAY;
            end else begin
                exp_data = model[idx]; exp_resp = RESP_OKAY;
            end

            checks = checks + 1;
            if (data !== exp_data)
                report_err($sformatf(
                    "READ addr=0x%02x : rdata=0x%08x exp=0x%08x", addr, data, exp_data));
            checks = checks + 1;
            if (resp !== exp_resp)
                report_err($sformatf(
                    "READ addr=0x%02x : rresp=%02b exp=%02b", addr, resp, exp_resp));
        end
    endtask

    // =========================================================================
    // Stimulus
    // =========================================================================
    integer t, i;
    logic [ADDR_WIDTH-1:0] raddr;
    logic [DATA_WIDTH-1:0] rdata_rand;
    logic [NBYTES-1:0]     rstrb;

    initial begin
        $dumpfile("axi4lite_regs.vcd");
        $dumpvars(0, tb_axi4lite_regs);

        // init
        checks  = 0; errors = 0;
        rst_n   = 1'b0;
        awaddr  = '0; awvalid = 1'b0;
        wdata   = '0; wstrb = '0; wvalid = 1'b0;
        bready  = 1'b0;
        araddr  = '0; arvalid = 1'b0;
        rready  = 1'b0;
        for (i = 0; i < NUM_REGS; i = i + 1)
            model[i] = (i == W1C_IDX) ? W1C_RESET : '0;

        // reset
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        $display("Day7 axi4lite_regs : self-checking testbench");
        $display("-------------------------------------------------------------");

        // ---- reset-state checks --------------------------------------------
        checks = checks + 1;
        if (bvalid !== 1'b0) report_err("bvalid high after reset");
        checks = checks + 1;
        if (rvalid !== 1'b0) report_err("rvalid high after reset");
        checks = checks + 1;
        if (awready !== 1'b1) report_err("awready low after reset");
        checks = checks + 1;
        if (arready !== 1'b1) report_err("arready low after reset");

        // ---- 1) write-then-read REG1 (this is the rendered window) ---------
        do_write(8'h04, 32'h1234_5678, 4'b1111);
        do_read (8'h04);

        // ---- 2) write & read back every RW register ------------------------
        do_write(8'h00, 32'h0000_0001, 4'b1111); do_read(8'h00);
        do_write(8'h08, 32'hCAFE_F00D, 4'b1111); do_read(8'h08);
        do_write(8'h10, 32'h0BAD_C0DE, 4'b1111); do_read(8'h10);
        do_write(8'h18, 32'h1357_9BDF, 4'b1111); do_read(8'h18);
        do_write(8'h1C, 32'hFFFF_FFFF, 4'b1111); do_read(8'h1C);

        // ---- 3) strobe-masked partial writes -------------------------------
        do_write(8'h00, 32'h0000_0000, 4'b1111); do_read(8'h00);   // clear
        do_write(8'h00, 32'hAABBCCDD, 4'b0101); do_read(8'h00);     // bytes 0,2 only
        do_write(8'h00, 32'h11223344, 4'b1010); do_read(8'h00);     // bytes 1,3 only
        do_write(8'h08, 32'hDEAD_BEEF, 4'b0000); do_read(8'h08);    // zero strobe: no change

        // ---- 4) read-only register (REG3 @ 0x0C) ---------------------------
        do_read (8'h0C);                                            // -> 0xDEADBEEF
        do_write(8'h0C, 32'h1234_5678, 4'b1111);                    // ignored, OKAY
        do_read (8'h0C);                                            // still 0xDEADBEEF

        // ---- 5) write-1-to-clear register (REG5 @ 0x14) --------------------
        do_read (8'h14);                                            // -> 0xA5A5A5A5
        do_write(8'h14, 32'h0000_00FF, 4'b1111); do_read(8'h14);    // clear low byte
        do_write(8'h14, 32'h05050000, 4'b1111); do_read(8'h14);     // clear some bits
        do_write(8'h14, 32'hFFFF_FFFF, 4'b0010); do_read(8'h14);    // clear byte1 only

        // ---- 6) unmapped-address errors ------------------------------------
        do_read (8'h20);                                            // SLVERR, data 0
        do_write(8'h20, 32'hDEAD_DEAD, 4'b1111);                    // SLVERR
        do_read (8'h3C);
        do_write(8'h80, 32'h0000_0001, 4'b1111);

        // ---- 7) randomized read/write burst --------------------------------
        for (t = 0; t < 240; t = t + 1) begin
            raddr      = (($random & (2*NUM_REGS-1)) << 2);   // word 0..15 (half unmapped)
            rdata_rand = $random;
            rstrb      = $random;
            if ($random & 1)
                do_read(raddr);
            else
                do_write(raddr, rdata_rand, rstrb);
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
        $display("  [%0t] ERROR: global timeout -- a handshake stalled", $time);
        $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule

`default_nettype wire
