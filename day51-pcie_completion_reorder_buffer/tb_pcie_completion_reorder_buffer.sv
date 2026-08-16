// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_pcie_completion_reorder_buffer;
    localparam integer DATA_W = 32;
    localparam integer TAG_W = 4;
    localparam integer DEPTH = 8;
    localparam integer MAX_BEATS = 4;
    localparam integer COUNT_W = $clog2(DEPTH + 1);
    localparam integer BEAT_W = $clog2(MAX_BEATS);
    localparam integer LEN_W = $clog2(MAX_BEATS + 1);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic issue_valid, issue_ready;
    logic [TAG_W-1:0] issue_tag;
    logic [LEN_W-1:0] issue_beats;
    logic cpl_valid, cpl_ready;
    logic [TAG_W-1:0] cpl_tag;
    logic [BEAT_W-1:0] cpl_beat;
    logic [DATA_W-1:0] cpl_data;
    logic cpl_error;
    logic retire_valid, retire_ready, retire_last, retire_error;
    logic [TAG_W-1:0] retire_tag;
    logic [BEAT_W-1:0] retire_beat;
    logic [DATA_W-1:0] retire_data;
    logic [COUNT_W-1:0] outstanding;
    logic protocol_error;

    logic [DATA_W-1:0] model_data [0:15][0:MAX_BEATS-1];
    integer model_beats [0:15];
    logic model_error [0:15];
    integer issued_count = 0;
    integer retired_count = 0;
    integer checks = 0;
    integer seed = 32'h51c0ffee;
    integer i, j, r, len, tag, beat;

    always #5 clk = ~clk;

    pcie_completion_reorder_buffer #(
        .DATA_W(DATA_W), .TAG_W(TAG_W),
        .MAX_OUTSTANDING(DEPTH), .MAX_BEATS(MAX_BEATS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .issue_valid_i(issue_valid), .issue_ready_o(issue_ready),
        .issue_tag_i(issue_tag), .issue_beats_i(issue_beats),
        .cpl_valid_i(cpl_valid), .cpl_ready_o(cpl_ready),
        .cpl_tag_i(cpl_tag), .cpl_beat_i(cpl_beat),
        .cpl_data_i(cpl_data), .cpl_error_i(cpl_error),
        .retire_valid_o(retire_valid), .retire_ready_i(retire_ready),
        .retire_tag_o(retire_tag), .retire_beat_o(retire_beat),
        .retire_data_o(retire_data), .retire_last_o(retire_last),
        .retire_error_o(retire_error), .outstanding_o(outstanding),
        .protocol_error_pulse_o(protocol_error)
    );

    task automatic fail(input string message);
        begin
            $display("ERROR: %s at time %0t", message, $time);
            $display("RESULT: *** FAIL ***");
            $finish;
        end
    endtask

    task automatic issue_request(input integer t, input integer beats_n,
                                 input logic err_expected);
        begin
            @(negedge clk);
            issue_tag = t[TAG_W-1:0];
            issue_beats = beats_n[LEN_W-1:0];
            issue_valid = 1'b1;
            #1;
            if (!issue_ready)
                fail($sformatf("tag %0d unexpectedly rejected", t));
            @(posedge clk);
            #1;
            model_beats[t] = beats_n;
            model_error[t] = err_expected;
            issued_count = issued_count + 1;
            if (outstanding !== (issued_count-retired_count))
                fail("outstanding count mismatch after issue");
            @(negedge clk);
            issue_valid = 1'b0;
            checks = checks + 1;
        end
    endtask

    task automatic send_fragment(input integer t, input integer b,
                                 input logic [DATA_W-1:0] data,
                                 input logic err);
        begin
            @(negedge clk);
            cpl_tag = t[TAG_W-1:0];
            cpl_beat = b[BEAT_W-1:0];
            cpl_data = data;
            cpl_error = err;
            cpl_valid = 1'b1;
            #1;
            if (!cpl_ready)
                fail("completion ingress backpressured unexpectedly");
            @(posedge clk);
            #1;
            @(negedge clk);
            cpl_valid = 1'b0;
            checks = checks + 1;
        end
    endtask

    task automatic expect_protocol_error(input integer t, input integer b,
                                         input logic [DATA_W-1:0] data);
        begin
            @(negedge clk);
            cpl_tag = t[TAG_W-1:0];
            cpl_beat = b[BEAT_W-1:0];
            cpl_data = data;
            cpl_error = 1'b0;
            cpl_valid = 1'b1;
            @(posedge clk);
            #1;
            if (!protocol_error)
                fail("malformed completion did not raise protocol error");
            @(negedge clk);
            cpl_valid = 1'b0;
            checks = checks + 1;
        end
    endtask

    task automatic drain_request(input integer t);
        logic [DATA_W-1:0] held_data;
        logic [BEAT_W-1:0] held_beat;
        begin
            for (j = 0; j < model_beats[t]; j = j + 1) begin
                @(negedge clk);
                retire_ready = 1'b0;
                #1;
                if (!retire_valid || retire_tag !== t[TAG_W-1:0] ||
                    retire_beat !== j[BEAT_W-1:0] ||
                    retire_data !== model_data[t][j] ||
                    retire_last !== (j == model_beats[t]-1) ||
                    retire_error !== model_error[t])
                    fail($sformatf("retire mismatch tag=%0d beat=%0d", t, j));
                held_data = retire_data;
                held_beat = retire_beat;
                repeat (($urandom(seed) % 2) + 1) begin
                    @(posedge clk);
                    #1;
                    if (!retire_valid || retire_data !== held_data ||
                        retire_beat !== held_beat)
                        fail("retire output changed under backpressure");
                end
                @(negedge clk);
                retire_ready = 1'b1;
                @(posedge clk);
                #1;
                checks = checks + 1;
            end
            retired_count = retired_count + 1;
            if (outstanding !== (issued_count-retired_count))
                fail("outstanding count mismatch after retirement");
            @(negedge clk);
            retire_ready = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("pcie_completion_reorder_buffer.vcd");
        $dumpvars(0, tb_pcie_completion_reorder_buffer);
        issue_valid = 1'b0;
        issue_tag = '0;
        issue_beats = '0;
        cpl_valid = 1'b0;
        cpl_tag = '0;
        cpl_beat = '0;
        cpl_data = '0;
        cpl_error = 1'b0;
        retire_ready = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        if (outstanding != 0 || retire_valid)
            fail("reset state is not empty");

        // Directed: later tags complete first, but the head still blocks retire.
        issue_request(1, 3, 1'b0);
        issue_request(2, 2, 1'b1);
        issue_request(3, 4, 1'b0);
        model_data[1][0] = 32'h1111_0000;
        model_data[1][1] = 32'h1111_0001;
        model_data[1][2] = 32'h1111_0002;
        model_data[2][0] = 32'h2222_0000;
        model_data[2][1] = 32'h2222_0001;
        for (i = 0; i < 4; i = i + 1)
            model_data[3][i] = 32'h3333_0000 + i;

        send_fragment(2, 1, model_data[2][1], 1'b1);
        send_fragment(2, 0, model_data[2][0], 1'b0);
        for (i = 3; i >= 0; i = i - 1)
            send_fragment(3, i, model_data[3][i], 1'b0);
        if (retire_valid)
            fail("younger completed tag bypassed incomplete head");
        send_fragment(1, 2, model_data[1][2], 1'b0);
        send_fragment(1, 0, model_data[1][0], 1'b0);
        send_fragment(1, 1, model_data[1][1], 1'b0);

        // Directed protocol checks: duplicate, inactive tag, and out-of-range beat.
        expect_protocol_error(1, 1, 32'hdead_0001);
        expect_protocol_error(9, 0, 32'hdead_0002);
        expect_protocol_error(2, 3, 32'hdead_0003);
        drain_request(1);
        drain_request(2);
        drain_request(3);

        // Randomized batches complete in reverse tag order and reverse beat order.
        for (r = 0; r < 8; r = r + 1) begin
            for (i = 0; i < 4; i = i + 1) begin
                tag = ((r * 4 + i) % 15) + 1;
                len = ($urandom(seed) % MAX_BEATS) + 1;
                issue_request(tag, len, ((r == 3) && (i == 2)));
                for (j = 0; j < len; j = j + 1)
                    model_data[tag][j] = $urandom(seed);
            end
            for (i = 3; i >= 0; i = i - 1) begin
                tag = ((r * 4 + i) % 15) + 1;
                for (j = model_beats[tag]-1; j >= 0; j = j - 1)
                    send_fragment(tag, j, model_data[tag][j],
                                  model_error[tag] && (j == 0));
            end
            for (i = 0; i < 4; i = i + 1) begin
                tag = ((r * 4 + i) % 15) + 1;
                drain_request(tag);
            end
        end

        repeat (3) @(posedge clk);
        if (outstanding != 0 || retire_valid)
            fail("final state is not empty");
        $display("Checks completed: %0d", checks);
        $display("RESULT: *** PASS ***");
        $finish;
    end

    initial begin
        #300000;
        fail("global timeout");
    end
endmodule
