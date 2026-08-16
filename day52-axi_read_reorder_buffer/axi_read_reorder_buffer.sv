// Author: Asresh Kuricheti
`timescale 1ns/1ps

module axi_read_reorder_buffer #(
    parameter integer DATA_W = 32,
    parameter integer ID_W = 3,
    parameter integer SLOTS = 8,
    parameter integer MAX_BEATS = 4,
    parameter integer SEQ_W = 4,
    parameter integer SLOT_W = (SLOTS <= 2) ? 1 : $clog2(SLOTS),
    parameter integer BEAT_W = (MAX_BEATS <= 2) ? 1 : $clog2(MAX_BEATS),
    parameter integer LEN_W = $clog2(MAX_BEATS + 1),
    parameter integer COUNT_W = $clog2(SLOTS + 1),
    parameter integer IDS = (1 << ID_W)
) (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 alloc_valid_i,
    output logic                alloc_ready_o,
    input  wire [ID_W-1:0]      alloc_id_i,
    input  wire [LEN_W-1:0]     alloc_beats_i,
    output logic [SLOT_W-1:0]   alloc_slot_o,

    input  wire                 fill_valid_i,
    output logic                fill_ready_o,
    input  wire [SLOT_W-1:0]    fill_slot_i,
    input  wire [BEAT_W-1:0]    fill_beat_i,
    input  wire [DATA_W-1:0]    fill_data_i,
    input  wire [1:0]           fill_resp_i,
    input  wire                 fill_last_i,

    output logic                rvalid_o,
    input  wire                 rready_i,
    output logic [ID_W-1:0]     rid_o,
    output logic [DATA_W-1:0]   rdata_o,
    output logic [1:0]          rresp_o,
    output logic                rlast_o,

    output logic [COUNT_W-1:0]  outstanding_o,
    output logic                protocol_error_pulse_o
);

    logic slot_active_q [0:SLOTS-1];
    logic slot_complete_q [0:SLOTS-1];
    logic [ID_W-1:0] slot_id_q [0:SLOTS-1];
    logic [SEQ_W-1:0] slot_seq_q [0:SLOTS-1];
    logic [LEN_W-1:0] slot_len_q [0:SLOTS-1];
    logic [MAX_BEATS-1:0] slot_received_q [0:SLOTS-1];
    logic [DATA_W-1:0] data_mem [0:SLOTS-1][0:MAX_BEATS-1];
    logic [1:0] resp_mem [0:SLOTS-1][0:MAX_BEATS-1];
    logic [SEQ_W-1:0] issue_seq_q [0:IDS-1];
    logic [SEQ_W-1:0] retire_seq_q [0:IDS-1];

    logic output_active_q;
    logic [SLOT_W-1:0] output_slot_q;
    logic [BEAT_W-1:0] output_beat_q;
    logic [SLOT_W-1:0] arbiter_base_q;
    logic [COUNT_W-1:0] count_q;

    logic free_found, candidate_found;
    logic [SLOT_W-1:0] free_slot, candidate_slot;
    logic alloc_fire, fill_fire, output_fire, output_last_fire;
    logic fill_slot_ok, fill_context_ok, fill_beat_ok, fill_unique, fill_last_ok;
    logic [MAX_BEATS-1:0] fill_mask, expected_mask;
    integer i;
    integer scan_idx;

    always_comb begin
        free_found = 1'b0;
        free_slot = '0;
        for (i = 0; i < SLOTS; i = i + 1) begin
            if (!free_found && !slot_active_q[i]) begin
                free_found = 1'b1;
                free_slot = i[SLOT_W-1:0];
            end
        end
    end

    assign alloc_ready_o = free_found && (alloc_beats_i != 0) &&
                           (alloc_beats_i <= MAX_BEATS);
    assign alloc_slot_o = free_slot;
    assign alloc_fire = alloc_valid_i && alloc_ready_o;

    assign fill_slot_ok = (fill_slot_i < SLOTS);
    assign fill_context_ok = fill_slot_ok && slot_active_q[fill_slot_i] &&
                             !slot_complete_q[fill_slot_i];
    assign fill_beat_ok = fill_context_ok &&
                          (fill_beat_i < slot_len_q[fill_slot_i]);
    assign fill_unique = fill_beat_ok &&
                         !slot_received_q[fill_slot_i][fill_beat_i];
    assign fill_last_ok = fill_beat_ok &&
                          (fill_last_i == (fill_beat_i == slot_len_q[fill_slot_i] - 1'b1));
    assign fill_mask = {{(MAX_BEATS-1){1'b0}}, 1'b1} << fill_beat_i;
    assign expected_mask = {MAX_BEATS{1'b1}} >>
                           (MAX_BEATS - slot_len_q[fill_slot_i]);
    assign fill_ready_o = 1'b1;
    assign fill_fire = fill_valid_i && fill_ready_o;

    always_comb begin
        candidate_found = 1'b0;
        candidate_slot = '0;
        for (i = 0; i < SLOTS; i = i + 1) begin
            scan_idx = arbiter_base_q + i;
            if (scan_idx >= SLOTS)
                scan_idx = scan_idx - SLOTS;
            if (!candidate_found && slot_active_q[scan_idx] &&
                slot_complete_q[scan_idx] &&
                (slot_seq_q[scan_idx] == retire_seq_q[slot_id_q[scan_idx]])) begin
                candidate_found = 1'b1;
                candidate_slot = scan_idx[SLOT_W-1:0];
            end
        end
    end

    always_comb begin
        rvalid_o = output_active_q;
        rid_o = slot_id_q[output_slot_q];
        rdata_o = data_mem[output_slot_q][output_beat_q];
        rresp_o = resp_mem[output_slot_q][output_beat_q];
        rlast_o = output_active_q &&
                  (output_beat_q == slot_len_q[output_slot_q] - 1'b1);
    end

    assign output_fire = rvalid_o && rready_i;
    assign output_last_fire = output_fire && rlast_o;
    assign outstanding_o = count_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_active_q <= 1'b0;
            output_slot_q <= '0;
            output_beat_q <= '0;
            arbiter_base_q <= '0;
            count_q <= '0;
            protocol_error_pulse_o <= 1'b0;
            for (i = 0; i < SLOTS; i = i + 1) begin
                slot_active_q[i] <= 1'b0;
                slot_complete_q[i] <= 1'b0;
                slot_received_q[i] <= '0;
                slot_id_q[i] <= '0;
                slot_seq_q[i] <= '0;
                slot_len_q[i] <= '0;
            end
            for (i = 0; i < IDS; i = i + 1) begin
                issue_seq_q[i] <= '0;
                retire_seq_q[i] <= '0;
            end
        end else begin
            protocol_error_pulse_o <= 1'b0;

            if (alloc_fire) begin
                slot_active_q[free_slot] <= 1'b1;
                slot_complete_q[free_slot] <= 1'b0;
                slot_received_q[free_slot] <= '0;
                slot_id_q[free_slot] <= alloc_id_i;
                slot_seq_q[free_slot] <= issue_seq_q[alloc_id_i];
                slot_len_q[free_slot] <= alloc_beats_i;
                issue_seq_q[alloc_id_i] <= issue_seq_q[alloc_id_i] + 1'b1;
            end

            if (fill_fire) begin
                if (!fill_unique || !fill_last_ok) begin
                    protocol_error_pulse_o <= 1'b1;
                end else begin
                    data_mem[fill_slot_i][fill_beat_i] <= fill_data_i;
                    resp_mem[fill_slot_i][fill_beat_i] <= fill_resp_i;
                    slot_received_q[fill_slot_i][fill_beat_i] <= 1'b1;
                    if ((slot_received_q[fill_slot_i] | fill_mask) == expected_mask)
                        slot_complete_q[fill_slot_i] <= 1'b1;
                end
            end

            if (!output_active_q && candidate_found) begin
                output_active_q <= 1'b1;
                output_slot_q <= candidate_slot;
                output_beat_q <= '0;
            end else if (output_fire) begin
                if (rlast_o) begin
                    output_active_q <= 1'b0;
                    output_beat_q <= '0;
                    slot_active_q[output_slot_q] <= 1'b0;
                    slot_complete_q[output_slot_q] <= 1'b0;
                    slot_received_q[output_slot_q] <= '0;
                    retire_seq_q[slot_id_q[output_slot_q]] <=
                        retire_seq_q[slot_id_q[output_slot_q]] + 1'b1;
                    arbiter_base_q <= output_slot_q + 1'b1;
                end else begin
                    output_beat_q <= output_beat_q + 1'b1;
                end
            end

            case ({alloc_fire, output_last_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (SLOTS < 2 || (SLOTS & (SLOTS-1)) != 0)
            $fatal(1, "SLOTS must be a power of two and at least two");
        if (MAX_BEATS < 2 || (MAX_BEATS & (MAX_BEATS-1)) != 0)
            $fatal(1, "MAX_BEATS must be a power of two and at least two");
        if ((1 << SEQ_W) < (2 * SLOTS))
            $fatal(1, "SEQ_W must provide at least twice the slot count");
    end
`endif

endmodule
