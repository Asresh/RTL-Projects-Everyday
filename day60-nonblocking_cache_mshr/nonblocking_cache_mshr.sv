// Author: Asresh Kuricheti
`timescale 1ns/1ps
module nonblocking_cache_mshr #(
    parameter int ADDR_W       = 32,
    parameter int DATA_W       = 64,
    parameter int ID_W         = 8,
    parameter int LINE_BYTES   = 64,
    parameter int ENTRIES      = 4,
    parameter int WAITERS      = 4,
    parameter int TAG_W        = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES),
    parameter int OCC_W        = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES + 1),
    parameter int WAITER_W     = (WAITERS <= 1) ? 1 : $clog2(WAITERS + 1),
    parameter int WAITER_PTR_W = (WAITERS <= 1) ? 1 : $clog2(WAITERS)
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 flush,

    input  logic                 req_valid,
    output logic                 req_ready,
    input  logic [ADDR_W-1:0]    req_addr,
    input  logic [ID_W-1:0]      req_id,

    output logic                 mem_req_valid,
    input  logic                 mem_req_ready,
    output logic [ADDR_W-1:0]    mem_req_addr,
    output logic [TAG_W-1:0]     mem_req_tag,

    input  logic                 fill_valid,
    output logic                 fill_ready,
    input  logic [TAG_W-1:0]     fill_tag,
    input  logic [DATA_W-1:0]    fill_data,
    input  logic                 fill_error,

    output logic                 resp_valid,
    input  logic                 resp_ready,
    output logic [ID_W-1:0]      resp_id,
    output logic [DATA_W-1:0]    resp_data,
    output logic                 resp_error,

    output logic [OCC_W-1:0]     occupancy,
    output logic [31:0]          allocation_count,
    output logic [31:0]          merge_count,
    output logic                 full_stall_sticky,
    output logic                 orphan_fill_sticky
);
    localparam int LINE_OFF_W  = $clog2(LINE_BYTES);
    localparam int LINE_ADDR_W = ADDR_W - LINE_OFF_W;

    logic [ENTRIES-1:0] active, issued, filled;
    logic [LINE_ADDR_W-1:0] line_addr [ENTRIES];
    logic [WAITER_W-1:0] waiter_count [ENTRIES];
    logic [WAITER_PTR_W-1:0] waiter_head [ENTRIES];
    logic [ID_W-1:0] waiter_id [ENTRIES][WAITERS];
    logic [DATA_W-1:0] saved_data [ENTRIES];
    logic saved_error [ENTRIES];

    logic [LINE_ADDR_W-1:0] incoming_line;
    logic hit_valid, free_valid, issue_valid, response_valid;
    logic [TAG_W-1:0] hit_index, free_index, issue_index, response_index;
    integer i, j;

    always_comb begin
        incoming_line = req_addr[ADDR_W-1:LINE_OFF_W];

        hit_valid = 1'b0;
        hit_index = '0;
        free_valid = 1'b0;
        free_index = '0;
        issue_valid = 1'b0;
        issue_index = '0;
        response_valid = 1'b0;
        response_index = '0;
        occupancy = '0;

        for (int k = 0; k < ENTRIES; k++) begin
            if (active[k])
                occupancy = occupancy + 1'b1;
            if (!hit_valid && active[k] && !filled[k] &&
                (line_addr[k] == incoming_line)) begin
                hit_valid = 1'b1;
                hit_index = TAG_W'(k);
            end
            if (!free_valid && !active[k]) begin
                free_valid = 1'b1;
                free_index = TAG_W'(k);
            end
            if (!issue_valid && active[k] && !issued[k]) begin
                issue_valid = 1'b1;
                issue_index = TAG_W'(k);
            end
            if (!response_valid && active[k] && filled[k] &&
                (waiter_count[k] != 0)) begin
                response_valid = 1'b1;
                response_index = TAG_W'(k);
            end
        end

        req_ready = !flush && (hit_valid ?
                    (waiter_count[hit_index] < WAITERS) : free_valid);

        mem_req_valid = issue_valid && !flush;
        mem_req_tag = issue_index;
        mem_req_addr = '0;
        if (issue_valid)
            mem_req_addr = {line_addr[issue_index], {LINE_OFF_W{1'b0}}};

        fill_ready = !flush && (fill_tag < ENTRIES) &&
                     active[fill_tag] && issued[fill_tag] && !filled[fill_tag];

        resp_valid = response_valid && !flush;
        resp_id = '0;
        resp_data = '0;
        resp_error = 1'b0;
        if (response_valid) begin
            resp_id = waiter_id[response_index][waiter_head[response_index]];
            resp_data = saved_data[response_index];
            resp_error = saved_error[response_index];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= '0;
            issued <= '0;
            filled <= '0;
            allocation_count <= '0;
            merge_count <= '0;
            full_stall_sticky <= 1'b0;
            orphan_fill_sticky <= 1'b0;
            for (i = 0; i < ENTRIES; i++) begin
                line_addr[i] <= '0;
                waiter_count[i] <= '0;
                waiter_head[i] <= '0;
                saved_data[i] <= '0;
                saved_error[i] <= 1'b0;
                for (j = 0; j < WAITERS; j++)
                    waiter_id[i][j] <= '0;
            end
        end else if (flush) begin
            active <= '0;
            issued <= '0;
            filled <= '0;
            for (i = 0; i < ENTRIES; i++) begin
                waiter_count[i] <= '0;
                waiter_head[i] <= '0;
            end
        end else begin
            if (req_valid && !req_ready)
                full_stall_sticky <= 1'b1;

            if (req_valid && req_ready) begin
                if (hit_valid) begin
                    waiter_id[hit_index][waiter_count[hit_index]] <= req_id;
                    waiter_count[hit_index] <= waiter_count[hit_index] + 1'b1;
                    merge_count <= merge_count + 1'b1;
                end else begin
                    active[free_index] <= 1'b1;
                    issued[free_index] <= 1'b0;
                    filled[free_index] <= 1'b0;
                    line_addr[free_index] <= incoming_line;
                    waiter_count[free_index] <= WAITER_W'(1);
                    waiter_head[free_index] <= '0;
                    waiter_id[free_index][0] <= req_id;
                    saved_data[free_index] <= '0;
                    saved_error[free_index] <= 1'b0;
                    allocation_count <= allocation_count + 1'b1;
                end
            end

            if (mem_req_valid && mem_req_ready)
                issued[issue_index] <= 1'b1;

            if (fill_valid && fill_ready) begin
                filled[fill_tag] <= 1'b1;
                saved_data[fill_tag] <= fill_data;
                saved_error[fill_tag] <= fill_error;
            end else if (fill_valid && !fill_ready) begin
                orphan_fill_sticky <= 1'b1;
            end

            if (resp_valid && resp_ready) begin
                if (waiter_count[response_index] == 1) begin
                    active[response_index] <= 1'b0;
                    issued[response_index] <= 1'b0;
                    filled[response_index] <= 1'b0;
                    waiter_count[response_index] <= '0;
                    waiter_head[response_index] <= '0;
                end else begin
                    waiter_count[response_index] <=
                        waiter_count[response_index] - 1'b1;
                    if (waiter_head[response_index] == WAITERS-1)
                        waiter_head[response_index] <= '0;
                    else
                        waiter_head[response_index] <=
                            waiter_head[response_index] + 1'b1;
                end
            end
        end
    end
endmodule
