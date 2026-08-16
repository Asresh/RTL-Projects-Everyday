// Author: Asresh Kuricheti
`timescale 1ns/1ps

module pcie_completion_reorder_buffer #(
    parameter integer DATA_W          = 32,
    parameter integer TAG_W           = 5,
    parameter integer MAX_OUTSTANDING = 8,
    parameter integer MAX_BEATS       = 4,
    parameter integer TAGS            = (1 << TAG_W),
    parameter integer PTR_W           = (MAX_OUTSTANDING <= 2) ? 1 : $clog2(MAX_OUTSTANDING),
    parameter integer COUNT_W         = $clog2(MAX_OUTSTANDING + 1),
    parameter integer BEAT_W          = (MAX_BEATS <= 2) ? 1 : $clog2(MAX_BEATS),
    parameter integer LEN_W           = $clog2(MAX_BEATS + 1)
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 issue_valid_i,
    output logic                issue_ready_o,
    input  wire [TAG_W-1:0]     issue_tag_i,
    input  wire [LEN_W-1:0]     issue_beats_i,

    input  wire                 cpl_valid_i,
    output logic                cpl_ready_o,
    input  wire [TAG_W-1:0]     cpl_tag_i,
    input  wire [BEAT_W-1:0]    cpl_beat_i,
    input  wire [DATA_W-1:0]    cpl_data_i,
    input  wire                 cpl_error_i,

    output logic                retire_valid_o,
    input  wire                 retire_ready_i,
    output logic [TAG_W-1:0]    retire_tag_o,
    output logic [BEAT_W-1:0]   retire_beat_o,
    output logic [DATA_W-1:0]   retire_data_o,
    output logic                retire_last_o,
    output logic                retire_error_o,

    output logic [COUNT_W-1:0]  outstanding_o,
    output logic                protocol_error_pulse_o
);

    logic [TAG_W-1:0] order_fifo [0:MAX_OUTSTANDING-1];
    logic [DATA_W-1:0] payload_mem [0:TAGS-1][0:MAX_BEATS-1];
    logic [MAX_BEATS-1:0] received_q [0:TAGS-1];
    logic [LEN_W-1:0] expected_q [0:TAGS-1];
    logic active_q [0:TAGS-1];
    logic complete_q [0:TAGS-1];
    logic error_q [0:TAGS-1];

    logic [PTR_W-1:0] head_q, tail_q;
    logic [COUNT_W-1:0] count_q;
    logic [BEAT_W-1:0] retire_beat_q;
    logic [TAG_W-1:0] head_tag;
    logic issue_fire, cpl_fire, retire_fire, retire_last_fire;
    logic cpl_context_ok, cpl_beat_ok, cpl_unique;
    logic [MAX_BEATS-1:0] cpl_bit_mask, expected_mask;
    integer i;

    assign head_tag = order_fifo[head_q];
    assign issue_ready_o = (count_q < MAX_OUTSTANDING) &&
                           !active_q[issue_tag_i] &&
                           (issue_beats_i != 0) &&
                           (issue_beats_i <= MAX_BEATS);
    assign cpl_ready_o = 1'b1;
    assign issue_fire = issue_valid_i && issue_ready_o;
    assign cpl_fire = cpl_valid_i && cpl_ready_o;

    assign cpl_context_ok = active_q[cpl_tag_i];
    assign cpl_beat_ok = cpl_context_ok &&
                         (cpl_beat_i < expected_q[cpl_tag_i]);
    assign cpl_unique = cpl_beat_ok && !received_q[cpl_tag_i][cpl_beat_i];
    assign cpl_bit_mask = {{(MAX_BEATS-1){1'b0}}, 1'b1} << cpl_beat_i;
    assign expected_mask = {MAX_BEATS{1'b1}} >>
                           (MAX_BEATS - expected_q[cpl_tag_i]);

    always_comb begin
        retire_valid_o = (count_q != 0) && complete_q[head_tag];
        retire_tag_o = head_tag;
        retire_beat_o = retire_beat_q;
        retire_data_o = payload_mem[head_tag][retire_beat_q];
        retire_last_o = retire_valid_o &&
                        (retire_beat_q == expected_q[head_tag] - 1'b1);
        retire_error_o = retire_valid_o && error_q[head_tag];
    end

    assign retire_fire = retire_valid_o && retire_ready_i;
    assign retire_last_fire = retire_fire && retire_last_o;
    assign outstanding_o = count_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q <= '0;
            tail_q <= '0;
            count_q <= '0;
            retire_beat_q <= '0;
            protocol_error_pulse_o <= 1'b0;
            for (i = 0; i < TAGS; i = i + 1) begin
                received_q[i] <= '0;
                expected_q[i] <= '0;
                active_q[i] <= 1'b0;
                complete_q[i] <= 1'b0;
                error_q[i] <= 1'b0;
            end
        end else begin
            protocol_error_pulse_o <= 1'b0;

            if (issue_fire) begin
                order_fifo[tail_q] <= issue_tag_i;
                tail_q <= tail_q + 1'b1;
                expected_q[issue_tag_i] <= issue_beats_i;
                received_q[issue_tag_i] <= '0;
                active_q[issue_tag_i] <= 1'b1;
                complete_q[issue_tag_i] <= 1'b0;
                error_q[issue_tag_i] <= 1'b0;
            end

            if (cpl_fire) begin
                if (!cpl_unique) begin
                    protocol_error_pulse_o <= 1'b1;
                end else begin
                    payload_mem[cpl_tag_i][cpl_beat_i] <= cpl_data_i;
                    received_q[cpl_tag_i][cpl_beat_i] <= 1'b1;
                    error_q[cpl_tag_i] <= error_q[cpl_tag_i] | cpl_error_i;
                    if ((received_q[cpl_tag_i] | cpl_bit_mask) == expected_mask)
                        complete_q[cpl_tag_i] <= 1'b1;
                end
            end

            case ({issue_fire, retire_last_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase

            if (retire_fire) begin
                if (retire_last_o) begin
                    active_q[head_tag] <= 1'b0;
                    complete_q[head_tag] <= 1'b0;
                    received_q[head_tag] <= '0;
                    error_q[head_tag] <= 1'b0;
                    head_q <= head_q + 1'b1;
                    retire_beat_q <= '0;
                end else begin
                    retire_beat_q <= retire_beat_q + 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (MAX_OUTSTANDING < 2 ||
            (MAX_OUTSTANDING & (MAX_OUTSTANDING-1)) != 0)
            $fatal(1, "MAX_OUTSTANDING must be a power of two and at least two");
        if (MAX_BEATS < 2 || (MAX_BEATS & (MAX_BEATS-1)) != 0)
            $fatal(1, "MAX_BEATS must be a power of two and at least two");
        if (MAX_OUTSTANDING > TAGS)
            $fatal(1, "MAX_OUTSTANDING cannot exceed the tag space");
    end
`endif

endmodule
