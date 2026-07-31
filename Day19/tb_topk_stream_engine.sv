// ============================================================================
// tb_topk_stream_engine.sv
// ----------------------------------------------------------------------------
// Self-checking testbench for the streaming Top-K selection engine.
//
//   Independent golden model: a plainly-coded behavioral running Top-K kept in
//   a descending-sorted fixed array {gd, gt, gv}. Each accepted candidate is
//   inserted at the first slot whose stored key it is >= to (empty slots =
//   -inf), shifting the rest down and dropping any overflow -- the newer
//   element wins ties, matching the DUT's `>=` rule. This reference is written
//   in a scalar sequential style, structurally different from the DUT's
//   parallel one-shot compare/shift datapath, so it independently validates it.
//
//   After every cycle the DUT's sorted array (data, tag, valid, count, full)
//   is checked slot-by-slot against the golden state.
//
//   Coverage: reset, fill-below-K, exact-fill, overflow past K, ascending /
//   descending / duplicate / negative streams, mid-stream flush, and 4000
//   randomized candidates. Directed + randomized, global timeout, VCD dump.
// ============================================================================

`timescale 1ns/1ps

module tb_topk_stream_engine;

    localparam int K  = 6;
    localparam int DW = 12;
    localparam int TW = 8;
    localparam int CW = $clog2(K+1);

    localparam logic signed [DW-1:0] NEG_INF = {1'b1, {(DW-1){1'b0}}};

    logic                    clk, rst, flush;
    logic                    in_valid;
    logic signed [DW-1:0]    in_data;
    logic        [TW-1:0]    in_tag;

    logic [K-1:0]            valid_o;
    logic [K*DW-1:0]         data_o;
    logic [K*TW-1:0]         tag_o;
    logic [CW-1:0]           count_o;
    logic                    full_o;

    integer errors = 0;
    integer checks = 0;

    // ------------------------------------------------------------------ DUT
    topk_stream_engine #(.K(K), .DW(DW), .TW(TW)) dut (
        .clk(clk), .rst(rst), .flush(flush),
        .in_valid(in_valid), .in_data(in_data), .in_tag(in_tag),
        .valid_o(valid_o), .data_o(data_o), .tag_o(tag_o),
        .count_o(count_o), .full_o(full_o)
    );

    // ------------------------------------------------------------ clock/dump
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("topk_stream_engine.vcd");
        $dumpvars(0, tb_topk_stream_engine);
    end

    // global watchdog
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

    // ------------------------------------------- golden running Top-K state
    logic signed [DW-1:0] gd [0:K-1];   // descending sorted keys
    logic        [TW-1:0] gt [0:K-1];   // matching tags
    logic                 gv [0:K-1];   // per-slot valid
    integer               gcnt;

    task gm_reset;
        integer i;
        begin
            for (i = 0; i < K; i = i + 1) begin
                gd[i] = '0; gt[i] = '0; gv[i] = 1'b0;
            end
            gcnt = 0;
        end
    endtask

    // behavioral sorted insertion (scalar style, independent of DUT internals)
    task gm_push(input logic signed [DW-1:0] d, input logic [TW-1:0] t);
        integer i, p;
        logic signed [DW-1:0] eff;
        begin
            // find insertion position: first slot whose effective key <= d
            p = K;
            for (i = K-1; i >= 0; i = i - 1) begin
                eff = gv[i] ? gd[i] : NEG_INF;
                if (d >= eff) p = i;
            end
            if (p < K) begin
                // shift [p .. K-2] down by one, then drop old last slot
                for (i = K-1; i > p; i = i - 1) begin
                    gd[i] = gd[i-1]; gt[i] = gt[i-1]; gv[i] = gv[i-1];
                end
                gd[p] = d; gt[p] = t; gv[p] = 1'b1;
                if (gcnt < K) gcnt = gcnt + 1;
            end
        end
    endtask

    // ----------------------------------------------------------- comparator
    task check(input [8*12-1:0] phase);
        integer i;
        logic signed [DW-1:0] dd;
        logic        [TW-1:0] dt;
        begin
            checks = checks + 1;
            if (count_o !== gcnt[CW-1:0]) begin
                $display("[%0t] %0s COUNT mismatch: dut=%0d exp=%0d", $time, phase, count_o, gcnt);
                errors = errors + 1;
            end
            if (full_o !== (gcnt == K)) begin
                $display("[%0t] %0s FULL mismatch: dut=%0b exp=%0b", $time, phase, full_o, (gcnt==K));
                errors = errors + 1;
            end
            for (i = 0; i < K; i = i + 1) begin
                dd = data_o[i*DW +: DW];
                dt = tag_o [i*TW +: TW];
                if (valid_o[i] !== gv[i]) begin
                    $display("[%0t] %0s slot%0d VALID mismatch dut=%0b exp=%0b",
                             $time, phase, i, valid_o[i], gv[i]);
                    errors = errors + 1;
                end
                else if (gv[i]) begin
                    if (dd !== gd[i]) begin
                        $display("[%0t] %0s slot%0d DATA mismatch dut=%0d exp=%0d",
                                 $time, phase, i, dd, gd[i]);
                        errors = errors + 1;
                    end
                    if (dt !== gt[i]) begin
                        $display("[%0t] %0s slot%0d TAG mismatch dut=%0h exp=%0h",
                                 $time, phase, i, dt, gt[i]);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------- stimulus
    task feed(input logic signed [DW-1:0] d, input logic [TW-1:0] t);
        begin
            @(negedge clk);
            in_valid = 1'b1; in_data = d; in_tag = t; flush = 1'b0;
            gm_push(d, t);          // reference accepts it too
            @(posedge clk);         // DUT state updates here
            #1 in_valid = 1'b0;
            check("stream");
        end
    endtask

    task do_flush;
        begin
            @(negedge clk);
            in_valid = 1'b0; flush = 1'b1;
            gm_reset();
            @(posedge clk);
            #1 flush = 1'b0;
            check("flush");
        end
    endtask

    integer v, n;
    integer rd;
    logic [TW-1:0] rt;

    initial begin
        in_valid = 1'b0; in_data = '0; in_tag = '0; flush = 1'b0;
        gm_reset();

        // synchronous reset
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        check("post-reset");

        // ---- directed: ascending fill then overflow --------------------
        for (v = 1; v <= K+4; v = v + 1) feed(v[DW-1:0], v[TW-1:0]);
        do_flush();

        // ---- directed: descending fill (worst case for insertion pos) --
        for (v = 20; v >= 20-(K+4); v = v - 1) feed(v[DW-1:0], v[TW-1:0]);
        do_flush();

        // ---- directed: duplicates (exercise newer-wins tie rule) -------
        feed(12'sd50, 8'hA0);
        feed(12'sd50, 8'hA1);
        feed(12'sd50, 8'hA2);
        feed(12'sd7 , 8'hB0);
        feed(12'sd50, 8'hA3);
        feed(12'sd99, 8'hC0);
        feed(-12'sd3, 8'hD0);
        do_flush();

        // ---- directed: negatives + a mid-stream flush ------------------
        feed(-12'sd100, 8'h01);
        feed(-12'sd5  , 8'h02);
        feed( 12'sd0  , 8'h03);
        do_flush();
        feed( 12'sd0  , 8'h04);
        do_flush();

        // ---- randomized soak -------------------------------------------
        for (n = 0; n < 4000; n = n + 1) begin
            rd = ($random % (1 << DW)) - (1 << (DW-1)); // full signed range
            rt = $random;
            feed(rd[DW-1:0], rt);
            if ((n % 523) == 522) do_flush();
        end

        // ---- final report ----------------------------------------------
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule
