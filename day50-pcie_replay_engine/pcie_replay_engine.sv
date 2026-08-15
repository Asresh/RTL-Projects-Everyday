// Author: Asresh Kuricheti
`timescale 1ns/1ps

module pcie_replay_engine #(
    parameter integer DATA_W         = 64,
    parameter integer SEQ_W          = 12,
    parameter integer REPLAY_DEPTH   = 8,
    parameter integer TIMEOUT_CYCLES = 32,
    parameter integer PTR_W          = (REPLAY_DEPTH <= 2) ? 1 : $clog2(REPLAY_DEPTH),
    parameter integer COUNT_W        = $clog2(REPLAY_DEPTH + 1),
    parameter integer TIMER_W        = (TIMEOUT_CYCLES <= 2) ? 1 : $clog2(TIMEOUT_CYCLES)
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   s_valid_i,
    output logic                  s_ready_o,
    input  wire [DATA_W-1:0]      s_data_i,

    output logic                  tx_valid_o,
    input  wire                   tx_ready_i,
    output logic [DATA_W-1:0]     tx_data_o,
    output logic [SEQ_W-1:0]      tx_seq_o,
    output logic                  tx_replay_o,

    input  wire                   ack_valid_i,
    input  wire [SEQ_W-1:0]       ack_seq_i,
    input  wire                   nak_valid_i,
    input  wire [SEQ_W-1:0]       nak_seq_i,

    output logic [COUNT_W-1:0]    outstanding_o,
    output logic                  replay_active_o,
    output logic                  timeout_replay_pulse_o
);

    logic [DATA_W-1:0] data_mem [0:REPLAY_DEPTH-1];
    logic [SEQ_W-1:0]  seq_mem  [0:REPLAY_DEPTH-1];

    logic [PTR_W-1:0] head_q, tail_q, replay_ptr_q;
    logic [COUNT_W-1:0] count_q, replay_remaining_q;
    logic [SEQ_W-1:0] next_seq_q;
    logic [TIMER_W-1:0] timer_q;
    logic replay_active_q;

    logic [SEQ_W-1:0] ack_distance, nak_distance;
    logic [COUNT_W-1:0] ack_free_count;
    logic ack_hit, nak_hit, timeout_due;
    logic new_tx_fire, replay_tx_fire;

    assign ack_distance = ack_seq_i - seq_mem[head_q];
    assign nak_distance = nak_seq_i - seq_mem[head_q];
    assign ack_hit = ack_valid_i && (count_q != 0) &&
                     (ack_distance < count_q);
    assign nak_hit = nak_valid_i && (count_q != 0) &&
                     (nak_distance < count_q);
    assign ack_free_count = ack_hit ?
                            ack_distance[COUNT_W-1:0] + 1'b1 : '0;
    assign timeout_due = (count_q != 0) && !replay_active_q &&
                         (timer_q == TIMEOUT_CYCLES-1);

    always_comb begin
        s_ready_o = !replay_active_q && !nak_valid_i && !timeout_due &&
                    tx_ready_i && ((count_q < REPLAY_DEPTH) || ack_hit);

        tx_valid_o = 1'b0;
        tx_data_o = '0;
        tx_seq_o = '0;
        tx_replay_o = replay_active_q;

        if (replay_active_q) begin
            tx_valid_o = 1'b1;
            tx_data_o = data_mem[replay_ptr_q];
            tx_seq_o = seq_mem[replay_ptr_q];
        end else if (!nak_valid_i && !timeout_due &&
                     ((count_q < REPLAY_DEPTH) || ack_hit)) begin
            tx_valid_o = s_valid_i;
            tx_data_o = s_data_i;
            tx_seq_o = next_seq_q;
        end
    end

    assign new_tx_fire = s_valid_i && s_ready_o;
    assign replay_tx_fire = replay_active_q && tx_valid_o && tx_ready_i;
    assign outstanding_o = count_q;
    assign replay_active_o = replay_active_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            head_q <= '0;
            tail_q <= '0;
            replay_ptr_q <= '0;
            count_q <= '0;
            replay_remaining_q <= '0;
            next_seq_q <= '0;
            timer_q <= '0;
            replay_active_q <= 1'b0;
            timeout_replay_pulse_o <= 1'b0;
        end else begin
            timeout_replay_pulse_o <= 1'b0;

            if (new_tx_fire) begin
                data_mem[tail_q] <= s_data_i;
                seq_mem[tail_q] <= next_seq_q;
                tail_q <= tail_q + 1'b1;
                next_seq_q <= next_seq_q + 1'b1;
            end

            count_q <= count_q - ack_free_count + new_tx_fire;
            if (ack_hit)
                head_q <= head_q + ack_free_count[PTR_W-1:0];

            if ((count_q - ack_free_count + new_tx_fire) == 0) begin
                timer_q <= '0;
            end else if (ack_hit || (new_tx_fire && (count_q == 0)) ||
                         nak_hit || timeout_due || replay_tx_fire) begin
                timer_q <= '0;
            end else if (!replay_active_q) begin
                timer_q <= timer_q + 1'b1;
            end

            if (ack_hit) begin
                replay_active_q <= 1'b0;
                replay_remaining_q <= '0;
            end else if (nak_hit) begin
                replay_active_q <= 1'b1;
                replay_ptr_q <= head_q + nak_distance[PTR_W-1:0];
                replay_remaining_q <= count_q - nak_distance;
            end else if (timeout_due) begin
                replay_active_q <= 1'b1;
                replay_ptr_q <= head_q;
                replay_remaining_q <= count_q;
                timeout_replay_pulse_o <= 1'b1;
            end else if (replay_tx_fire) begin
                if (replay_remaining_q == 1) begin
                    replay_active_q <= 1'b0;
                    replay_remaining_q <= '0;
                end else begin
                    replay_ptr_q <= replay_ptr_q + 1'b1;
                    replay_remaining_q <= replay_remaining_q - 1'b1;
                end
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (REPLAY_DEPTH < 2 || (REPLAY_DEPTH & (REPLAY_DEPTH-1)) != 0)
            $fatal(1, "REPLAY_DEPTH must be a power of two and at least two");
        if (REPLAY_DEPTH > (1 << (SEQ_W-1)))
            $fatal(1, "REPLAY_DEPTH must not exceed half the sequence space");
        if (TIMEOUT_CYCLES < 2)
            $fatal(1, "TIMEOUT_CYCLES must be at least two");
    end
`endif

endmodule
