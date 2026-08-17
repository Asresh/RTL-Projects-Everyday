// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_lms_adaptive_equalizer;
    localparam integer DATA_W = 12;
    localparam integer COEFF_W = 16;
    localparam integer TAPS = 4;
    localparam integer SAMPLE_FRAC = 10;
    localparam integer COEFF_FRAC = 12;
    localparam integer UPDATE_BASE_SHIFT = (2*SAMPLE_FRAC)-COEFF_FRAC;
    localparam integer DATA_MAX = (1 << (DATA_W-1)) - 1;
    localparam integer DATA_MIN = -(1 << (DATA_W-1));
    localparam integer COEFF_MAX = (1 << (COEFF_W-1)) - 1;
    localparam integer COEFF_MIN = -(1 << (COEFF_W-1));

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear_i;
    logic sample_valid_i;
    wire sample_ready_o;
    logic adapt_enable_i;
    logic signed [DATA_W-1:0] sample_i;
    logic signed [DATA_W-1:0] desired_i;
    logic [3:0] step_shift_i;
    wire output_valid_o;
    wire signed [DATA_W-1:0] sample_o;
    wire signed [DATA_W-1:0] error_o;
    wire converged_o;
    wire busy_o;
    wire [31:0] update_count_o;
    wire [TAPS*COEFF_W-1:0] coeffs_o;

    integer model_history [0:TAPS-1];
    integer model_coeff [0:TAPS-1];
    integer target_coeff [0:TAPS-1];
    integer checks = 0;
    integer errors = 0;
    integer accepted = 0;
    integer updates = 0;
    integer seed = 32'h53a11d;
    integer i;
    integer random_input;
    integer random_desired;

    always #5 clk = ~clk;

    lms_adaptive_equalizer #(
        .DATA_W(DATA_W), .COEFF_W(COEFF_W), .TAPS(TAPS),
        .SAMPLE_FRAC(SAMPLE_FRAC), .COEFF_FRAC(COEFF_FRAC),
        .STEP_SHIFT_W(4), .ERROR_THRESHOLD(24)
    ) dut (.*);

    function automatic integer sat_data(input longint signed value);
        begin
            if (value > DATA_MAX) sat_data = DATA_MAX;
            else if (value < DATA_MIN) sat_data = DATA_MIN;
            else sat_data = value;
        end
    endfunction

    function automatic integer sat_coeff(input longint signed value);
        begin
            if (value > COEFF_MAX) sat_coeff = COEFF_MAX;
            else if (value < COEFF_MIN) sat_coeff = COEFF_MIN;
            else sat_coeff = value;
        end
    endfunction

    task automatic fail(input string message);
        begin
            errors = errors + 1;
            $display("ERROR @ %0t: %s", $time, message);
        end
    endtask

    task automatic check_coefficients;
        integer k;
        integer observed;
        begin
            for (k = 0; k < TAPS; k = k + 1) begin
                observed = $signed(coeffs_o[k*COEFF_W +: COEFF_W]);
                checks = checks + 1;
                if (observed !== model_coeff[k]) begin
                    $display("tap %0d observed=%0d expected=%0d", k, observed, model_coeff[k]);
                    fail("coefficient mismatch");
                end
            end
        end
    endtask

    task automatic transact(
        input integer x_value,
        input integer d_value,
        input logic adapt_value,
        input integer shift_value
    );
        integer k;
        integer expected_y;
        integer expected_error;
        integer expected_converged;
        longint signed sum;
        longint signed delta;
        begin
            while (!sample_ready_o) @(negedge clk);
            sample_valid_i = 1'b1;
            sample_i = x_value;
            desired_i = d_value;
            adapt_enable_i = adapt_value;
            step_shift_i = shift_value;
            @(posedge clk);
            #1 sample_valid_i = 1'b0;
            accepted = accepted + 1;

            for (k = TAPS-1; k > 0; k = k - 1)
                model_history[k] = model_history[k-1];
            model_history[0] = x_value;
            sum = 0;
            for (k = 0; k < TAPS; k = k + 1)
                sum = sum + (model_history[k] * model_coeff[k]);
            expected_y = sat_data(sum >>> COEFF_FRAC);
            expected_error = sat_data(d_value - expected_y);
            expected_converged = ((expected_error < 0 ? -expected_error : expected_error) <= 24);

            wait (output_valid_o === 1'b1);
            checks = checks + 4;
            if ($signed(sample_o) !== expected_y) fail("FIR output mismatch");
            if ($signed(error_o) !== expected_error) fail("training error mismatch");
            if (converged_o !== expected_converged) fail("convergence flag mismatch");
            if (!busy_o && adapt_value) fail("busy dropped before coefficient update");

            if (adapt_value) begin
                for (k = 0; k < TAPS; k = k + 1) begin
                    delta = (expected_error * model_history[k]) >>>
                            (UPDATE_BASE_SHIFT + shift_value);
                    model_coeff[k] = sat_coeff(model_coeff[k] + delta);
                end
                updates = updates + 1;
            end
            while (busy_o) @(negedge clk);
            check_coefficients();
            checks = checks + 1;
            if (update_count_o !== updates) fail("update counter mismatch");
        end
    endtask

    function automatic integer desired_filter(input integer x_now);
        longint signed target_sum;
        begin
            target_sum = x_now * target_coeff[0] +
                         model_history[0] * target_coeff[1] +
                         model_history[1] * target_coeff[2] +
                         model_history[2] * target_coeff[3];
            desired_filter = sat_data(target_sum >>> COEFF_FRAC);
        end
    endfunction

    initial begin
        $dumpfile("lms_adaptive_equalizer.vcd");
        $dumpvars(0, tb_lms_adaptive_equalizer);
        clear_i = 0;
        sample_valid_i = 0;
        adapt_enable_i = 0;
        sample_i = 0;
        desired_i = 0;
        step_shift_i = 0;
        target_coeff[0] = 3072;
        target_coeff[1] = -1024;
        target_coeff[2] = 512;
        target_coeff[3] = 256;
        for (i = 0; i < TAPS; i = i + 1) begin
            model_history[i] = 0;
            model_coeff[i] = 0;
        end

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);
        checks = checks + 3;
        if (!sample_ready_o || busy_o || output_valid_o) fail("invalid post-reset handshake state");
        check_coefficients();

        // Directed impulse and sign cases exercise positive/negative updates.
        transact(1024, 768, 1'b1, 2);
        transact(0, -256, 1'b1, 2);
        transact(-1024, -640, 1'b1, 3);
        transact(512, 384, 1'b0, 1);

        // Synchronous clear must erase learned state, history, and counters.
        @(negedge clk);
        clear_i = 1'b1;
        @(posedge clk);
        #1 clear_i = 1'b0;
        for (i = 0; i < TAPS; i = i + 1) begin
            model_history[i] = 0;
            model_coeff[i] = 0;
        end
        updates = 0;
        @(negedge clk);
        checks = checks + 4;
        if (!sample_ready_o || busy_o || output_valid_o || update_count_o != 0)
            fail("clear did not restore the idle state");
        check_coefficients();

        // Train toward a known four-tap response with persistent excitation.
        for (i = 0; i < 120; i = i + 1) begin
            random_input = ($urandom(seed) % 1537) - 768;
            random_desired = desired_filter(random_input);
            transact(random_input, random_desired, 1'b1, 4);
        end

        // Freeze adaptation and verify randomized inference cannot move taps.
        for (i = 0; i < 24; i = i + 1) begin
            random_input = ($urandom(seed) % 2049) - 1024;
            random_desired = ($urandom(seed) % 2049) - 1024;
            transact(random_input, random_desired, 1'b0, $urandom(seed) % 6);
        end

        checks = checks + 1;
        if (accepted != 148) fail("unexpected accepted-sample count");
        if (errors == 0) begin
            $display("Accepted %0d samples, applied %0d LMS updates, completed %0d checks",
                     accepted, updates, checks);
            $display("Final taps: %0d %0d %0d %0d", model_coeff[0], model_coeff[1],
                     model_coeff[2], model_coeff[3]);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #1000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1);
    end
endmodule
