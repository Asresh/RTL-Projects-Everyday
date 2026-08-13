//==============================================================================
// Testbench  : tb_round_robin_arbiter
// Description : Self-checking testbench for round_robin_arbiter.
//               The golden reference is an INDEPENDENT implementation: a
//               rotating priority pointer that scans requesters in round-robin
//               order. The DUT uses a mask-based one-hot scheme, so agreement
//               between the two different implementations is a strong check.
//
//               Registered state (RTL mask / reference pointer) is sampled on
//               the negative clock edge, where the combinational grant and the
//               expected grant are both settled and race-free.
// Author      : Asresh Kuricheti
//==============================================================================
`timescale 1ns/1ps

module tb_round_robin_arbiter;

    localparam int N = 4;
    localparam int IW = $clog2(N);

    // DUT interface
    logic          clk, rst_n;
    logic [N-1:0]  req;
    logic [N-1:0]  grant;
    logic          grant_valid;
    logic [IW-1:0] grant_index;

    // Reference model + scoreboard state
    int            rr_ptr;                 // next requester to start scanning from
    logic [N-1:0]  exp_grant;
    logic          exp_valid;
    int            exp_index;
    int            errors = 0;
    int            checks = 0;

    //--------------------------------------------------------------------------
    // DUT
    //--------------------------------------------------------------------------
    round_robin_arbiter #(.N(N)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .req        (req),
        .grant      (grant),
        .grant_valid(grant_valid),
        .grant_index(grant_index)
    );

    //--------------------------------------------------------------------------
    // Clock: 100 MHz
    //--------------------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // Golden reference: rotating-pointer round-robin (independent of the DUT).
    // Scan requesters starting at rr_ptr, wrapping, and grant the first pending.
    //--------------------------------------------------------------------------
    always_comb begin
        exp_grant = '0;
        exp_valid = 1'b0;
        exp_index = 0;
        for (int k = 0; k < N; k++) begin
            automatic int idx = (rr_ptr + k) % N;
            if (!exp_valid && req[idx]) begin
                exp_valid      = 1'b1;
                exp_index      = idx;
                exp_grant[idx] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rr_ptr <= 0;
        else if (exp_valid)
            rr_ptr <= (exp_index + 1) % N;
    end

    //--------------------------------------------------------------------------
    // Scoreboard (negedge: registered state + combinational outputs are stable)
    //--------------------------------------------------------------------------
    always @(negedge clk) begin
        if (rst_n) begin
            checks++;

            if (grant !== exp_grant) begin
                errors++;
                $error("[%0t] GRANT MISMATCH: req=%b grant=%b expected=%b",
                       $time, req, grant, exp_grant);
            end

            if (grant_valid !== exp_valid) begin
                errors++;
                $error("[%0t] VALID MISMATCH: req=%b grant_valid=%b expected=%b",
                       $time, req, grant_valid, exp_valid);
            end

            if (exp_valid && (grant_index !== IW'(exp_index))) begin
                errors++;
                $error("[%0t] INDEX MISMATCH: grant_index=%0d expected=%0d",
                       $time, grant_index, exp_index);
            end

            // grant must be one-hot when valid, all-zero otherwise.
            if (grant_valid && ($countones(grant) != 1)) begin
                errors++;
                $error("[%0t] ONE-HOT VIOLATION: grant=%b", $time, grant);
            end
            if (!grant_valid && (grant !== '0)) begin
                errors++;
                $error("[%0t] IDLE GRANT VIOLATION: grant=%b", $time, grant);
            end
        end
    end

    //--------------------------------------------------------------------------
    // Stimulus helpers
    //--------------------------------------------------------------------------
    task automatic do_reset();
        req   = '0;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
    endtask

    // Drive a request vector and hold it for exactly one clock cycle.
    task automatic step(input logic [N-1:0] r);
        req = r;
        @(posedge clk);
    endtask

    //--------------------------------------------------------------------------
    // Test sequence
    //--------------------------------------------------------------------------
    initial begin
        $display("==== round_robin_arbiter test start ====");
        do_reset();

        // 1) Idle: no requests => no grant.
        step('0);
        step('0);

        // 2) Single requester held high: always granted, index stable.
        repeat (4) step(4'b0100);

        // 3) All requesters high for several cycles => grant rotates 0,1,2,3,0...
        repeat (6) step(4'b1111);

        // 4) Sparse / wrapping patterns to exercise the mask wrap-around.
        step(4'b1001);
        step(4'b1001);
        step(4'b0110);
        step(4'b1010);
        step(4'b0001);
        step(4'b1000);

        // 5) Randomized traffic, fully scoreboarded.
        for (int i = 0; i < 300; i++)
            step(N'($urandom));

        step('0);
        repeat (2) @(posedge clk);

        //----------------------------------------------------------------------
        $display("==== round_robin_arbiter test done ====");
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

    // Waveform dump
    initial begin
        $dumpfile("round_robin_arbiter.vcd");
        $dumpvars(0, tb_round_robin_arbiter);
    end

endmodule
