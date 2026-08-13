//==============================================================================
// Testbench  : tb_sync_fifo
// Description : Self-checking testbench for sync_fifo.
//               A SystemVerilog queue serves as the golden reference model.
//               The registered (1-cycle) read latency is mirrored by a small
//               expected-data pipeline, and every read is scoreboarded.
// Author      : Asresh Kuricheti
//==============================================================================
`timescale 1ns/1ps

module tb_sync_fifo;

    localparam int DATA_WIDTH = 8;
    localparam int DEPTH      = 16;

    // DUT interface
    logic                    clk, rst_n;
    logic                    wr_en, rd_en;
    logic [DATA_WIDTH-1:0]   din, dout;
    logic                    full, empty;
    logic [$clog2(DEPTH):0]  count;

    // Reference model + scoreboard state
    logic [DATA_WIDTH-1:0]   ref_q [$];
    logic [DATA_WIDTH-1:0]   exp_data;
    logic                    exp_valid;
    int                      errors  = 0;
    int                      checks  = 0;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    sync_fifo #(.DATA_WIDTH(DATA_WIDTH), .DEPTH(DEPTH)) dut (
        .clk (clk), .rst_n (rst_n),
        .wr_en(wr_en), .rd_en(rd_en),
        .din (din),  .dout (dout),
        .full(full), .empty(empty), .count(count)
    );

    //--------------------------------------------------------------------------
    // Clock: 100 MHz
    //--------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // Golden reference model (single block => no queue race).
    // Pop mirrors the DUT's 1-cycle registered read.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exp_valid <= 1'b0;
            ref_q.delete();
        end else begin
            // read side (registered)
            if (rd_en && !empty) begin
                exp_data  <= ref_q.pop_front();
                exp_valid <= 1'b1;
            end else begin
                exp_valid <= 1'b0;
            end
            // write side
            if (wr_en && !full)
                ref_q.push_back(din);
        end
    end

    //--------------------------------------------------------------------------
    // Scoreboard: compare on the cycle the registered read data is valid.
    //--------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst_n && exp_valid) begin
            checks++;
            if (dout !== exp_data) begin
                errors++;
                $error("[%0t] MISMATCH: dout=0x%02h expected=0x%02h", $time, dout, exp_data);
            end
        end
    end

    // Depth check: reference length must always track the DUT count.
    always_ff @(posedge clk) begin
        if (rst_n && (ref_q.size() != count))
            $error("[%0t] COUNT MISMATCH: dut count=%0d ref size=%0d", $time, count, ref_q.size());
    end

    //--------------------------------------------------------------------------
    // Stimulus tasks
    //--------------------------------------------------------------------------
    task automatic do_reset();
        wr_en = 0; rd_en = 0; din = '0; rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    task automatic push(input logic [DATA_WIDTH-1:0] data);
        @(negedge clk); wr_en = 1; rd_en = 0; din = data;
        @(negedge clk); wr_en = 0;
    endtask

    task automatic pop();
        @(negedge clk); rd_en = 1; wr_en = 0;
        @(negedge clk); rd_en = 0;
    endtask

    //--------------------------------------------------------------------------
    // Test sequence
    //--------------------------------------------------------------------------
    initial begin
        $display("==== sync_fifo test start ====");
        do_reset();

        if (!empty) $error("FIFO should be empty after reset");

        // 1) Fill the FIFO completely and confirm 'full'.
        for (int i = 0; i < DEPTH; i++)
            push(8'(i * 3 + 1));
        if (!full) $error("FIFO should be full after %0d writes", DEPTH);

        // 2) A write while full must be ignored (no overflow).
        push(8'hFF);

        // 3) Drain the FIFO completely and confirm 'empty'.
        for (int i = 0; i < DEPTH; i++)
            pop();
        repeat (2) @(posedge clk);
        if (!empty) $error("FIFO should be empty after draining");

        // 4) Simultaneous read + write while half full.
        for (int i = 0; i < DEPTH/2; i++) push(8'(i + 100));
        for (int i = 0; i < 8; i++) begin
            @(negedge clk); wr_en = 1; rd_en = 1; din = 8'(i + 200);
        end
        @(negedge clk); wr_en = 0; rd_en = 0;

        // 5) Randomized traffic.
        for (int i = 0; i < 200; i++) begin
            @(negedge clk);
            wr_en = $urandom_range(0, 1);
            rd_en = $urandom_range(0, 1);
            din   = 8'($urandom);
        end
        @(negedge clk); wr_en = 0; rd_en = 0;

        // Drain whatever remains.
        while (!empty) pop();
        repeat (4) @(posedge clk);

        //----------------------------------------------------------------------
        $display("==== sync_fifo test done ====");
        $display("Checks performed : %0d", checks);
        $display("Errors           : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $finish;
    end

    // Safety timeout
    initial begin
        #100000;
        $error("TIMEOUT: test did not finish");
        $finish;
    end

    // Waveform dump (optional)
    initial begin
        $dumpfile("sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);
    end

endmodule
