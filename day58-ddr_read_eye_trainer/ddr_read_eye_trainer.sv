// Author: Asresh Kuricheti
// Parameterized per-lane DDR read-eye training controller.
`timescale 1ns/1ps

module ddr_read_eye_trainer #(
    parameter integer LANES           = 4,
    parameter integer TAP_COUNT       = 32,
    parameter integer SAMPLES_PER_TAP = 8,
    parameter integer SETTLE_CYCLES   = 2,
    parameter integer MIN_EYE_TAPS    = 4,
    parameter integer LANE_W          = (LANES <= 1) ? 1 : $clog2(LANES),
    parameter integer TAP_W           = (TAP_COUNT <= 1) ? 1 : $clog2(TAP_COUNT)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,

    output logic                         busy,
    output logic                         done,
    output logic [LANE_W-1:0]            lane_select,
    output logic [TAP_W-1:0]             tap_value,
    output logic                         tap_load,
    output logic                         sample_req,
    input  logic                         sample_valid,
    input  logic                         sample_data,
    input  logic                         expected_data,

    output logic [LANES*TAP_W-1:0]       trained_taps,
    output logic [LANES-1:0]             lane_pass,
    output logic                         training_failed,
    output logic [LANE_W-1:0]            first_failed_lane
);
    localparam integer SAMPLE_W = (SAMPLES_PER_TAP <= 1) ? 1 : $clog2(SAMPLES_PER_TAP);
    localparam integer SETTLE_W = (SETTLE_CYCLES <= 1) ? 1 : $clog2(SETTLE_CYCLES + 1);
    localparam integer RUN_W    = (TAP_COUNT <= 1) ? 1 : $clog2(TAP_COUNT + 1);

    typedef enum logic [2:0] {IDLE, LOAD_TAP, SETTLE, SAMPLE, FINISH} state_t;
    state_t state;

    logic [SAMPLE_W-1:0] sample_count;
    logic [SETTLE_W-1:0] settle_count;
    logic                 tap_has_error;
    logic [TAP_W-1:0]     run_start;
    logic [RUN_W-1:0]     run_length;
    logic [TAP_W-1:0]     best_start;
    logic [RUN_W-1:0]     best_length;
    logic                 failure_seen;

    assign busy            = (state != IDLE) && (state != FINISH);
    assign tap_load        = (state == LOAD_TAP);
    assign sample_req      = (state == SAMPLE) && (sample_count < SAMPLES_PER_TAP);

    always_ff @(posedge clk or negedge rst_n) begin : training_fsm
        logic                 this_error;
        logic                 tap_good;
        logic [TAP_W-1:0]     candidate_start;
        logic [RUN_W-1:0]     candidate_length;
        logic [TAP_W-1:0]     final_best_start;
        logic [RUN_W-1:0]     final_best_length;
        logic [TAP_W:0]       center_sum;

        if (!rst_n) begin
            state             <= IDLE;
            done              <= 1'b0;
            lane_select       <= '0;
            tap_value         <= '0;
            sample_count      <= '0;
            settle_count      <= '0;
            tap_has_error     <= 1'b0;
            run_start         <= '0;
            run_length        <= '0;
            best_start        <= '0;
            best_length       <= '0;
            failure_seen      <= 1'b0;
            trained_taps      <= '0;
            lane_pass         <= '0;
            training_failed   <= 1'b0;
            first_failed_lane <= '0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        lane_select       <= '0;
                        tap_value         <= '0;
                        trained_taps      <= '0;
                        lane_pass         <= '0;
                        training_failed   <= 1'b0;
                        first_failed_lane <= '0;
                        sample_count      <= '0;
                        settle_count      <= '0;
                        tap_has_error     <= 1'b0;
                        run_start         <= '0;
                        run_length        <= '0;
                        best_start        <= '0;
                        best_length       <= '0;
                        failure_seen      <= 1'b0;
                        state             <= LOAD_TAP;
                    end
                end

                LOAD_TAP: begin
                    settle_count <= '0;
                    sample_count <= '0;
                    tap_has_error <= 1'b0;
                    state <= (SETTLE_CYCLES == 0) ? SAMPLE : SETTLE;
                end

                SETTLE: begin
                    if (settle_count == SETTLE_CYCLES-1) begin
                        state <= SAMPLE;
                    end else begin
                        settle_count <= settle_count + 1'b1;
                    end
                end

                SAMPLE: begin
                    if (sample_valid && sample_req) begin
                        this_error = (sample_data != expected_data);
                        tap_has_error <= tap_has_error | this_error;

                        if (sample_count == SAMPLES_PER_TAP-1) begin
                            tap_good = !(tap_has_error | this_error);
                            candidate_start  = run_start;
                            candidate_length = run_length;

                            if (tap_good) begin
                                if (run_length == 0) begin
                                    candidate_start = tap_value;
                                end
                                candidate_length = run_length + 1'b1;
                            end

                            final_best_start  = best_start;
                            final_best_length = best_length;
                            if (candidate_length > best_length) begin
                                final_best_start  = candidate_start;
                                final_best_length = candidate_length;
                            end

                            if (tap_value == TAP_COUNT-1) begin
                                if (final_best_length >= MIN_EYE_TAPS) begin
                                    lane_pass[lane_select] <= 1'b1;
                                    center_sum = final_best_start + ((final_best_length - 1'b1) >> 1);
                                    trained_taps[lane_select*TAP_W +: TAP_W] <= center_sum[TAP_W-1:0];
                                end else begin
                                    lane_pass[lane_select] <= 1'b0;
                                    trained_taps[lane_select*TAP_W +: TAP_W] <= '0;
                                    if (!failure_seen) begin
                                        first_failed_lane <= lane_select;
                                    end
                                    failure_seen <= 1'b1;
                                    training_failed <= 1'b1;
                                end

                                if (lane_select == LANES-1) begin
                                    state <= FINISH;
                                end else begin
                                    lane_select   <= lane_select + 1'b1;
                                    tap_value     <= '0;
                                    run_start     <= '0;
                                    run_length    <= '0;
                                    best_start    <= '0;
                                    best_length   <= '0;
                                    state         <= LOAD_TAP;
                                end
                            end else begin
                                tap_value <= tap_value + 1'b1;
                                if (tap_good) begin
                                    run_start  <= candidate_start;
                                    run_length <= candidate_length;
                                end else begin
                                    run_length <= '0;
                                end
                                best_start  <= final_best_start;
                                best_length <= final_best_length;
                                state <= LOAD_TAP;
                            end

                            sample_count  <= '0;
                            tap_has_error <= 1'b0;
                        end else begin
                            sample_count <= sample_count + 1'b1;
                        end
                    end
                end

                FINISH: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (LANES < 1 || TAP_COUNT < 2 || SAMPLES_PER_TAP < 1 || MIN_EYE_TAPS < 1)
            $fatal(1, "Invalid ddr_read_eye_trainer parameterization");
    end
`endif
endmodule
