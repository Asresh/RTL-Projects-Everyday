// Author: Asresh Kuricheti
// Self-checking directed and randomized testbench for DDR read-eye training.
`timescale 1ns/1ps

module tb_ddr_read_eye_trainer;
    localparam integer LANES = 4;
    localparam integer TAPS = 16;
    localparam integer SAMPLES = 5;
    localparam integer MIN_EYE = 4;
    localparam integer LANE_W = $clog2(LANES);
    localparam integer TAP_W = $clog2(TAPS);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start;
    logic busy, done;
    logic [LANE_W-1:0] lane_select;
    logic [TAP_W-1:0] tap_value;
    logic tap_load, sample_req;
    logic sample_valid, sample_data, expected_data;
    logic [LANES*TAP_W-1:0] trained_taps;
    logic [LANES-1:0] lane_pass;
    logic training_failed;
    logic [LANE_W-1:0] first_failed_lane;

    integer eye_lo [0:LANES-1];
    integer eye_hi [0:LANES-1];
    integer checks = 0;
    integer runs = 0;
    integer seed = 32'h58dd2026;
    integer lane;
    integer timeout;
    logic response_pending;

    ddr_read_eye_trainer #(
        .LANES(LANES), .TAP_COUNT(TAPS), .SAMPLES_PER_TAP(SAMPLES),
        .SETTLE_CYCLES(1), .MIN_EYE_TAPS(MIN_EYE)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("CHECK FAILED: %s at t=%0t", message, $time);
                $fatal(1);
            end
        end
    endtask

    // PHY/channel model: responses arrive after zero or one backpressure cycle.
    always @(negedge clk) begin
        sample_valid <= 1'b0;
        if (!rst_n) begin
            response_pending <= 1'b0;
            expected_data <= 1'b0;
            sample_data <= 1'b0;
        end else begin
            if (sample_req && (!response_pending) && (($urandom(seed) % 4) != 0)) begin
                sample_valid <= 1'b1;
                sample_data <= ((tap_value >= eye_lo[lane_select]) &&
                                (tap_value <= eye_hi[lane_select])) ? expected_data : ~expected_data;
            end else if (sample_req) begin
                response_pending <= 1'b1;
            end

            if (response_pending && sample_req) begin
                sample_valid <= 1'b1;
                sample_data <= ((tap_value >= eye_lo[lane_select]) &&
                                (tap_value <= eye_hi[lane_select])) ? expected_data : ~expected_data;
                response_pending <= 1'b0;
            end
        end
    end

    task automatic run_case(input string label);
        integer expected_center;
        integer expected_first_fail;
        logic expected_any_fail;
        begin
            runs = runs + 1;
            @(negedge clk);
            start <= 1'b1;
            @(negedge clk);
            start <= 1'b0;

            timeout = 0;
            while (!done && timeout < 10000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            check(done, {label, ": timeout"});

            expected_any_fail = 1'b0;
            expected_first_fail = 0;
            $display("%s: lane_pass=%b taps=%h", label, lane_pass, trained_taps);
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if ((eye_hi[lane] - eye_lo[lane] + 1) >= MIN_EYE) begin
                    expected_center = eye_lo[lane] + ((eye_hi[lane] - eye_lo[lane]) / 2);
                    check(lane_pass[lane] === 1'b1, {label, ": lane should pass"});
                    check(trained_taps[lane*TAP_W +: TAP_W] == expected_center,
                          {label, ": trained center mismatch"});
                end else begin
                    check(lane_pass[lane] === 1'b0, {label, ": lane should fail"});
                    check(trained_taps[lane*TAP_W +: TAP_W] == 0,
                          {label, ": failed lane tap should be zero"});
                    if (!expected_any_fail) expected_first_fail = lane;
                    expected_any_fail = 1'b1;
                end
            end
            check(training_failed == expected_any_fail, {label, ": aggregate failure mismatch"});
            if (expected_any_fail)
                check(first_failed_lane == expected_first_fail, {label, ": first failed lane mismatch"});
            @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("ddr_read_eye_trainer.vcd");
        $dumpvars(0, tb_ddr_read_eye_trainer);
        start = 1'b0;
        sample_valid = 1'b0;
        sample_data = 1'b0;
        expected_data = 1'b0;
        response_pending = 1'b0;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;

        eye_lo[0]=2; eye_hi[0]=9;
        eye_lo[1]=5; eye_hi[1]=12;
        eye_lo[2]=0; eye_hi[2]=5;
        eye_lo[3]=11; eye_hi[3]=15;
        run_case("directed healthy eyes");

        eye_lo[0]=1; eye_hi[0]=6;
        eye_lo[1]=7; eye_hi[1]=9;
        eye_lo[2]=4; eye_hi[2]=11;
        eye_lo[3]=12; eye_hi[3]=13;
        run_case("directed marginal lanes");

        repeat (8) begin
            for (lane = 0; lane < LANES; lane = lane + 1) begin
                eye_lo[lane] = $urandom(seed) % 10;
                eye_hi[lane] = eye_lo[lane] + 2 + ($urandom(seed) % (TAPS-eye_lo[lane]-1));
                if (eye_hi[lane] >= TAPS) eye_hi[lane] = TAPS-1;
            end
            run_case("randomized eye map");
        end

        $display("Completed %0d training runs and %0d checks", runs, checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "Global testbench timeout");
    end
endmodule
