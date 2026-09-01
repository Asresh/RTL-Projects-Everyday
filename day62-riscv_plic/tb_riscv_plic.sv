// Author: Asresh Kuricheti
// Directed and randomized self-checking golden-model testbench.

`timescale 1ns/1ps

module tb_riscv_plic;
    localparam int SOURCES = 8;
    localparam int CONTEXTS = 2;
    localparam int PW = 3;
    localparam int IW = $clog2(SOURCES + 1);
    localparam logic [SOURCES-1:0] EDGE_MASK = 8'b0000_1111;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear_status = 1'b0;
    logic [SOURCES-1:0] irq_source = '0;
    logic priority_we = 1'b0;
    logic [IW-1:0] priority_id = '0;
    logic [PW-1:0] priority_value = '0;
    logic enable_we = 1'b0;
    logic enable_context = 1'b0;
    logic [SOURCES-1:0] enable_value = '0;
    logic threshold_we = 1'b0;
    logic threshold_context = 1'b0;
    logic [PW-1:0] threshold_value = '0;
    logic [CONTEXTS-1:0] claim_req = '0;
    logic [CONTEXTS-1:0] claim_valid;
    logic [CONTEXTS-1:0][IW-1:0] claim_id;
    logic [CONTEXTS-1:0] complete_valid = '0;
    logic [CONTEXTS-1:0][IW-1:0] complete_id = '0;
    logic [CONTEXTS-1:0] irq_notify;
    logic [SOURCES-1:0] pending_bitmap;
    logic [SOURCES-1:0] in_service_bitmap;
    logic protocol_error;
    logic event_overflow;
    logic [IW-1:0] first_error_id;
    logic [CONTEXTS-1:0][15:0] claim_count;

    integer m_priority [0:SOURCES-1];
    logic [SOURCES-1:0] m_enable [0:CONTEXTS-1];
    integer m_threshold [0:CONTEXTS-1];
    logic [SOURCES-1:0] m_pending = '0;
    logic [SOURCES-1:0] m_service = '0;
    integer m_owner [0:SOURCES-1];
    integer m_claim_count [0:CONTEXTS-1];
    integer checks = 0;
    integer errors = 0;
    integer random_claims = 0;
    integer seed = 32'h62c0ffee;

    riscv_plic #(
        .SOURCES(SOURCES), .CONTEXTS(CONTEXTS),
        .PRIORITY_WIDTH(PW), .EDGE_MASK(EDGE_MASK)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (!condition) begin
            errors = errors + 1;
            $display("ERROR @ %0t: %s", $time, message);
        end
    endtask

    function automatic integer best_for_context(input integer ctx);
        integer best_id;
        integer best_prio;
        begin
            best_id = 0;
            best_prio = 0;
            for (integer src = 0; src < SOURCES; src++) begin
                if (m_pending[src] && !m_service[src] && m_enable[ctx][src] &&
                    (m_priority[src] > m_threshold[ctx]) &&
                    (m_priority[src] > best_prio)) begin
                    best_id = src + 1;
                    best_prio = m_priority[src];
                end
            end
            best_for_context = best_id;
        end
    endfunction

    task automatic check_state;
        integer expected;
        begin
            #1;
            check(pending_bitmap === m_pending, "pending bitmap differs from model");
            check(in_service_bitmap === m_service, "in-service bitmap differs from model");
            for (integer ctx = 0; ctx < CONTEXTS; ctx++) begin
                expected = best_for_context(ctx);
                check(irq_notify[ctx] === (expected != 0),
                      $sformatf("context %0d notification mismatch", ctx));
                check(claim_count[ctx] == m_claim_count[ctx],
                      $sformatf("context %0d claim counter mismatch", ctx));
            end
        end
    endtask

    task automatic set_priority(input integer id, input integer value);
        @(negedge clk);
        priority_we = 1'b1;
        priority_id = id;
        priority_value = value;
        @(posedge clk);
        m_priority[id-1] = value;
        @(negedge clk);
        priority_we = 1'b0;
        check_state();
    endtask

    task automatic set_enable(input integer ctx, input logic [SOURCES-1:0] value);
        @(negedge clk);
        enable_we = 1'b1;
        enable_context = ctx;
        enable_value = value;
        @(posedge clk);
        m_enable[ctx] = value;
        @(negedge clk);
        enable_we = 1'b0;
        check_state();
    endtask

    task automatic set_threshold(input integer ctx, input integer value);
        @(negedge clk);
        threshold_we = 1'b1;
        threshold_context = ctx;
        threshold_value = value;
        @(posedge clk);
        m_threshold[ctx] = value;
        @(negedge clk);
        threshold_we = 1'b0;
        check_state();
    endtask

    task automatic pulse_edge(input integer id);
        @(negedge clk);
        irq_source[id-1] = 1'b1;
        @(posedge clk);
        if (!m_pending[id-1])
            m_pending[id-1] = 1'b1;
        @(negedge clk);
        irq_source[id-1] = 1'b0;
        @(posedge clk);
        @(negedge clk);
        check_state();
    endtask

    task automatic drive_level(input integer id, input logic value);
        @(negedge clk);
        irq_source[id-1] = value;
        @(posedge clk);
        if (!m_service[id-1])
            m_pending[id-1] = value;
        @(negedge clk);
        check_state();
    endtask

    task automatic do_claim(input integer ctx);
        integer expected;
        begin
            expected = best_for_context(ctx);
            @(negedge clk);
            claim_req[ctx] = 1'b1;
            #1;
            check(claim_valid[ctx] === (expected != 0),
                  $sformatf("context %0d claim-valid mismatch", ctx));
            check(claim_id[ctx] == expected,
                  $sformatf("context %0d expected ID %0d, got %0d",
                            ctx, expected, claim_id[ctx]));
            @(posedge clk);
            if (expected != 0) begin
                m_pending[expected-1] = 1'b0;
                m_service[expected-1] = 1'b1;
                m_owner[expected-1] = ctx;
                m_claim_count[ctx] = m_claim_count[ctx] + 1;
                random_claims = random_claims + 1;
            end
            @(negedge clk);
            claim_req[ctx] = 1'b0;
            check_state();
        end
    endtask

    task automatic do_complete(input integer ctx, input integer id,
                               input logic expect_legal);
        @(negedge clk);
        complete_valid[ctx] = 1'b1;
        complete_id[ctx] = id;
        @(posedge clk);
        if (expect_legal) begin
            m_service[id-1] = 1'b0;
            if (!EDGE_MASK[id-1] && irq_source[id-1])
                m_pending[id-1] = 1'b1;
        end
        @(negedge clk);
        complete_valid[ctx] = 1'b0;
        complete_id[ctx] = '0;
        check_state();
    endtask

    task automatic simultaneous_claim;
        integer first_id;
        integer second_id;
        begin
            first_id = best_for_context(0);
            m_pending[first_id-1] = 1'b0;
            second_id = best_for_context(1);
            m_pending[first_id-1] = 1'b1;
            @(negedge clk);
            claim_req = '1;
            #1;
            check(claim_valid == '1, "simultaneous claims were not both granted");
            check(claim_id[0] == first_id, "context 0 simultaneous winner mismatch");
            check(claim_id[1] == second_id, "context 1 did not skip reserved source");
            @(posedge clk);
            m_pending[first_id-1] = 1'b0;
            m_pending[second_id-1] = 1'b0;
            m_service[first_id-1] = 1'b1;
            m_service[second_id-1] = 1'b1;
            m_owner[first_id-1] = 0;
            m_owner[second_id-1] = 1;
            m_claim_count[0] = m_claim_count[0] + 1;
            m_claim_count[1] = m_claim_count[1] + 1;
            @(negedge clk);
            claim_req = '0;
            check_state();
        end
    endtask

    always @(posedge clk) begin
        if ($time > 120000) begin
            $display("ERROR: timeout");
            $display("RESULT: *** FAIL ***");
            $fatal(1, "testbench timeout");
        end
    end

    initial begin
        $dumpfile("riscv_plic.vcd");
        $dumpvars(0, tb_riscv_plic);
        for (integer src = 0; src < SOURCES; src++) begin
            m_priority[src] = 0;
            m_owner[src] = 0;
        end
        for (integer ctx = 0; ctx < CONTEXTS; ctx++) begin
            m_enable[ctx] = '0;
            m_threshold[ctx] = 0;
            m_claim_count[ctx] = 0;
        end

        repeat (4) @(posedge clk);
        #1;
        check(pending_bitmap == '0 && in_service_bitmap == '0,
              "reset did not clear interrupt state");
        check(irq_notify == '0 && !protocol_error && !event_overflow,
              "reset did not clear outputs and diagnostics");
        rst_n = 1'b1;

        for (integer id = 1; id <= SOURCES; id++)
            set_priority(id, ((id * 3) % 7) + 1);
        set_enable(0, '1);
        set_enable(1, '1);
        set_threshold(0, 0);
        set_threshold(1, 2);

        pulse_edge(1);
        pulse_edge(2);
        pulse_edge(3);
        do_claim(0);

        do_complete(1, 2, 1'b0);
        check(protocol_error, "wrong-context completion was not diagnosed");
        check(first_error_id == 2, "first failing completion ID was not retained");
        do_complete(0, 2, 1'b1);

        @(negedge clk);
        clear_status = 1'b1;
        @(posedge clk);
        m_claim_count[0] = 0;
        m_claim_count[1] = 0;
        @(negedge clk);
        clear_status = 1'b0;
        #1;
        check(!protocol_error && first_error_id == 0,
              "clear_status did not clear sticky protocol diagnostics");

        set_priority(1, 5);
        set_priority(2, 5);
        set_priority(3, 7);
        set_priority(4, 7);
        set_threshold(1, 0);
        pulse_edge(1);
        pulse_edge(2);
        pulse_edge(3);
        pulse_edge(4);
        simultaneous_claim();
        do_complete(0, 3, 1'b1);
        do_complete(1, 4, 1'b1);

        drive_level(5, 1'b1);
        do_claim(0);
        do_complete(0, 5, 1'b1);
        check(m_pending[4], "asserted level source did not re-pend on completion");
        do_claim(0);
        drive_level(5, 1'b0);
        do_complete(0, 5, 1'b1);

        pulse_edge(1);
        pulse_edge(1);
        check(event_overflow, "second queued edge was not diagnosed as overflow");

        for (integer iteration = 0; iteration < 80; iteration++) begin
            integer choice;
            integer id;
            integer ctx;
            choice = $urandom(seed) % 4;
            id = ($urandom(seed) % SOURCES) + 1;
            ctx = $urandom(seed) % CONTEXTS;
            case (choice)
                0: begin
                    id = ($urandom(seed) % 4) + 1;
                    pulse_edge(id);
                end
                1: begin
                    id = ($urandom(seed) % 4) + 5;
                    drive_level(id, $urandom(seed) & 1);
                end
                2: do_claim(ctx);
                3: begin
                    integer found;
                    found = 0;
                    for (integer src = 0; src < SOURCES; src++) begin
                        if ((found == 0) && m_service[src] && (m_owner[src] == ctx))
                            found = src + 1;
                    end
                    if (found != 0)
                        do_complete(ctx, found, 1'b1);
                    else
                        do_claim(ctx);
                end
            endcase
        end

        check(random_claims >= 8, "randomized phase executed too few claims");
        check(checks >= 350, "insufficient self-checking coverage");

        if (errors == 0) begin
            $display("Completed %0d checks and %0d claimed interrupts", checks,
                     m_claim_count[0] + m_claim_count[1]);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("Completed with %0d errors across %0d checks", errors, checks);
            $display("RESULT: *** FAIL ***");
            $fatal(1, "self-checking testbench failed");
        end
        $finish;
    end
endmodule
