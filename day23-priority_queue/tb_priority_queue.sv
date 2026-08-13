// ============================================================================
// tb_priority_queue.sv
// ----------------------------------------------------------------------------
// Self-checking testbench for the systolic register-array priority queue.
//
//   Independent golden model: a plainly-coded behavioral min-priority-queue
//   kept in an ascending-sorted fixed array {gk, gd, gv} with an occupancy
//   counter. Each cycle it applies the SAME {enq, deq} request the DUT sees,
//   using the same accept rules (a lone enq is dropped when full, a lone deq
//   when empty, enq&deq is a replace-min) and the same STRICT-'>' tie rule so
//   equal keys pop in arrival order. The reference is written in a scalar
//   sequential shift style — structurally different from the DUT's parallel
//   base-shift + monotone-priority-encode + one-shot insert datapath — so it
//   validates the DUT rather than mirroring it.
//
//   After every operation the DUT is checked in full against the model:
//   head view (valid_o/min_key_o/min_data_o), the whole sorted array
//   (slot_valid/key/data), occupancy (count_o/full_o/empty_o) and the
//   overflow_o/underflow_o status pulses.
//
//   Coverage: reset, fill-to-full, overflow-on-full, drain-to-empty,
//   underflow-on-empty, replace-min on full/empty, ascending/descending/
//   duplicate-key streams, interleaved enq/deq, mid-stream flush, and 4000
//   randomized operations. Directed + randomized, global timeout, VCD dump.
// ============================================================================

`timescale 1ns/1ps

module tb_priority_queue;

    localparam int N  = 8;
    localparam int KW = 12;
    localparam int DW = 8;
    localparam int CW = $clog2(N+1);

    localparam logic [KW-1:0] KEY_INF = {KW{1'b1}};

    logic                clk, rst, flush;
    logic                enq, deq;
    logic [KW-1:0]       enq_key;
    logic [DW-1:0]       enq_data;

    logic                valid_o;
    logic [KW-1:0]       min_key_o;
    logic [DW-1:0]       min_data_o;
    logic [N-1:0]        slot_valid_o;
    logic [N*KW-1:0]     slot_key_o;
    logic [N*DW-1:0]     slot_data_o;
    logic [CW-1:0]       count_o;
    logic                full_o, empty_o, overflow_o, underflow_o;

    integer errors = 0;
    integer checks = 0;

    // ------------------------------------------------------------------ DUT
    priority_queue #(.N(N), .KW(KW), .DW(DW)) dut (
        .clk(clk), .rst(rst), .flush(flush),
        .enq(enq), .deq(deq), .enq_key(enq_key), .enq_data(enq_data),
        .valid_o(valid_o), .min_key_o(min_key_o), .min_data_o(min_data_o),
        .slot_valid_o(slot_valid_o), .slot_key_o(slot_key_o), .slot_data_o(slot_data_o),
        .count_o(count_o), .full_o(full_o), .empty_o(empty_o),
        .overflow_o(overflow_o), .underflow_o(underflow_o)
    );

    // ------------------------------------------------------------ clock/dump
    initial clk = 1'b0;
    always #5 clk = ~clk;

    initial begin
        $dumpfile("priority_queue.vcd");
        $dumpvars(0, tb_priority_queue);
    end

    // global watchdog
    initial begin
        #800000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

    // ------------------------------------------- golden priority-queue state
    logic [KW-1:0] gk [0:N-1];      // ascending sorted keys
    logic [DW-1:0] gd [0:N-1];      // matching payloads
    logic          gv [0:N-1];      // per-slot valid
    integer        gcnt;
    // expected registered status pulses (mirrors DUT's registered flags)
    logic          exp_ovf, exp_udf;

    task gm_reset;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                gk[i] = '0; gd[i] = '0; gv[i] = 1'b0;
            end
            gcnt = 0; exp_ovf = 1'b0; exp_udf = 1'b0;
        end
    endtask

    // apply one {en,dq} request to the reference (scalar sequential style)
    task gm_step(input logic en, input logic dq,
                 input logic [KW-1:0] k, input logic [DW-1:0] d);
        integer i, p;
        logic gdo_enq, gdo_deq;
        logic [KW-1:0] eff;
        begin
            gdo_deq = dq && (gcnt != 0);
            gdo_enq = en && (dq || (gcnt != N));

            // registered status pulses reflect the raw request vs. occupancy
            exp_ovf = en && !dq && (gcnt == N);
            exp_udf = dq && !en && (gcnt == 0);

            // --- extract-min: shift every entry down by one -----------------
            if (gdo_deq) begin
                for (i = 0; i < N-1; i = i + 1) begin
                    gk[i] = gk[i+1]; gd[i] = gd[i+1]; gv[i] = gv[i+1];
                end
                gk[N-1] = '0; gd[N-1] = '0; gv[N-1] = 1'b0;
            end

            // --- insert: find first slot whose effective key strictly > k ---
            if (gdo_enq) begin
                p = N;
                for (i = N-1; i >= 0; i = i - 1) begin
                    eff = gv[i] ? gk[i] : KEY_INF;
                    if (eff > k) p = i;
                end
                // shift [p .. N-2] up by one, then drop the new entry at p
                for (i = N-1; i > p; i = i - 1) begin
                    gk[i] = gk[i-1]; gd[i] = gd[i-1]; gv[i] = gv[i-1];
                end
                gk[p] = k; gd[p] = d; gv[p] = 1'b1;
            end

            gcnt = gcnt + (gdo_enq ? 1 : 0) - (gdo_deq ? 1 : 0);
        end
    endtask

    // ----------------------------------------------------------- comparator
    task check(input [8*16-1:0] phase);
        integer i;
        logic [KW-1:0] dk;
        logic [DW-1:0] dd;
        begin
            checks = checks + 1;
            if (count_o !== gcnt[CW-1:0]) begin
                $display("[%0t] %0s COUNT mismatch dut=%0d exp=%0d", $time, phase, count_o, gcnt);
                errors = errors + 1;
            end
            if (full_o !== (gcnt == N)) begin
                $display("[%0t] %0s FULL mismatch dut=%0b exp=%0b", $time, phase, full_o, (gcnt==N));
                errors = errors + 1;
            end
            if (empty_o !== (gcnt == 0)) begin
                $display("[%0t] %0s EMPTY mismatch dut=%0b exp=%0b", $time, phase, empty_o, (gcnt==0));
                errors = errors + 1;
            end
            if (valid_o !== gv[0]) begin
                $display("[%0t] %0s HEAD-VALID mismatch dut=%0b exp=%0b", $time, phase, valid_o, gv[0]);
                errors = errors + 1;
            end
            else if (gv[0]) begin
                if (min_key_o !== gk[0]) begin
                    $display("[%0t] %0s MIN-KEY mismatch dut=%0d exp=%0d", $time, phase, min_key_o, gk[0]);
                    errors = errors + 1;
                end
                if (min_data_o !== gd[0]) begin
                    $display("[%0t] %0s MIN-DATA mismatch dut=%0h exp=%0h", $time, phase, min_data_o, gd[0]);
                    errors = errors + 1;
                end
            end
            if (overflow_o !== exp_ovf) begin
                $display("[%0t] %0s OVERFLOW mismatch dut=%0b exp=%0b", $time, phase, overflow_o, exp_ovf);
                errors = errors + 1;
            end
            if (underflow_o !== exp_udf) begin
                $display("[%0t] %0s UNDERFLOW mismatch dut=%0b exp=%0b", $time, phase, underflow_o, exp_udf);
                errors = errors + 1;
            end
            for (i = 0; i < N; i = i + 1) begin
                dk = slot_key_o [i*KW +: KW];
                dd = slot_data_o[i*DW +: DW];
                if (slot_valid_o[i] !== gv[i]) begin
                    $display("[%0t] %0s slot%0d VALID mismatch dut=%0b exp=%0b",
                             $time, phase, i, slot_valid_o[i], gv[i]);
                    errors = errors + 1;
                end
                else if (gv[i]) begin
                    if (dk !== gk[i]) begin
                        $display("[%0t] %0s slot%0d KEY mismatch dut=%0d exp=%0d",
                                 $time, phase, i, dk, gk[i]);
                        errors = errors + 1;
                    end
                    if (dd !== gd[i]) begin
                        $display("[%0t] %0s slot%0d DATA mismatch dut=%0h exp=%0h",
                                 $time, phase, i, dd, gd[i]);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    // ------------------------------------------------------------- stimulus
    // Drive one {en,dq} request, mirror it in the reference, then check.
    task op(input logic en, input logic dq,
            input logic [KW-1:0] k, input logic [DW-1:0] d,
            input [8*16-1:0] phase);
        begin
            @(negedge clk);
            enq = en; deq = dq; enq_key = k; enq_data = d; flush = 1'b0;
            gm_step(en, dq, k, d);
            @(posedge clk);
            #1 enq = 1'b0; deq = 1'b0;
            check(phase);
        end
    endtask

    task push(input logic [KW-1:0] k, input logic [DW-1:0] d); begin op(1'b1,1'b0,k,d,"push"); end endtask
    task pop;  begin op(1'b0,1'b1,'0,'0,"pop"); end endtask

    task do_flush;
        begin
            @(negedge clk);
            enq = 1'b0; deq = 1'b0; flush = 1'b1;
            gm_reset();
            @(posedge clk);
            #1 flush = 1'b0;
            check("flush");
        end
    endtask

    integer i, n;
    logic        r_en, r_dq;
    logic [KW-1:0] r_k;
    logic [DW-1:0] r_d;

    initial begin
        enq = 1'b0; deq = 1'b0; enq_key = '0; enq_data = '0; flush = 1'b0;
        gm_reset();

        // synchronous reset
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1 rst = 1'b0;
        check("post-reset");

        // ---- directed: fill to full in random-ish key order --------------
        push(12'd50, 8'h10);
        push(12'd20, 8'h11);
        push(12'd80, 8'h12);
        push(12'd20, 8'h13);   // duplicate key -> must sit AFTER the first 20
        push(12'd5 , 8'h14);
        push(12'd95, 8'h15);
        push(12'd35, 8'h16);
        push(12'd60, 8'h17);   // now full (N=8)
        // overflow: enqueue while full -> ignored, overflow pulse
        push(12'd1 , 8'hEE);

        // ---- directed: drain to empty (keys must come out ascending) -----
        repeat (N) pop();
        // underflow: pop while empty -> ignored, underflow pulse
        pop();

        do_flush();

        // ---- directed: ascending stream then descending stream -----------
        for (i = 1; i <= N; i = i + 1) push(i[KW-1:0], i[DW-1:0]);
        repeat (N) pop();
        for (i = N; i >= 1; i = i - 1) push(i[KW-1:0], (8'h80 | i[DW-1:0]));
        repeat (N) pop();
        do_flush();

        // ---- directed: replace-min (enq & deq together) ------------------
        push(12'd40, 8'h01);
        push(12'd10, 8'h02);
        push(12'd70, 8'h03);
        op(1'b1, 1'b1, 12'd25, 8'h04, "replace");   // pop 10, insert 25
        op(1'b1, 1'b1, 12'd5 , 8'h05, "replace");   // pop 25, insert 5
        op(1'b1, 1'b1, 12'd99, 8'h06, "replace");   // pop 5, insert 99
        repeat (3) pop();
        // replace-min on empty behaves as a plain enqueue
        op(1'b1, 1'b1, 12'd7, 8'h07, "replace-empty");
        pop();
        do_flush();

        // ---- directed: interleaved enq/deq keeping a partial queue -------
        push(12'd30, 8'hA0);
        push(12'd12, 8'hA1);
        pop();                 // removes 12
        push(12'd18, 8'hA2);
        push(12'd18, 8'hA3);   // duplicate again
        pop();                 // removes one 18 (older one)
        push(12'd4 , 8'hA4);
        pop(); pop(); pop();
        do_flush();

        // ---- randomized soak ---------------------------------------------
        for (n = 0; n < 4000; n = n + 1) begin
            r_en = $random;
            r_dq = $random;
            r_k  = $random % (1 << KW);
            r_d  = $random;
            op(r_en, r_dq, r_k, r_d, "rand");
            if ((n % 617) == 616) do_flush();
        end

        // ---- final report ------------------------------------------------
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule
