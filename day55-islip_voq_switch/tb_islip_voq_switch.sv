// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_islip_voq_switch;
    localparam integer PORTS = 4;
    localparam integer DATA_WIDTH = 32;
    localparam integer VOQ_DEPTH = 4;
    localparam integer PORT_W = 2;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic [PORTS-1:0] in_valid_i;
    wire  [PORTS-1:0] in_ready_o;
    logic [PORTS*DATA_WIDTH-1:0] in_data_i;
    logic [PORTS*PORT_W-1:0] in_dest_i;
    wire  [PORTS-1:0] out_valid_o;
    logic [PORTS-1:0] out_ready_i;
    wire  [PORTS*DATA_WIDTH-1:0] out_data_o;
    wire  [PORTS*PORT_W-1:0] out_src_o;

    logic [DATA_WIDTH-1:0] ref_mem [0:PORTS-1][0:PORTS-1][0:VOQ_DEPTH-1];
    integer ref_head [0:PORTS-1][0:PORTS-1];
    integer ref_tail [0:PORTS-1][0:PORTS-1];
    integer ref_count[0:PORTS-1][0:PORTS-1];
    integer ref_grant_ptr[0:PORTS-1];
    integer ref_accept_ptr[0:PORTS-1];
    logic [PORTS-1:0] exp_valid;
    logic [DATA_WIDTH-1:0] exp_data[0:PORTS-1];
    integer exp_src[0:PORTS-1];
    integer grant_sel[0:PORTS-1];
    integer match_in[0:PORTS-1];
    integer push[0:PORTS-1][0:PORTS-1];
    integer pop [0:PORTS-1][0:PORTS-1];
    integer checks = 0;
    integer transfers = 0;
    integer errors = 0;
    integer cycle = 0;
    integer seq = 0;
    integer i, o, k, c, d;

    islip_voq_switch #(
        .PORTS(PORTS), .DATA_WIDTH(DATA_WIDTH), .VOQ_DEPTH(VOQ_DEPTH)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input string message);
        begin
            $display("ERROR cycle %0d: %s", cycle, message);
            errors = errors + 1;
        end
    endtask

    task automatic init_model;
        integer a, b;
        begin
            exp_valid = '0;
            for (a = 0; a < PORTS; a = a + 1) begin
                exp_data[a] = '0;
                exp_src[a] = 0;
                ref_grant_ptr[a] = 0;
                ref_accept_ptr[a] = 0;
                for (b = 0; b < PORTS; b = b + 1) begin
                    ref_head[a][b] = 0;
                    ref_tail[a][b] = 0;
                    ref_count[a][b] = 0;
                end
            end
        end
    endtask

    task automatic model_step;
        integer a, b, n, cand, dest;
        integer accept_output[0:PORTS-1];
        begin
            for (a = 0; a < PORTS; a = a + 1) begin
                grant_sel[a] = -1;
                match_in[a] = -1;
                accept_output[a] = -1;
                for (b = 0; b < PORTS; b = b + 1) begin
                    push[a][b] = 0;
                    pop[a][b] = 0;
                end
            end

            for (a = 0; a < PORTS; a = a + 1) begin
                dest = in_dest_i[a*PORT_W +: PORT_W];
                if (in_valid_i[a] && (ref_count[a][dest] < VOQ_DEPTH))
                    push[a][dest] = 1;
            end

            for (b = 0; b < PORTS; b = b + 1) begin
                if (!exp_valid[b] || out_ready_i[b]) begin
                    for (n = PORTS; n > 0; n = n - 1) begin
                        cand = (ref_grant_ptr[b] + n - 1) % PORTS;
                        if (ref_count[cand][b] != 0)
                            grant_sel[b] = cand;
                    end
                end
            end

            for (a = 0; a < PORTS; a = a + 1) begin
                for (n = PORTS; n > 0; n = n - 1) begin
                    cand = (ref_accept_ptr[a] + n - 1) % PORTS;
                    if (grant_sel[cand] == a)
                        accept_output[a] = cand;
                end
                if (accept_output[a] >= 0)
                    match_in[accept_output[a]] = a;
            end

            for (b = 0; b < PORTS; b = b + 1) begin
                if (match_in[b] >= 0) begin
                    a = match_in[b];
                    exp_valid[b] = 1'b1;
                    exp_data[b] = ref_mem[a][b][ref_head[a][b]];
                    exp_src[b] = a;
                    pop[a][b] = 1;
                    ref_grant_ptr[b] = (a + 1) % PORTS;
                    ref_accept_ptr[a] = (b + 1) % PORTS;
                    transfers = transfers + 1;
                end else if (exp_valid[b] && out_ready_i[b]) begin
                    exp_valid[b] = 1'b0;
                end
            end

            for (a = 0; a < PORTS; a = a + 1) begin
                for (b = 0; b < PORTS; b = b + 1) begin
                    if (push[a][b]) begin
                        ref_mem[a][b][ref_tail[a][b]] =
                            in_data_i[a*DATA_WIDTH +: DATA_WIDTH];
                        ref_tail[a][b] = (ref_tail[a][b] + 1) % VOQ_DEPTH;
                    end
                    if (pop[a][b])
                        ref_head[a][b] = (ref_head[a][b] + 1) % VOQ_DEPTH;
                    ref_count[a][b] = ref_count[a][b] + push[a][b] - pop[a][b];
                    if ((ref_count[a][b] < 0) || (ref_count[a][b] > VOQ_DEPTH))
                        fail("reference VOQ count escaped legal range");
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n)
            init_model();
        else begin
            cycle = cycle + 1;
            model_step();
        end
    end

    always @(negedge clk) begin
        integer a, dest;
        if (!rst_n) begin
            checks = checks + 1;
            if (out_valid_o !== '0)
                fail("output valid was not cleared during reset");
        end else begin
            for (a = 0; a < PORTS; a = a + 1) begin
                checks = checks + 1;
                if (out_valid_o[a] !== exp_valid[a])
                    fail($sformatf("output %0d valid expected %0b got %0b",
                                   a, exp_valid[a], out_valid_o[a]));
                if (exp_valid[a]) begin
                    checks = checks + 2;
                    if (out_data_o[a*DATA_WIDTH +: DATA_WIDTH] !== exp_data[a])
                        fail($sformatf("output %0d data expected %08x got %08x",
                            a, exp_data[a], out_data_o[a*DATA_WIDTH +: DATA_WIDTH]));
                    if (out_src_o[a*PORT_W +: PORT_W] !== exp_src[a][PORT_W-1:0])
                        fail($sformatf("output %0d source mismatch", a));
                end
                dest = in_dest_i[a*PORT_W +: PORT_W];
                checks = checks + 1;
                if (in_ready_o[a] !== (ref_count[a][dest] < VOQ_DEPTH))
                    fail($sformatf("input %0d ready mismatch for destination %0d", a, dest));
            end
            if (errors > 20)
                $fatal(1, "too many errors");
        end
    end

    task automatic drive_cycle(input integer phase);
        integer a;
        begin
            @(negedge clk);
            #1;
            for (a = 0; a < PORTS; a = a + 1) begin
                if (phase == 0) begin
                    in_valid_i[a] = 1'b1;
                    in_dest_i[a*PORT_W +: PORT_W] = 0;
                    out_ready_i[a] = (a == 0) ? (cycle > 7) : 1'b1;
                end else begin
                    in_valid_i[a] = ($urandom_range(0, 99) < 72);
                    in_dest_i[a*PORT_W +: PORT_W] = $urandom_range(0, PORTS-1);
                    out_ready_i[a] = ($urandom_range(0, 99) < 68);
                end
                in_data_i[a*DATA_WIDTH +: DATA_WIDTH] =
                    {a[3:0], in_dest_i[a*PORT_W +: PORT_W], 10'h155, seq[15:0]};
                seq = seq + 1;
            end
        end
    endtask

    function automatic integer model_empty;
        integer a, b;
        begin
            model_empty = (exp_valid == '0);
            for (a = 0; a < PORTS; a = a + 1)
                for (b = 0; b < PORTS; b = b + 1)
                    if (ref_count[a][b] != 0)
                        model_empty = 0;
        end
    endfunction

    initial begin
        $dumpfile("islip_voq_switch.vcd");
        $dumpvars(0, tb_islip_voq_switch);
        in_valid_i = '0;
        in_data_i = '0;
        in_dest_i = '0;
        out_ready_i = '0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // Directed hotspot traffic fills four VOQs while output 0 is stalled.
        repeat (18) drive_cycle(0);
        // Random traffic exercises independent destinations and backpressure.
        repeat (700) drive_cycle(1);

        @(negedge clk);
        in_valid_i = '0;
        out_ready_i = '1;
        c = 0;
        while (!model_empty() && c < 300) begin
            @(negedge clk);
            c = c + 1;
        end
        repeat (3) @(negedge clk);

        if (!model_empty())
            fail("drain timeout");
        if (transfers < 500)
            fail("insufficient accepted transfers");

        if (errors == 0) begin
            $display("Validated %0d scheduled transfers with %0d checks", transfers, checks);
            $display("RESULT: *** PASS ***");
            $finish;
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
    end

    initial begin
        #200000;
        $fatal(1, "global timeout");
    end

endmodule
