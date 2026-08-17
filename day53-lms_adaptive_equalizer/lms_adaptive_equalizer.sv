// Author: Asresh Kuricheti
`timescale 1ns/1ps

module lms_adaptive_equalizer #(
    parameter integer DATA_W = 12,
    parameter integer COEFF_W = 16,
    parameter integer TAPS = 4,
    parameter integer SAMPLE_FRAC = 10,
    parameter integer COEFF_FRAC = 12,
    parameter integer STEP_SHIFT_W = 4,
    parameter integer ERROR_THRESHOLD = 24,
    parameter integer TAP_W = (TAPS <= 2) ? 1 : $clog2(TAPS),
    parameter integer ACC_W = DATA_W + COEFF_W + $clog2(TAPS) + 2,
    parameter integer UPDATE_W = (2 * DATA_W) + 1
) (
    input  wire                              clk,
    input  wire                              rst_n,
    input  wire                              clear_i,
    input  wire                              sample_valid_i,
    output logic                             sample_ready_o,
    input  wire                              adapt_enable_i,
    input  wire signed [DATA_W-1:0]          sample_i,
    input  wire signed [DATA_W-1:0]          desired_i,
    input  wire [STEP_SHIFT_W-1:0]           step_shift_i,
    output logic                             output_valid_o,
    output logic signed [DATA_W-1:0]         sample_o,
    output logic signed [DATA_W-1:0]         error_o,
    output logic                             converged_o,
    output logic                             busy_o,
    output logic [31:0]                      update_count_o,
    output wire [TAPS*COEFF_W-1:0]           coeffs_o
);

    localparam integer UPDATE_BASE_SHIFT = (2 * SAMPLE_FRAC) - COEFF_FRAC;
    localparam logic [1:0] ST_IDLE = 2'd0;
    localparam logic [1:0] ST_MAC = 2'd1;
    localparam logic [1:0] ST_UPDATE = 2'd2;

    logic [1:0] state_q;
    logic [TAP_W-1:0] tap_index_q;
    logic signed [DATA_W-1:0] history_q [0:TAPS-1];
    logic signed [COEFF_W-1:0] coeff_q [0:TAPS-1];
    logic signed [DATA_W-1:0] desired_q;
    logic signed [DATA_W-1:0] update_error_q;
    logic [STEP_SHIFT_W-1:0] step_shift_q;
    logic adapt_q;
    logic signed [ACC_W-1:0] accumulator_q;

    logic signed [DATA_W+COEFF_W-1:0] mac_product_w;
    logic signed [ACC_W-1:0] mac_product_ext_w;
    logic signed [ACC_W-1:0] mac_sum_w;
    logic signed [ACC_W-1:0] scaled_output_w;
    logic signed [DATA_W-1:0] saturated_output_w;
    logic signed [DATA_W:0] error_full_w;
    logic signed [DATA_W-1:0] saturated_error_w;

    logic signed [(2*DATA_W)-1:0] update_product_w;
    logic signed [UPDATE_W-1:0] update_product_ext_w;
    logic signed [UPDATE_W-1:0] update_delta_w;
    logic signed [UPDATE_W-1:0] coeff_extended_w;
    logic signed [UPDATE_W-1:0] coeff_candidate_w;
    logic signed [COEFF_W-1:0] saturated_coeff_w;

    integer i;
    genvar g;

    function automatic signed [DATA_W-1:0] saturate_data(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] max_value;
        logic signed [ACC_W-1:0] min_value;
        begin
            max_value = (64'sd1 <<< (DATA_W-1)) - 1;
            min_value = -(64'sd1 <<< (DATA_W-1));
            if (value > max_value)
                saturate_data = {1'b0, {(DATA_W-1){1'b1}}};
            else if (value < min_value)
                saturate_data = {1'b1, {(DATA_W-1){1'b0}}};
            else
                saturate_data = value[DATA_W-1:0];
        end
    endfunction

    function automatic signed [DATA_W-1:0] saturate_error(
        input logic signed [DATA_W:0] value
    );
        logic signed [DATA_W:0] max_value;
        logic signed [DATA_W:0] min_value;
        begin
            max_value = (64'sd1 <<< (DATA_W-1)) - 1;
            min_value = -(64'sd1 <<< (DATA_W-1));
            if (value > max_value)
                saturate_error = {1'b0, {(DATA_W-1){1'b1}}};
            else if (value < min_value)
                saturate_error = {1'b1, {(DATA_W-1){1'b0}}};
            else
                saturate_error = value[DATA_W-1:0];
        end
    endfunction

    function automatic signed [COEFF_W-1:0] saturate_coeff(
        input logic signed [UPDATE_W-1:0] value
    );
        logic signed [UPDATE_W-1:0] max_value;
        logic signed [UPDATE_W-1:0] min_value;
        begin
            max_value = (64'sd1 <<< (COEFF_W-1)) - 1;
            min_value = -(64'sd1 <<< (COEFF_W-1));
            if (value > max_value)
                saturate_coeff = {1'b0, {(COEFF_W-1){1'b1}}};
            else if (value < min_value)
                saturate_coeff = {1'b1, {(COEFF_W-1){1'b0}}};
            else
                saturate_coeff = value[COEFF_W-1:0];
        end
    endfunction

    function automatic [DATA_W-1:0] magnitude(
        input logic signed [DATA_W-1:0] value
    );
        begin
            if (value[DATA_W-1])
                magnitude = (~value) + 1'b1;
            else
                magnitude = value;
        end
    endfunction

    assign mac_product_w = $signed(history_q[tap_index_q]) *
                           $signed(coeff_q[tap_index_q]);
    assign mac_product_ext_w = {{(ACC_W-(DATA_W+COEFF_W)){mac_product_w[DATA_W+COEFF_W-1]}},
                                mac_product_w};
    assign mac_sum_w = accumulator_q + mac_product_ext_w;
    assign scaled_output_w = mac_sum_w >>> COEFF_FRAC;
    assign saturated_output_w = saturate_data(scaled_output_w);
    assign error_full_w = $signed(desired_q) - $signed(saturated_output_w);
    assign saturated_error_w = saturate_error(error_full_w);

    assign update_product_w = $signed(update_error_q) *
                              $signed(history_q[tap_index_q]);
    assign update_product_ext_w = {{(UPDATE_W-(2*DATA_W)){update_product_w[(2*DATA_W)-1]}},
                                   update_product_w};
    assign update_delta_w = update_product_ext_w >>>
                            (UPDATE_BASE_SHIFT + step_shift_q);
    assign coeff_extended_w = {{(UPDATE_W-COEFF_W){coeff_q[tap_index_q][COEFF_W-1]}},
                               coeff_q[tap_index_q]};
    assign coeff_candidate_w = coeff_extended_w + update_delta_w;
    assign saturated_coeff_w = saturate_coeff(coeff_candidate_w);

    assign sample_ready_o = (state_q == ST_IDLE) && !clear_i;
    assign busy_o = (state_q != ST_IDLE);

    generate
        for (g = 0; g < TAPS; g = g + 1) begin : gen_coeff_view
            assign coeffs_o[g*COEFF_W +: COEFF_W] = coeff_q[g];
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            tap_index_q <= '0;
            desired_q <= '0;
            update_error_q <= '0;
            step_shift_q <= '0;
            adapt_q <= 1'b0;
            accumulator_q <= '0;
            output_valid_o <= 1'b0;
            sample_o <= '0;
            error_o <= '0;
            converged_o <= 1'b0;
            update_count_o <= '0;
            for (i = 0; i < TAPS; i = i + 1) begin
                history_q[i] <= '0;
                coeff_q[i] <= '0;
            end
        end else if (clear_i) begin
            state_q <= ST_IDLE;
            tap_index_q <= '0;
            desired_q <= '0;
            update_error_q <= '0;
            step_shift_q <= '0;
            adapt_q <= 1'b0;
            accumulator_q <= '0;
            output_valid_o <= 1'b0;
            sample_o <= '0;
            error_o <= '0;
            converged_o <= 1'b0;
            update_count_o <= '0;
            for (i = 0; i < TAPS; i = i + 1) begin
                history_q[i] <= '0;
                coeff_q[i] <= '0;
            end
        end else begin
            output_valid_o <= 1'b0;
            case (state_q)
                ST_IDLE: begin
                    if (sample_valid_i) begin
                        for (i = TAPS-1; i > 0; i = i - 1)
                            history_q[i] <= history_q[i-1];
                        history_q[0] <= sample_i;
                        desired_q <= desired_i;
                        step_shift_q <= step_shift_i;
                        adapt_q <= adapt_enable_i;
                        accumulator_q <= '0;
                        tap_index_q <= '0;
                        state_q <= ST_MAC;
                    end
                end

                ST_MAC: begin
                    if (tap_index_q == TAPS-1) begin
                        sample_o <= saturated_output_w;
                        error_o <= saturated_error_w;
                        converged_o <= (magnitude(saturated_error_w) <= ERROR_THRESHOLD);
                        output_valid_o <= 1'b1;
                        accumulator_q <= '0;
                        tap_index_q <= '0;
                        if (adapt_q) begin
                            update_error_q <= saturated_error_w;
                            state_q <= ST_UPDATE;
                        end else begin
                            state_q <= ST_IDLE;
                        end
                    end else begin
                        accumulator_q <= mac_sum_w;
                        tap_index_q <= tap_index_q + 1'b1;
                    end
                end

                ST_UPDATE: begin
                    coeff_q[tap_index_q] <= saturated_coeff_w;
                    if (tap_index_q == TAPS-1) begin
                        tap_index_q <= '0;
                        update_count_o <= update_count_o + 1'b1;
                        state_q <= ST_IDLE;
                    end else begin
                        tap_index_q <= tap_index_q + 1'b1;
                    end
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (DATA_W < 4 || COEFF_W < 4)
            $fatal(1, "DATA_W and COEFF_W must both be at least four");
        if (TAPS < 2)
            $fatal(1, "TAPS must be at least two");
        if (COEFF_FRAC >= COEFF_W || SAMPLE_FRAC >= DATA_W)
            $fatal(1, "fractional widths must be smaller than their words");
        if (UPDATE_BASE_SHIFT < 0)
            $fatal(1, "unsupported fractional-width combination");
        if (ACC_W < DATA_W + COEFF_W + $clog2(TAPS))
            $fatal(1, "ACC_W is too small for the FIR sum");
    end
`endif

endmodule
