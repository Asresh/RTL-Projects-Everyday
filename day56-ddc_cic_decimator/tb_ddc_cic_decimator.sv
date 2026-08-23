// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_ddc_cic_decimator;
    localparam integer DATA_W = 12;
    localparam integer COEFF_W = 12;
    localparam integer PHASE_W = 8;
    localparam integer CIC_STAGES = 3;
    localparam integer DECIM_RATE = 8;
    localparam integer OUT_W = 10;
    localparam integer COEFF_FRAC = 10;
    localparam integer RATE_SHIFT = 3;
    localparam integer MIX_W = DATA_W + COEFF_W;
    localparam integer ACC_W = MIX_W + CIC_STAGES*RATE_SHIFT + 2;
    localparam integer SCALE_SHIFT = COEFF_FRAC + CIC_STAGES*RATE_SHIFT;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear_i;
    logic cfg_valid_i;
    logic [PHASE_W-1:0] phase_inc_i;
    logic sample_valid_i;
    logic signed [DATA_W-1:0] sample_i;
    wire output_valid_o;
    wire signed [OUT_W-1:0] i_data_o;
    wire signed [OUT_W-1:0] q_data_o;
    wire overflow_o;
    wire [PHASE_W-1:0] phase_o;
    wire [31:0] sample_count_o;
    wire [31:0] output_count_o;

    logic [PHASE_W-1:0] ref_phase_inc;
    logic [PHASE_W-1:0] ref_phase;
    integer ref_decim;
    logic signed [ACC_W-1:0] ref_integrator_i [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] ref_integrator_q [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] ref_comb_delay_i [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] ref_comb_delay_q [0:CIC_STAGES-1];
    logic ref_output_valid;
    logic signed [OUT_W-1:0] ref_i_data;
    logic signed [OUT_W-1:0] ref_q_data;
    logic ref_overflow;
    integer ref_samples;
    integer ref_outputs;
    integer overflow_events;
    integer checks = 0;
    integer errors = 0;
    integer cycles = 0;
    integer index;

    ddc_cic_decimator #(
        .DATA_W(DATA_W), .COEFF_W(COEFF_W), .PHASE_W(PHASE_W),
        .CIC_STAGES(CIC_STAGES), .DECIM_RATE(DECIM_RATE), .OUT_W(OUT_W)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic logic signed [11:0] ref_sine(input logic [3:0] address);
        begin
            case (address)
                4'h0: ref_sine =  12'sd0;
                4'h1: ref_sine =  12'sd392;
                4'h2: ref_sine =  12'sd724;
                4'h3: ref_sine =  12'sd946;
                4'h4: ref_sine =  12'sd1024;
                4'h5: ref_sine =  12'sd946;
                4'h6: ref_sine =  12'sd724;
                4'h7: ref_sine =  12'sd392;
                4'h8: ref_sine =  12'sd0;
                4'h9: ref_sine = -12'sd392;
                4'ha: ref_sine = -12'sd724;
                4'hb: ref_sine = -12'sd946;
                4'hc: ref_sine = -12'sd1024;
                4'hd: ref_sine = -12'sd946;
                4'he: ref_sine = -12'sd724;
                default: ref_sine = -12'sd392;
            endcase
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] ref_saturate(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] maximum;
        logic signed [ACC_W-1:0] minimum;
        begin
            maximum = (1 <<< (OUT_W-1)) - 1;
            minimum = -(1 <<< (OUT_W-1));
            if (value > maximum)
                ref_saturate = {1'b0, {(OUT_W-1){1'b1}}};
            else if (value < minimum)
                ref_saturate = {1'b1, {(OUT_W-1){1'b0}}};
            else
                ref_saturate = value[OUT_W-1:0];
        end
    endfunction

    function automatic logic ref_is_overflow(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] maximum;
        logic signed [ACC_W-1:0] minimum;
        begin
            maximum = (1 <<< (OUT_W-1)) - 1;
            minimum = -(1 <<< (OUT_W-1));
            ref_is_overflow = (value > maximum) || (value < minimum);
        end
    endfunction

    task automatic reset_model;
        integer k;
        begin
            ref_phase_inc = '0;
            ref_phase = '0;
            ref_decim = 0;
            ref_output_valid = 1'b0;
            ref_i_data = '0;
            ref_q_data = '0;
            ref_overflow = 1'b0;
            ref_samples = 0;
            ref_outputs = 0;
            overflow_events = 0;
            for (k = 0; k < CIC_STAGES; k = k + 1) begin
                ref_integrator_i[k] = '0;
                ref_integrator_q[k] = '0;
                ref_comb_delay_i[k] = '0;
                ref_comb_delay_q[k] = '0;
            end
        end
    endtask

    task automatic clear_model;
        integer k;
        begin
            ref_phase = '0;
            ref_decim = 0;
            ref_output_valid = 1'b0;
            ref_i_data = '0;
            ref_q_data = '0;
            ref_overflow = 1'b0;
            ref_samples = 0;
            ref_outputs = 0;
            for (k = 0; k < CIC_STAGES; k = k + 1) begin
                ref_integrator_i[k] = '0;
                ref_integrator_q[k] = '0;
                ref_comb_delay_i[k] = '0;
                ref_comb_delay_q[k] = '0;
            end
        end
    endtask

    task automatic model_step;
        logic [3:0] address;
        logic signed [11:0] cosine;
        logic signed [11:0] sine;
        logic signed [MIX_W-1:0] mixed_i;
        logic signed [MIX_W-1:0] mixed_q;
        logic signed [ACC_W-1:0] new_i [0:CIC_STAGES-1];
        logic signed [ACC_W-1:0] new_q [0:CIC_STAGES-1];
        logic signed [ACC_W-1:0] comb_i;
        logic signed [ACC_W-1:0] comb_q;
        logic signed [ACC_W-1:0] difference_i;
        logic signed [ACC_W-1:0] difference_q;
        logic signed [ACC_W-1:0] scaled_i;
        logic signed [ACC_W-1:0] scaled_q;
        integer k;
        begin
            ref_output_valid = 1'b0;
            if (clear_i) begin
                clear_model();
                if (cfg_valid_i)
                    ref_phase_inc = phase_inc_i;
            end else begin
                if (cfg_valid_i)
                    ref_phase_inc = phase_inc_i;
                if (sample_valid_i) begin
                    address = ref_phase[PHASE_W-1 -: 4];
                    cosine = ref_sine(address + 4'd4);
                    sine = ref_sine(address);
                    mixed_i = $signed(sample_i) * $signed(cosine);
                    mixed_q = -($signed(sample_i) * $signed(sine));
                    new_i[0] = ref_integrator_i[0] + mixed_i;
                    new_q[0] = ref_integrator_q[0] + mixed_q;
                    for (k = 1; k < CIC_STAGES; k = k + 1) begin
                        new_i[k] = ref_integrator_i[k] + new_i[k-1];
                        new_q[k] = ref_integrator_q[k] + new_q[k-1];
                    end
                    for (k = 0; k < CIC_STAGES; k = k + 1) begin
                        ref_integrator_i[k] = new_i[k];
                        ref_integrator_q[k] = new_q[k];
                    end
                    ref_phase = ref_phase + ref_phase_inc;
                    ref_samples = ref_samples + 1;
                    if (ref_decim == DECIM_RATE-1) begin
                        ref_decim = 0;
                        comb_i = new_i[CIC_STAGES-1];
                        comb_q = new_q[CIC_STAGES-1];
                        for (k = 0; k < CIC_STAGES; k = k + 1) begin
                            difference_i = comb_i - ref_comb_delay_i[k];
                            difference_q = comb_q - ref_comb_delay_q[k];
                            ref_comb_delay_i[k] = comb_i;
                            ref_comb_delay_q[k] = comb_q;
                            comb_i = difference_i;
                            comb_q = difference_q;
                        end
                        scaled_i = comb_i >>> SCALE_SHIFT;
                        scaled_q = comb_q >>> SCALE_SHIFT;
                        ref_i_data = ref_saturate(scaled_i);
                        ref_q_data = ref_saturate(scaled_q);
                        ref_overflow = ref_overflow || ref_is_overflow(scaled_i) || ref_is_overflow(scaled_q);
                        if (ref_is_overflow(scaled_i) || ref_is_overflow(scaled_q))
                            overflow_events = overflow_events + 1;
                        ref_output_valid = 1'b1;
                        ref_outputs = ref_outputs + 1;
                    end else begin
                        ref_decim = ref_decim + 1;
                    end
                end
            end
        end
    endtask

    task automatic fail(input string message);
        begin
            $display("ERROR cycle %0d: %s", cycles, message);
            errors = errors + 1;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n)
            reset_model();
        else begin
            cycles = cycles + 1;
            model_step();
        end
    end

    always @(negedge clk) begin
        if (!rst_n) begin
            checks = checks + 1;
            if (output_valid_o !== 1'b0 || sample_count_o !== 0 || output_count_o !== 0)
                fail("reset outputs were not cleared");
        end else begin
            checks = checks + 6;
            if (output_valid_o !== ref_output_valid)
                fail("output-valid mismatch");
            if (phase_o !== ref_phase)
                fail($sformatf("phase expected %0d got %0d", ref_phase, phase_o));
            if (sample_count_o !== ref_samples)
                fail("sample counter mismatch");
            if (output_count_o !== ref_outputs)
                fail("output counter mismatch");
            if (overflow_o !== ref_overflow)
                fail("sticky overflow mismatch");
            if (ref_output_valid) begin
                checks = checks + 2;
                if (i_data_o !== ref_i_data)
                    fail($sformatf("I output expected %0d got %0d", ref_i_data, i_data_o));
                if (q_data_o !== ref_q_data)
                    fail($sformatf("Q output expected %0d got %0d", ref_q_data, q_data_o));
            end
            if (errors > 20)
                $fatal(1, "too many errors");
        end
    end

    task automatic drive_sample(input logic signed [DATA_W-1:0] value, input logic valid);
        begin
            @(negedge clk);
            #1;
            sample_i = value;
            sample_valid_i = valid;
            cfg_valid_i = 1'b0;
            clear_i = 1'b0;
        end
    endtask

    task automatic configure(input logic [PHASE_W-1:0] increment);
        begin
            @(negedge clk);
            #1;
            cfg_valid_i = 1'b1;
            phase_inc_i = increment;
            sample_valid_i = 1'b0;
            clear_i = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("ddc_cic_decimator.vcd");
        $dumpvars(0, tb_ddc_cic_decimator);
        clear_i = 1'b0;
        cfg_valid_i = 1'b0;
        phase_inc_i = '0;
        sample_valid_i = 1'b0;
        sample_i = '0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        configure(8'd16);
        // Directed coherent tone: carrier samples follow the same 16-step LUT.
        for (index = 0; index < 64; index = index + 1)
            drive_sample(ref_sine(index[3:0]) + (index[0] ? 12'sd40 : -12'sd40), 1'b1);

        // Valid gaps prove that NCO and decimator advance only on accepted samples.
        for (index = 0; index < 32; index = index + 1)
            drive_sample($signed($urandom_range(0, 4095) - 2048), (index % 3) != 0);

        configure(8'd29);
        // Random input after a runtime frequency retune.
        for (index = 0; index < 320; index = index + 1)
            drive_sample($signed($urandom_range(0, 4095) - 2048), $urandom_range(0, 99) < 84);

        @(negedge clk);
        #1;
        clear_i = 1'b1;
        sample_valid_i = 1'b0;
        cfg_valid_i = 1'b1;
        phase_inc_i = 8'd7;
        @(negedge clk);
        #1;
        clear_i = 1'b0;
        cfg_valid_i = 1'b0;

        for (index = 0; index < 96; index = index + 1)
            drive_sample($signed($urandom_range(0, 4095) - 2048), 1'b1);
        repeat (3) drive_sample('0, 1'b0);

        if (ref_outputs < 10)
            fail("insufficient decimated outputs");
        if (overflow_events == 0)
            fail("directed/random stimulus did not exercise output saturation");
        if (errors == 0) begin
            $display("Validated %0d samples, %0d decimated outputs, and %0d checks",
                     ref_samples, ref_outputs, checks);
            $display("RESULT: *** PASS ***");
            $finish;
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #200000;
        $fatal(1, "global timeout");
    end
endmodule
