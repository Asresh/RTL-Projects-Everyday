`timescale 1ns/1ps
`default_nettype none

module strided_dma #(
    parameter integer ADDR_W    = 16,
    parameter integer DATA_W    = 32,
    parameter integer LEN_W     = 16,
    parameter integer ROW_W     = 8,
    parameter integer TAG_W     = 8,
    parameter integer CMD_DEPTH = 4
) (
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire                         cmd_valid_i,
    output wire                         cmd_ready_o,
    input  wire [ADDR_W-1:0]            cmd_src_addr_i,
    input  wire [ADDR_W-1:0]            cmd_dst_addr_i,
    input  wire [LEN_W-1:0]             cmd_row_bytes_i,
    input  wire [ROW_W-1:0]             cmd_rows_i,
    input  wire signed [ADDR_W-1:0]     cmd_src_stride_i,
    input  wire signed [ADDR_W-1:0]     cmd_dst_stride_i,
    input  wire [TAG_W-1:0]             cmd_tag_i,

    output wire                         busy_o,
    output wire [$clog2(CMD_DEPTH+1)-1:0] queue_level_o,

    output wire                         rd_req_valid_o,
    input  wire                         rd_req_ready_i,
    output wire [ADDR_W-1:0]            rd_req_addr_o,
    input  wire                         rd_rsp_valid_i,
    output wire                         rd_rsp_ready_o,
    input  wire [DATA_W-1:0]            rd_rsp_data_i,
    input  wire                         rd_rsp_error_i,

    output wire                         wr_req_valid_o,
    input  wire                         wr_req_ready_i,
    output wire [ADDR_W-1:0]            wr_req_addr_o,
    output wire [DATA_W-1:0]            wr_req_data_o,
    output wire [DATA_W/8-1:0]          wr_req_strb_o,
    input  wire                         wr_rsp_valid_i,
    output wire                         wr_rsp_ready_o,
    input  wire                         wr_rsp_error_i,

    output reg                          done_o,
    output reg                          error_o,
    output reg  [TAG_W-1:0]             done_tag_o,
    output reg  [31:0]                  perf_bytes_o,
    output reg  [31:0]                  perf_desc_o,
    output reg  [31:0]                  perf_stall_cycles_o
);

    localparam integer BYTE_LANES = DATA_W / 8;
    localparam integer PTR_W = (CMD_DEPTH <= 1) ? 1 : $clog2(CMD_DEPTH);
    localparam integer CNT_W = $clog2(CMD_DEPTH + 1);

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_START  = 3'd1;
    localparam [2:0] S_RD_REQ = 3'd2;
    localparam [2:0] S_RD_RSP = 3'd3;
    localparam [2:0] S_WR_REQ = 3'd4;
    localparam [2:0] S_WR_RSP = 3'd5;

    reg [2:0] state_q;

    reg [ADDR_W-1:0] fifo_src_q        [0:CMD_DEPTH-1];
    reg [ADDR_W-1:0] fifo_dst_q        [0:CMD_DEPTH-1];
    reg [LEN_W-1:0]  fifo_row_bytes_q  [0:CMD_DEPTH-1];
    reg [ROW_W-1:0]  fifo_rows_q       [0:CMD_DEPTH-1];
    reg signed [ADDR_W-1:0] fifo_src_stride_q [0:CMD_DEPTH-1];
    reg signed [ADDR_W-1:0] fifo_dst_stride_q [0:CMD_DEPTH-1];
    reg [TAG_W-1:0]  fifo_tag_q        [0:CMD_DEPTH-1];
    reg [PTR_W-1:0]  fifo_wr_ptr_q;
    reg [PTR_W-1:0]  fifo_rd_ptr_q;
    reg [CNT_W-1:0]  fifo_count_q;

    reg [ADDR_W-1:0] src_addr_q;
    reg [ADDR_W-1:0] dst_addr_q;
    reg [ADDR_W-1:0] row_src_base_q;
    reg [ADDR_W-1:0] row_dst_base_q;
    reg [LEN_W-1:0]  row_bytes_q;
    reg [LEN_W-1:0]  bytes_left_q;
    reg [ROW_W-1:0]  rows_q;
    reg [ROW_W-1:0]  row_index_q;
    reg signed [ADDR_W-1:0] src_stride_q;
    reg signed [ADDR_W-1:0] dst_stride_q;
    reg [TAG_W-1:0]  tag_q;
    reg [DATA_W-1:0] read_data_q;
    reg [DATA_W/8-1:0] write_strb_q;

    wire fifo_push = cmd_valid_i && cmd_ready_o;
    wire fifo_pop  = (state_q == S_IDLE) && (fifo_count_q != 0);

    function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] ptr);
        begin
            if (ptr == CMD_DEPTH-1)
                ptr_inc = {PTR_W{1'b0}};
            else
                ptr_inc = ptr + 1'b1;
        end
    endfunction

    function automatic [BYTE_LANES-1:0] byte_mask(input [LEN_W-1:0] count);
        integer k;
        begin
            byte_mask = {BYTE_LANES{1'b0}};
            for (k = 0; k < BYTE_LANES; k = k + 1)
                if (k < count)
                    byte_mask[k] = 1'b1;
        end
    endfunction

    assign cmd_ready_o   = (fifo_count_q < CMD_DEPTH);
    assign queue_level_o = fifo_count_q;
    assign busy_o        = (state_q != S_IDLE) || (fifo_count_q != 0);

    assign rd_req_valid_o = (state_q == S_RD_REQ);
    assign rd_req_addr_o  = src_addr_q;
    assign rd_rsp_ready_o  = (state_q == S_RD_RSP);

    assign wr_req_valid_o = (state_q == S_WR_REQ);
    assign wr_req_addr_o  = dst_addr_q;
    assign wr_req_data_o  = read_data_q;
    assign wr_req_strb_o  = write_strb_q;
    assign wr_rsp_ready_o = (state_q == S_WR_RSP);

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q             <= S_IDLE;
            fifo_wr_ptr_q       <= {PTR_W{1'b0}};
            fifo_rd_ptr_q       <= {PTR_W{1'b0}};
            fifo_count_q        <= {CNT_W{1'b0}};
            src_addr_q          <= {ADDR_W{1'b0}};
            dst_addr_q          <= {ADDR_W{1'b0}};
            row_src_base_q      <= {ADDR_W{1'b0}};
            row_dst_base_q      <= {ADDR_W{1'b0}};
            row_bytes_q         <= {LEN_W{1'b0}};
            bytes_left_q        <= {LEN_W{1'b0}};
            rows_q              <= {ROW_W{1'b0}};
            row_index_q         <= {ROW_W{1'b0}};
            src_stride_q        <= {ADDR_W{1'b0}};
            dst_stride_q        <= {ADDR_W{1'b0}};
            tag_q               <= {TAG_W{1'b0}};
            read_data_q         <= {DATA_W{1'b0}};
            write_strb_q        <= {BYTE_LANES{1'b0}};
            done_o              <= 1'b0;
            error_o             <= 1'b0;
            done_tag_o          <= {TAG_W{1'b0}};
            perf_bytes_o        <= 32'd0;
            perf_desc_o         <= 32'd0;
            perf_stall_cycles_o <= 32'd0;
            for (i = 0; i < CMD_DEPTH; i = i + 1) begin
                fifo_src_q[i]        <= {ADDR_W{1'b0}};
                fifo_dst_q[i]        <= {ADDR_W{1'b0}};
                fifo_row_bytes_q[i]  <= {LEN_W{1'b0}};
                fifo_rows_q[i]       <= {ROW_W{1'b0}};
                fifo_src_stride_q[i] <= {ADDR_W{1'b0}};
                fifo_dst_stride_q[i] <= {ADDR_W{1'b0}};
                fifo_tag_q[i]        <= {TAG_W{1'b0}};
            end
        end else begin
            done_o  <= 1'b0;
            error_o <= 1'b0;

            case ({fifo_push, fifo_pop})
                2'b10: fifo_count_q <= fifo_count_q + 1'b1;
                2'b01: fifo_count_q <= fifo_count_q - 1'b1;
                default: fifo_count_q <= fifo_count_q;
            endcase

            if (fifo_push) begin
                fifo_src_q[fifo_wr_ptr_q]        <= cmd_src_addr_i;
                fifo_dst_q[fifo_wr_ptr_q]        <= cmd_dst_addr_i;
                fifo_row_bytes_q[fifo_wr_ptr_q]  <= cmd_row_bytes_i;
                fifo_rows_q[fifo_wr_ptr_q]       <= cmd_rows_i;
                fifo_src_stride_q[fifo_wr_ptr_q] <= cmd_src_stride_i;
                fifo_dst_stride_q[fifo_wr_ptr_q] <= cmd_dst_stride_i;
                fifo_tag_q[fifo_wr_ptr_q]        <= cmd_tag_i;
                fifo_wr_ptr_q                    <= ptr_inc(fifo_wr_ptr_q);
            end

            if (((state_q == S_RD_REQ) && !rd_req_ready_i) ||
                ((state_q == S_RD_RSP) && !rd_rsp_valid_i) ||
                ((state_q == S_WR_REQ) && !wr_req_ready_i) ||
                ((state_q == S_WR_RSP) && !wr_rsp_valid_i))
                perf_stall_cycles_o <= perf_stall_cycles_o + 1'b1;

            case (state_q)
                S_IDLE: begin
                    if (fifo_pop) begin
                        src_addr_q     <= fifo_src_q[fifo_rd_ptr_q];
                        dst_addr_q     <= fifo_dst_q[fifo_rd_ptr_q];
                        row_src_base_q <= fifo_src_q[fifo_rd_ptr_q];
                        row_dst_base_q <= fifo_dst_q[fifo_rd_ptr_q];
                        row_bytes_q    <= fifo_row_bytes_q[fifo_rd_ptr_q];
                        bytes_left_q   <= fifo_row_bytes_q[fifo_rd_ptr_q];
                        rows_q         <= fifo_rows_q[fifo_rd_ptr_q];
                        row_index_q    <= {ROW_W{1'b0}};
                        src_stride_q   <= fifo_src_stride_q[fifo_rd_ptr_q];
                        dst_stride_q   <= fifo_dst_stride_q[fifo_rd_ptr_q];
                        tag_q          <= fifo_tag_q[fifo_rd_ptr_q];
                        fifo_rd_ptr_q  <= ptr_inc(fifo_rd_ptr_q);
                        state_q        <= S_START;
                    end
                end

                S_START: begin
                    if ((row_bytes_q == 0) || (rows_q == 0)) begin
                        done_o       <= 1'b1;
                        error_o      <= 1'b1;
                        done_tag_o   <= tag_q;
                        perf_desc_o  <= perf_desc_o + 1'b1;
                        state_q      <= S_IDLE;
                    end else begin
                        state_q <= S_RD_REQ;
                    end
                end

                S_RD_REQ: begin
                    if (rd_req_ready_i)
                        state_q <= S_RD_RSP;
                end

                S_RD_RSP: begin
                    if (rd_rsp_valid_i) begin
                        if (rd_rsp_error_i) begin
                            done_o      <= 1'b1;
                            error_o     <= 1'b1;
                            done_tag_o  <= tag_q;
                            perf_desc_o <= perf_desc_o + 1'b1;
                            state_q     <= S_IDLE;
                        end else begin
                            read_data_q  <= rd_rsp_data_i;
                            write_strb_q <= byte_mask(bytes_left_q);
                            state_q      <= S_WR_REQ;
                        end
                    end
                end

                S_WR_REQ: begin
                    if (wr_req_ready_i)
                        state_q <= S_WR_RSP;
                end

                S_WR_RSP: begin
                    if (wr_rsp_valid_i) begin
                        if (wr_rsp_error_i) begin
                            done_o      <= 1'b1;
                            error_o     <= 1'b1;
                            done_tag_o  <= tag_q;
                            perf_desc_o <= perf_desc_o + 1'b1;
                            state_q     <= S_IDLE;
                        end else begin
                            if (bytes_left_q > BYTE_LANES)
                                perf_bytes_o <= perf_bytes_o + BYTE_LANES;
                            else
                                perf_bytes_o <= perf_bytes_o + bytes_left_q;

                            if (bytes_left_q <= BYTE_LANES) begin
                                if ((row_index_q + 1'b1) >= rows_q) begin
                                    done_o      <= 1'b1;
                                    done_tag_o  <= tag_q;
                                    perf_desc_o <= perf_desc_o + 1'b1;
                                    state_q     <= S_IDLE;
                                end else begin
                                    row_index_q    <= row_index_q + 1'b1;
                                    row_src_base_q <= row_src_base_q + src_stride_q;
                                    row_dst_base_q <= row_dst_base_q + dst_stride_q;
                                    src_addr_q     <= row_src_base_q + src_stride_q;
                                    dst_addr_q     <= row_dst_base_q + dst_stride_q;
                                    bytes_left_q   <= row_bytes_q;
                                    state_q        <= S_RD_REQ;
                                end
                            end else begin
                                src_addr_q   <= src_addr_q + BYTE_LANES;
                                dst_addr_q   <= dst_addr_q + BYTE_LANES;
                                bytes_left_q <= bytes_left_q - BYTE_LANES;
                                state_q      <= S_RD_REQ;
                            end
                        end
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((DATA_W % 8) != 0)
            $error("DATA_W must be byte-addressable");
        if (CMD_DEPTH < 2)
            $error("CMD_DEPTH must be at least two");
    end
`endif

endmodule

`default_nettype wire
