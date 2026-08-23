// Author: Asresh Kuricheti
`timescale 1ns/1ps

module ddc_cic_decimator #(
    parameter integer DATA_W       = 12,
    parameter integer COEFF_W      = 12,
    parameter integer PHASE_W      = 8,
    parameter integer CIC_STAGES   = 3,
    parameter integer DECIM_RATE   = 8,
    parameter integer OUT_W        = 16,
    parameter integer COEFF_FRAC   = COEFF_W - 2,
    parameter integer RATE_SHIFT   = $clog2(DECIM_RATE),
    parameter integer MIX_W        = DATA_W + COEFF_W,
    parameter integer ACC_W        = MIX_W + CIC_STAGES*RATE_SHIFT + 2,
    parameter integer DECIM_W      = (DECIM_RATE <= 2) ? 1 : $clog2(DECIM_RATE)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         clear_i,
    input  logic                         cfg_valid_i,
    input  logic [PHASE_W-1:0]           phase_inc_i,
    input  logic                         sample_valid_i,
    input  logic signed [DATA_W-1:0]     sample_i,
    output logic                         output_valid_o,
    output logic signed [OUT_W-1:0]      i_data_o,
    output logic signed [OUT_W-1:0]      q_data_o,
    output logic                         overflow_o,
    output logic [PHASE_W-1:0]           phase_o,
    output logic [31:0]                  sample_count_o,
    output logic [31:0]                  output_count_o
);
    localparam integer LUT_ADDR_W = 4;
    localparam integer SCALE_SHIFT = COEFF_FRAC + CIC_STAGES*RATE_SHIFT;

    logic [PHASE_W-1:0] phase_inc_q;
    logic [DECIM_W-1:0] decim_count_q;
    logic [LUT_ADDR_W-1:0] lut_addr;
    logic signed [COEFF_W-1:0] cos_value;
    logic signed [COEFF_W-1:0] sin_value;
    logic signed [MIX_W-1:0] mixer_i;
    logic signed [MIX_W-1:0] mixer_q;
    logic signed [ACC_W-1:0] integrator_i [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] integrator_q [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] comb_delay_i [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] comb_delay_q [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] integ_i_next [0:CIC_STAGES-1];
    logic signed [ACC_W-1:0] integ_q_next [0:CIC_STAGES-1];
    integer stage;

    function automatic logic signed [COEFF_W-1:0] sine_lut(
        input logic [LUT_ADDR_W-1:0] address
    );
        logic signed [11:0] value;
        begin
            case (address)
                4'h0: value =  12'sd0;
                4'h1: value =  12'sd392;
                4'h2: value =  12'sd724;
                4'h3: value =  12'sd946;
                4'h4: value =  12'sd1024;
                4'h5: value =  12'sd946;
                4'h6: value =  12'sd724;
                4'h7: value =  12'sd392;
                4'h8: value =  12'sd0;
                4'h9: value = -12'sd392;
                4'ha: value = -12'sd724;
                4'hb: value = -12'sd946;
                4'hc: value = -12'sd1024;
                4'hd: value = -12'sd946;
                4'he: value = -12'sd724;
                default: value = -12'sd392;
            endcase
            sine_lut = value[COEFF_W-1:0];
        end
    endfunction

    function automatic logic signed [OUT_W-1:0] saturate_output(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] maximum;
        logic signed [ACC_W-1:0] minimum;
        begin
            maximum = ({{(ACC_W-OUT_W){1'b0}}, 1'b0, {(OUT_W-1){1'b1}}});
            minimum = ({{(ACC_W-OUT_W){1'b1}}, 1'b1, {(OUT_W-1){1'b0}}});
            if (value > maximum)
                saturate_output = {1'b0, {(OUT_W-1){1'b1}}};
            else if (value < minimum)
                saturate_output = {1'b1, {(OUT_W-1){1'b0}}};
            else
                saturate_output = value[OUT_W-1:0];
        end
    endfunction

    function automatic logic output_overflow(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] maximum;
        logic signed [ACC_W-1:0] minimum;
        begin
            maximum = ({{(ACC_W-OUT_W){1'b0}}, 1'b0, {(OUT_W-1){1'b1}}});
            minimum = ({{(ACC_W-OUT_W){1'b1}}, 1'b1, {(OUT_W-1){1'b0}}});
            output_overflow = (value > maximum) || (value < minimum);
        end
    endfunction

    assign lut_addr = phase_o[PHASE_W-1 -: LUT_ADDR_W];
    assign cos_value = sine_lut(lut_addr + 4'd4);
    assign sin_value = sine_lut(lut_addr);
    assign mixer_i = sample_i * cos_value;
    assign mixer_q = -(sample_i * sin_value);

    always @* begin
        integ_i_next[0] = integrator_i[0] + {{(ACC_W-MIX_W){mixer_i[MIX_W-1]}}, mixer_i};
        integ_q_next[0] = integrator_q[0] + {{(ACC_W-MIX_W){mixer_q[MIX_W-1]}}, mixer_q};
        for (stage = 1; stage < CIC_STAGES; stage = stage + 1) begin
            integ_i_next[stage] = integrator_i[stage] + integ_i_next[stage-1];
            integ_q_next[stage] = integrator_q[stage] + integ_q_next[stage-1];
        end
    end

    initial begin
        if (DATA_W < 2 || COEFF_W != 12 || PHASE_W < LUT_ADDR_W ||
            CIC_STAGES < 1 || DECIM_RATE < 2 || OUT_W < 2 ||
            (DECIM_RATE != (1 << RATE_SHIFT)) || SCALE_SHIFT >= ACC_W)
            $error("Invalid ddc_cic_decimator parameter combination");
    end

    always_ff @(posedge clk or negedge rst_n) begin : ddc_sequential
        logic signed [ACC_W-1:0] comb_i;
        logic signed [ACC_W-1:0] comb_q;
        logic signed [ACC_W-1:0] next_comb_i;
        logic signed [ACC_W-1:0] next_comb_q;
        logic signed [ACC_W-1:0] scaled_i;
        logic signed [ACC_W-1:0] scaled_q;
        integer index;
        if (!rst_n) begin
            phase_inc_q <= '0;
            phase_o <= '0;
            decim_count_q <= '0;
            output_valid_o <= 1'b0;
            i_data_o <= '0;
            q_data_o <= '0;
            overflow_o <= 1'b0;
            sample_count_o <= '0;
            output_count_o <= '0;
            for (index = 0; index < CIC_STAGES; index = index + 1) begin
                integrator_i[index] <= '0;
                integrator_q[index] <= '0;
                comb_delay_i[index] <= '0;
                comb_delay_q[index] <= '0;
            end
        end else if (clear_i) begin
            phase_o <= '0;
            decim_count_q <= '0;
            output_valid_o <= 1'b0;
            i_data_o <= '0;
            q_data_o <= '0;
            overflow_o <= 1'b0;
            sample_count_o <= '0;
            output_count_o <= '0;
            for (index = 0; index < CIC_STAGES; index = index + 1) begin
                integrator_i[index] <= '0;
                integrator_q[index] <= '0;
                comb_delay_i[index] <= '0;
                comb_delay_q[index] <= '0;
            end
            if (cfg_valid_i)
                phase_inc_q <= phase_inc_i;
        end else begin
            output_valid_o <= 1'b0;
            if (cfg_valid_i)
                phase_inc_q <= phase_inc_i;
            if (sample_valid_i) begin
                phase_o <= phase_o + phase_inc_q;
                sample_count_o <= sample_count_o + 1'b1;
                for (index = 0; index < CIC_STAGES; index = index + 1) begin
                    integrator_i[index] <= integ_i_next[index];
                    integrator_q[index] <= integ_q_next[index];
                end
                if (decim_count_q == DECIM_RATE-1) begin
                    decim_count_q <= '0;
                    comb_i = integ_i_next[CIC_STAGES-1];
                    comb_q = integ_q_next[CIC_STAGES-1];
                    for (index = 0; index < CIC_STAGES; index = index + 1) begin
                        next_comb_i = comb_i - comb_delay_i[index];
                        next_comb_q = comb_q - comb_delay_q[index];
                        comb_delay_i[index] <= comb_i;
                        comb_delay_q[index] <= comb_q;
                        comb_i = next_comb_i;
                        comb_q = next_comb_q;
                    end
                    scaled_i = comb_i >>> SCALE_SHIFT;
                    scaled_q = comb_q >>> SCALE_SHIFT;
                    i_data_o <= saturate_output(scaled_i);
                    q_data_o <= saturate_output(scaled_q);
                    overflow_o <= overflow_o || output_overflow(scaled_i) || output_overflow(scaled_q);
                    output_valid_o <= 1'b1;
                    output_count_o <= output_count_o + 1'b1;
                end else begin
                    decim_count_q <= decim_count_q + 1'b1;
                end
            end
        end
    end
endmodule
