// Author: Asresh Kuricheti
// Self-checking directed and randomized testbench with an independent scoreboard.

module tb_pcie_credit_scheduler;
    timeunit 1ns;
    timeprecision 1ps;

    localparam int VCS = 2;
    localparam int DEPTH = 4;
    localparam int MAX_IDS = 512;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear_status;
    logic in_valid, in_ready;
    logic in_vc;
    logic [1:0] in_class;
    logic [11:0] in_id;
    logic [7:0] in_data_credits;
    logic fc_valid, fc_vc;
    logic [1:0] fc_class;
    logic [7:0] fc_header_inc, fc_data_inc;
    logic out_valid, out_ready, out_vc;
    logic [1:0] out_class;
    logic [11:0] out_id;
    logic [7:0] out_data_credits;
    logic completion_urgent, credit_blocked;
    logic protocol_error, queue_overflow;
    logic [15:0] accepted_count, transmitted_count;

    logic expected_valid [0:MAX_IDS-1];
    logic expected_sent [0:MAX_IDS-1];
    logic expected_vc [0:MAX_IDS-1];
    logic [1:0] expected_class [0:MAX_IDS-1];
    logic [7:0] expected_data [0:MAX_IDS-1];
    integer last_seq [0:5];
    integer checks = 0;
    integer errors = 0;
    integer accepted = 0;
    integer sent = 0;
    integer next_id = 1;

    pcie_credit_scheduler #(.VCS(VCS), .DEPTH(DEPTH)) dut (.*);

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        checks++;
        if (!condition) begin
            errors++;
            $error("CHECK FAILED: %s", message);
        end
    endtask

    task automatic drive_idle;
        in_valid = 1'b0;
        in_vc = '0;
        in_class = '0;
        in_id = '0;
        in_data_credits = '0;
        fc_valid = 1'b0;
        fc_vc = '0;
        fc_class = '0;
        fc_header_inc = '0;
        fc_data_inc = '0;
        clear_status = 1'b0;
    endtask

    task automatic add_credit(input int vc, input int cls,
                              input int hdr, input int dat);
        @(negedge clk);
        drive_idle();
        fc_valid = 1'b1;
        fc_vc = vc[0];
        fc_class = cls[1:0];
        fc_header_inc = hdr[7:0];
        fc_data_inc = dat[7:0];
        @(posedge clk);
        #1;
        drive_idle();
    endtask

    task automatic offer(input int vc, input int cls, input int dat);
        integer id;
        id = next_id;
        next_id++;
        @(negedge clk);
        drive_idle();
        in_valid = 1'b1;
        in_vc = vc[0];
        in_class = cls[1:0];
        in_id = id[11:0];
        in_data_credits = dat[7:0];
        @(posedge clk);
        if (in_ready) begin
            expected_valid[id] = 1'b1;
            expected_vc[id] = vc[0];
            expected_class[id] = cls[1:0];
            expected_data[id] = dat[7:0];
            accepted++;
        end
        #1;
        drive_idle();
    endtask

    always @(posedge clk) begin
        integer q;
        if (rst_n && out_valid && out_ready) begin
            check((out_id > 0) && (out_id < MAX_IDS), "output ID is in scoreboard range");
            if ((out_id > 0) && (out_id < MAX_IDS)) begin
                check(expected_valid[out_id], "output was previously accepted");
                check(!expected_sent[out_id], "packet is transmitted only once");
                check(out_vc == expected_vc[out_id], "virtual channel metadata is preserved");
                check(out_class == expected_class[out_id], "traffic class metadata is preserved");
                check(out_data_credits == expected_data[out_id], "data-credit requirement is preserved");
                q = (out_vc * 3) + out_class;
                check(out_id > last_seq[q], "FIFO order is preserved within each VC/class queue");
                last_seq[q] = out_id;
                expected_sent[out_id] = 1'b1;
                sent++;
            end
        end
    end

    initial begin : timeout_watchdog
        #20000;
        $fatal(1, "TIMEOUT: testbench did not finish");
    end

    initial begin : stimulus
        integer i;
        integer vc;
        integer cls;
        integer dat;
        integer choice;

        $dumpfile("pcie_credit_scheduler.vcd");
        $dumpvars(0, tb_pcie_credit_scheduler);
        drive_idle();
        out_ready = 1'b0;
        for (i = 0; i < MAX_IDS; i++) begin
            expected_valid[i] = 1'b0;
            expected_sent[i] = 1'b0;
            expected_vc[i] = 1'b0;
            expected_class[i] = '0;
            expected_data[i] = '0;
        end
        for (i = 0; i < 6; i++) last_seq[i] = 0;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        check(!out_valid && !protocol_error && !queue_overflow,
              "reset produces an idle, clean interface");

        // Directed credit gate: a packet remains blocked until both header and
        // payload credits exist, then survives downstream backpressure.
        offer(0, 0, 3);
        repeat (2) @(posedge clk);
        check(credit_blocked && !out_valid, "packet blocks with zero credits");
        add_credit(0, 0, 1, 2);
        repeat (2) @(posedge clk);
        check(credit_blocked && !out_valid, "insufficient data credits still block");
        add_credit(0, 0, 0, 1);
        repeat (2) @(posedge clk);
        check(out_valid && (out_id == 1), "eligible packet reaches the elastic output");
        repeat (2) begin
            @(posedge clk);
            check(out_valid && (out_id == 1), "output is stable during backpressure");
        end
        out_ready = 1'b1;
        @(posedge clk);
        #1;

        // Fill completion queues to exercise the anti-deadlock urgent path.
        out_ready = 1'b0;
        add_credit(0, 2, 8, 32);
        offer(0, 2, 1);
        offer(0, 2, 2);
        offer(0, 2, 3);
        offer(0, 2, 4);
        check(completion_urgent, "near-full completion queue asserts urgency");
        out_ready = 1'b1;

        // Seed every queue, then randomize credit returns, arrivals, and stalls.
        for (vc = 0; vc < VCS; vc++)
            for (cls = 0; cls < 3; cls++)
                add_credit(vc, cls, 20, 80);

        for (i = 0; i < 360; i++) begin
            @(negedge clk);
            drive_idle();
            out_ready = ($urandom_range(0, 4) != 0);
            choice = $urandom_range(0, 9);
            vc = $urandom_range(0, VCS-1);
            cls = $urandom_range(0, 2);
            dat = $urandom_range(0, 7);
            if (choice < 6) begin
                in_valid = 1'b1;
                in_vc = vc[0];
                in_class = cls[1:0];
                in_id = next_id[11:0];
                in_data_credits = dat[7:0];
            end else begin
                fc_valid = 1'b1;
                fc_vc = vc[0];
                fc_class = cls[1:0];
                fc_header_inc = $urandom_range(1, 5);
                fc_data_inc = $urandom_range(4, 24);
            end
            @(posedge clk);
            if (in_valid && in_ready) begin
                expected_valid[next_id] = 1'b1;
                expected_vc[next_id] = in_vc;
                expected_class[next_id] = in_class;
                expected_data[next_id] = in_data_credits;
                accepted++;
                next_id++;
            end
        end

        // Return ample credits and drain all accepted traffic.
        #1;
        drive_idle();
        out_ready = 1'b1;
        for (vc = 0; vc < VCS; vc++)
            for (cls = 0; cls < 3; cls++)
                add_credit(vc, cls, 200, 200);

        i = 0;
        while ((sent < accepted) && (i < 500)) begin
            @(posedge clk);
            i++;
        end
        check(sent == accepted, "every accepted packet is eventually transmitted");
        check(!protocol_error, "legal traffic raises no protocol error");
        check(accepted_count == accepted, "accepted telemetry matches scoreboard");
        check(transmitted_count == sent, "transmit telemetry matches scoreboard");

        @(negedge clk);
        drive_idle();
        in_valid = 1'b1;
        in_class = 2'd3;
        @(posedge clk);
        #1;
        check(protocol_error, "invalid traffic class sets sticky protocol error");

        $display("Accepted packets: %0d", accepted);
        $display("Transmitted packets: %0d", sent);
        $display("Checks: %0d", checks);
        if (errors == 0) begin
            $display("RESULT: *** PASS ***");
            $finish;
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1, "Self-checking testbench failed");
        end
    end
endmodule
