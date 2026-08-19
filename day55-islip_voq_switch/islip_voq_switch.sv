// Author: Asresh Kuricheti
`timescale 1ns/1ps

module islip_voq_switch #(
    parameter integer PORTS      = 4,
    parameter integer DATA_WIDTH = 32,
    parameter integer VOQ_DEPTH  = 4,
    parameter integer PORT_W     = (PORTS <= 1) ? 1 : $clog2(PORTS),
    parameter integer PTR_W      = (VOQ_DEPTH <= 1) ? 1 : $clog2(VOQ_DEPTH),
    parameter integer COUNT_W    = $clog2(VOQ_DEPTH + 1)
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire [PORTS-1:0]              in_valid_i,
    output logic [PORTS-1:0]             in_ready_o,
    input  wire [PORTS*DATA_WIDTH-1:0]   in_data_i,
    input  wire [PORTS*PORT_W-1:0]       in_dest_i,
    output logic [PORTS-1:0]             out_valid_o,
    input  wire [PORTS-1:0]              out_ready_i,
    output logic [PORTS*DATA_WIDTH-1:0]  out_data_o,
    output logic [PORTS*PORT_W-1:0]      out_src_o
);

    logic [DATA_WIDTH-1:0] voq_mem [0:PORTS-1][0:PORTS-1][0:VOQ_DEPTH-1];
    logic [PTR_W-1:0]      head_q  [0:PORTS-1][0:PORTS-1];
    logic [PTR_W-1:0]      tail_q  [0:PORTS-1][0:PORTS-1];
    logic [COUNT_W-1:0]    count_q [0:PORTS-1][0:PORTS-1];

    logic [PORT_W-1:0] grant_ptr_q  [0:PORTS-1];
    logic [PORT_W-1:0] accept_ptr_q [0:PORTS-1];
    logic [DATA_WIDTH-1:0] out_data_q [0:PORTS-1];
    logic [PORT_W-1:0]     out_src_q  [0:PORTS-1];
    logic [PORTS-1:0]      out_valid_q;

    logic [PORTS-1:0] grant_to_input [0:PORTS-1];
    logic [PORTS-1:0] match_output   [0:PORTS-1];
    logic [PORTS-1:0] pop_voq        [0:PORTS-1];
    logic [PORTS-1:0] push_voq       [0:PORTS-1];
    logic [PORTS-1:0] output_load;

    integer i, o, k, j;
    integer candidate;
    integer dest_int;

    function automatic [PTR_W-1:0] ptr_inc(input [PTR_W-1:0] ptr);
        begin
            if (ptr == VOQ_DEPTH-1)
                ptr_inc = '0;
            else
                ptr_inc = ptr + 1'b1;
        end
    endfunction

    function automatic [PORT_W-1:0] port_inc(input [PORT_W-1:0] ptr);
        begin
            if (ptr == PORTS-1)
                port_inc = '0;
            else
                port_inc = ptr + 1'b1;
        end
    endfunction

    always_comb begin
        for (i = 0; i < PORTS; i = i + 1) begin
            dest_int = in_dest_i[i*PORT_W +: PORT_W];
            if (dest_int < PORTS)
                in_ready_o[i] = (count_q[i][dest_int] < VOQ_DEPTH);
            else
                in_ready_o[i] = 1'b0;
            out_valid_o[i] = out_valid_q[i];
            out_data_o[i*DATA_WIDTH +: DATA_WIDTH] = out_data_q[i];
            out_src_o[i*PORT_W +: PORT_W] = out_src_q[i];
        end
    end

    always_comb begin
        for (o = 0; o < PORTS; o = o + 1) begin
            grant_to_input[o] = '0;
            match_output[o] = '0;
            pop_voq[o] = '0;
            push_voq[o] = '0;
            output_load[o] = 1'b0;
        end

        for (i = 0; i < PORTS; i = i + 1) begin
            dest_int = in_dest_i[i*PORT_W +: PORT_W];
            if (in_valid_i[i] && in_ready_o[i])
                push_voq[i][dest_int] = 1'b1;
        end

        // Grant phase: each available output selects one requesting input.
        for (o = 0; o < PORTS; o = o + 1) begin
            if (!out_valid_q[o] || out_ready_i[o]) begin
                for (k = PORTS; k > 0; k = k - 1) begin
                    candidate = grant_ptr_q[o] + k - 1;
                    if (candidate >= PORTS)
                        candidate = candidate - PORTS;
                    if (count_q[candidate][o] != 0)
                        grant_to_input[o] = {{(PORTS-1){1'b0}}, 1'b1} << candidate;
                end
            end
        end

        // Accept phase: each input accepts at most one output grant.
        for (i = 0; i < PORTS; i = i + 1) begin
            for (k = PORTS; k > 0; k = k - 1) begin
                candidate = accept_ptr_q[i] + k - 1;
                if (candidate >= PORTS)
                    candidate = candidate - PORTS;
                if (grant_to_input[candidate][i]) begin
                    for (j = 0; j < PORTS; j = j + 1)
                        match_output[j][i] = 1'b0;
                    match_output[candidate][i] = 1'b1;
                end
            end
        end

        for (o = 0; o < PORTS; o = o + 1) begin
            for (i = 0; i < PORTS; i = i + 1) begin
                if (match_output[o][i]) begin
                    output_load[o] = 1'b1;
                    pop_voq[i][o] = 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid_q <= '0;
            for (i = 0; i < PORTS; i = i + 1) begin
                grant_ptr_q[i] <= '0;
                accept_ptr_q[i] <= '0;
                out_data_q[i] <= '0;
                out_src_q[i] <= '0;
                for (o = 0; o < PORTS; o = o + 1) begin
                    head_q[i][o] <= '0;
                    tail_q[i][o] <= '0;
                    count_q[i][o] <= '0;
                end
            end
        end else begin
            for (o = 0; o < PORTS; o = o + 1) begin
                if (output_load[o]) begin
                    out_valid_q[o] <= 1'b1;
                    for (i = 0; i < PORTS; i = i + 1) begin
                        if (match_output[o][i]) begin
                            out_data_q[o] <= voq_mem[i][o][head_q[i][o]];
                            out_src_q[o] <= i[PORT_W-1:0];
                            grant_ptr_q[o] <= port_inc(i[PORT_W-1:0]);
                            accept_ptr_q[i] <= port_inc(o[PORT_W-1:0]);
                        end
                    end
                end else if (out_valid_q[o] && out_ready_i[o]) begin
                    out_valid_q[o] <= 1'b0;
                end
            end

            for (i = 0; i < PORTS; i = i + 1) begin
                for (o = 0; o < PORTS; o = o + 1) begin
                    case ({push_voq[i][o], pop_voq[i][o]})
                        2'b10: begin
                            voq_mem[i][o][tail_q[i][o]] <=
                                in_data_i[i*DATA_WIDTH +: DATA_WIDTH];
                            tail_q[i][o] <= ptr_inc(tail_q[i][o]);
                            count_q[i][o] <= count_q[i][o] + 1'b1;
                        end
                        2'b01: begin
                            head_q[i][o] <= ptr_inc(head_q[i][o]);
                            count_q[i][o] <= count_q[i][o] - 1'b1;
                        end
                        2'b11: begin
                            voq_mem[i][o][tail_q[i][o]] <=
                                in_data_i[i*DATA_WIDTH +: DATA_WIDTH];
                            tail_q[i][o] <= ptr_inc(tail_q[i][o]);
                            head_q[i][o] <= ptr_inc(head_q[i][o]);
                        end
                        default: begin end
                    endcase
                end
            end
        end
    end

endmodule
