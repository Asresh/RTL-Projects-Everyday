// Author: Asresh Kuricheti
`timescale 1ns/1ps

module coherent_home_node #(
    parameter integer NUM_CLIENTS = 4,
    parameter integer ADDR_W      = 32,
    parameter integer DATA_W      = 64,
    parameter integer CLIENT_W    = (NUM_CLIENTS <= 1) ? 1 : $clog2(NUM_CLIENTS)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         req_valid_i,
    output logic                        req_ready_o,
    input  wire [1:0]                   req_opcode_i,
    input  wire [CLIENT_W-1:0]          req_src_i,
    input  wire [ADDR_W-1:0]            req_addr_i,
    input  wire [DATA_W-1:0]            req_data_i,
    input  wire [NUM_CLIENTS-1:0]        req_sharers_i,
    input  wire                         req_owner_valid_i,
    input  wire [CLIENT_W-1:0]          req_owner_i,
    input  wire                         req_dirty_i,

    output logic [NUM_CLIENTS-1:0]       snoop_valid_o,
    input  wire [NUM_CLIENTS-1:0]        snoop_ready_i,
    output logic                        snoop_invalidate_o,
    output logic [ADDR_W-1:0]           snoop_addr_o,
    input  wire [NUM_CLIENTS-1:0]        snoop_rsp_valid_i,
    input  wire [NUM_CLIENTS-1:0]        snoop_rsp_dirty_i,
    input  wire [NUM_CLIENTS*DATA_W-1:0] snoop_rsp_data_i,

    output logic                        mem_req_valid_o,
    input  wire                         mem_req_ready_i,
    output logic                        mem_req_write_o,
    output logic [ADDR_W-1:0]           mem_req_addr_o,
    output logic [DATA_W-1:0]           mem_req_data_o,
    input  wire                         mem_rsp_valid_i,
    input  wire [DATA_W-1:0]            mem_rsp_data_i,

    output logic                        rsp_valid_o,
    input  wire                         rsp_ready_i,
    output logic [CLIENT_W-1:0]          rsp_dst_o,
    output logic [DATA_W-1:0]            rsp_data_o,
    output logic                        rsp_dirty_forwarded_o,

    output logic                        dir_update_valid_o,
    output logic [NUM_CLIENTS-1:0]       dir_sharers_o,
    output logic                        dir_owner_valid_o,
    output logic [CLIENT_W-1:0]          dir_owner_o,
    output logic                        dir_dirty_o,
    output logic                        busy_o,
    output logic [2:0]                  state_o
);

    localparam logic [1:0] OP_READ_SHARED = 2'd0;
    localparam logic [1:0] OP_READ_UNIQUE = 2'd1;
    localparam logic [1:0] OP_WRITEBACK   = 2'd2;
    localparam logic [1:0] OP_EVICT       = 2'd3;

    localparam logic [2:0] ST_IDLE        = 3'd0;
    localparam logic [2:0] ST_SNOOP_SEND  = 3'd1;
    localparam logic [2:0] ST_SNOOP_WAIT  = 3'd2;
    localparam logic [2:0] ST_MEM_REQ     = 3'd3;
    localparam logic [2:0] ST_MEM_WAIT    = 3'd4;
    localparam logic [2:0] ST_RESPONSE    = 3'd5;

    logic [2:0] state_q;
    logic [1:0] opcode_q;
    logic [CLIENT_W-1:0] src_q, owner_q;
    logic [ADDR_W-1:0] addr_q;
    logic [DATA_W-1:0] data_q, response_data_q;
    logic [NUM_CLIENTS-1:0] sharers_q;
    logic owner_valid_q, dirty_q;
    logic [NUM_CLIENTS-1:0] snoop_send_q, snoop_wait_q;
    logic dirty_seen_q;

    logic [NUM_CLIENTS-1:0] initial_targets;
    logic [NUM_CLIENTS-1:0] accepted_snoops;
    logic [NUM_CLIENTS-1:0] accepted_responses;
    logic [NUM_CLIENTS-1:0] wait_after_response;
    logic any_dirty_response;
    logic [DATA_W-1:0] selected_snoop_data;
    integer i;

    always_comb begin
        initial_targets = '0;
        if (req_opcode_i == OP_READ_SHARED) begin
            if (req_owner_valid_i && req_dirty_i && (req_owner_i != req_src_i))
                initial_targets[req_owner_i] = 1'b1;
        end else if (req_opcode_i == OP_READ_UNIQUE) begin
            initial_targets = req_sharers_i;
            initial_targets[req_src_i] = 1'b0;
            if (req_owner_valid_i && (req_owner_i != req_src_i))
                initial_targets[req_owner_i] = 1'b1;
        end
    end

    assign accepted_snoops = snoop_send_q & snoop_ready_i;
    assign accepted_responses = snoop_wait_q & snoop_rsp_valid_i;
    assign wait_after_response = snoop_wait_q & ~snoop_rsp_valid_i;
    assign any_dirty_response = |(accepted_responses & snoop_rsp_dirty_i);

    always_comb begin
        selected_snoop_data = response_data_q;
        for (i = 0; i < NUM_CLIENTS; i = i + 1)
            if (accepted_responses[i] && snoop_rsp_dirty_i[i])
                selected_snoop_data = snoop_rsp_data_i[i*DATA_W +: DATA_W];
    end

    always_comb begin
        req_ready_o = (state_q == ST_IDLE);
        busy_o = (state_q != ST_IDLE);
        state_o = state_q;
        snoop_valid_o = (state_q == ST_SNOOP_SEND) ? snoop_send_q : '0;
        snoop_invalidate_o = (opcode_q == OP_READ_UNIQUE);
        snoop_addr_o = addr_q;
        mem_req_valid_o = (state_q == ST_MEM_REQ);
        mem_req_write_o = (opcode_q == OP_WRITEBACK) ||
                          ((opcode_q == OP_EVICT) && dirty_q);
        mem_req_addr_o = addr_q;
        mem_req_data_o = data_q;
        rsp_valid_o = (state_q == ST_RESPONSE);
        rsp_dst_o = src_q;
        rsp_data_o = response_data_q;
        rsp_dirty_forwarded_o = dirty_seen_q;
        dir_update_valid_o = rsp_valid_o;
        dir_sharers_o = sharers_q;
        dir_owner_valid_o = owner_valid_q;
        dir_owner_o = owner_q;
        dir_dirty_o = dirty_q;

        case (opcode_q)
            OP_READ_SHARED: begin
                dir_sharers_o = sharers_q | ({{(NUM_CLIENTS-1){1'b0}}, 1'b1} << src_q);
                dir_owner_valid_o = 1'b0;
                dir_dirty_o = 1'b0;
            end
            OP_READ_UNIQUE: begin
                dir_sharers_o = ({{(NUM_CLIENTS-1){1'b0}}, 1'b1} << src_q);
                dir_owner_valid_o = 1'b1;
                dir_owner_o = src_q;
                dir_dirty_o = 1'b1;
            end
            OP_WRITEBACK, OP_EVICT: begin
                dir_sharers_o = sharers_q & ~({{(NUM_CLIENTS-1){1'b0}}, 1'b1} << src_q);
                if (owner_valid_q && (owner_q == src_q)) begin
                    dir_owner_valid_o = 1'b0;
                    dir_dirty_o = 1'b0;
                end
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= ST_IDLE;
            opcode_q <= OP_READ_SHARED;
            src_q <= '0;
            owner_q <= '0;
            addr_q <= '0;
            data_q <= '0;
            response_data_q <= '0;
            sharers_q <= '0;
            owner_valid_q <= 1'b0;
            dirty_q <= 1'b0;
            snoop_send_q <= '0;
            snoop_wait_q <= '0;
            dirty_seen_q <= 1'b0;
        end else begin
            case (state_q)
                ST_IDLE: if (req_valid_i) begin
                    opcode_q <= req_opcode_i;
                    src_q <= req_src_i;
                    owner_q <= req_owner_i;
                    addr_q <= req_addr_i;
                    data_q <= req_data_i;
                    sharers_q <= req_sharers_i;
                    owner_valid_q <= req_owner_valid_i;
                    dirty_q <= req_dirty_i;
                    response_data_q <= '0;
                    dirty_seen_q <= 1'b0;
                    snoop_send_q <= initial_targets;
                    snoop_wait_q <= '0;
                    if (initial_targets != '0)
                        state_q <= ST_SNOOP_SEND;
                    else if ((req_opcode_i == OP_WRITEBACK) ||
                             ((req_opcode_i == OP_EVICT) && req_dirty_i) ||
                             (req_opcode_i == OP_READ_SHARED) ||
                             (req_opcode_i == OP_READ_UNIQUE))
                        state_q <= ST_MEM_REQ;
                    else
                        state_q <= ST_RESPONSE;
                end

                ST_SNOOP_SEND: begin
                    snoop_send_q <= snoop_send_q & ~snoop_ready_i;
                    snoop_wait_q <= snoop_wait_q | accepted_snoops;
                    if ((snoop_send_q & ~snoop_ready_i) == '0)
                        state_q <= ST_SNOOP_WAIT;
                end

                ST_SNOOP_WAIT: begin
                    snoop_wait_q <= wait_after_response;
                    if (any_dirty_response) begin
                        response_data_q <= selected_snoop_data;
                        dirty_seen_q <= 1'b1;
                    end
                    if ((snoop_wait_q != '0) && (wait_after_response == '0)) begin
                        if (dirty_seen_q || any_dirty_response)
                            state_q <= ST_RESPONSE;
                        else
                            state_q <= ST_MEM_REQ;
                    end
                end

                ST_MEM_REQ: if (mem_req_ready_i) begin
                    if (mem_req_write_o)
                        state_q <= ST_RESPONSE;
                    else
                        state_q <= ST_MEM_WAIT;
                end

                ST_MEM_WAIT: if (mem_rsp_valid_i) begin
                    response_data_q <= mem_rsp_data_i;
                    state_q <= ST_RESPONSE;
                end

                ST_RESPONSE: if (rsp_ready_i)
                    state_q <= ST_IDLE;

                default: state_q <= ST_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NUM_CLIENTS < 1) $fatal(1, "NUM_CLIENTS must be at least one");
        if ((1 << CLIENT_W) < NUM_CLIENTS) $fatal(1, "CLIENT_W is too small");
    end
`endif

endmodule
