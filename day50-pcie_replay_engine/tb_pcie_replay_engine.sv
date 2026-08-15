// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_pcie_replay_engine;
    localparam integer DATA_W = 32;
    localparam integer SEQ_W = 4;
    localparam integer DEPTH = 8;
    localparam integer TIMEOUT = 10;
    localparam integer COUNT_W = $clog2(DEPTH + 1);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic s_valid, s_ready;
    logic [DATA_W-1:0] s_data;
    logic tx_valid, tx_ready, tx_replay;
    logic [DATA_W-1:0] tx_data;
    logic [SEQ_W-1:0] tx_seq;
    logic ack_valid, nak_valid;
    logic [SEQ_W-1:0] ack_seq, nak_seq;
    logic [COUNT_W-1:0] outstanding;
    logic replay_active, timeout_pulse;

    logic [DATA_W-1:0] model_data [0:127];
    logic [SEQ_W-1:0] model_seq [0:127];
    integer model_count = 0;
    integer model_next_seq = 0;
    integer tests = 0;
    integer seed = 32'h50c0ffee;

    always #5 clk = ~clk;

    pcie_replay_engine #(
        .DATA_W(DATA_W),
        .SEQ_W(SEQ_W),
        .REPLAY_DEPTH(DEPTH),
        .TIMEOUT_CYCLES(TIMEOUT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .s_valid_i(s_valid), .s_ready_o(s_ready), .s_data_i(s_data),
        .tx_valid_o(tx_valid), .tx_ready_i(tx_ready),
        .tx_data_o(tx_data), .tx_seq_o(tx_seq), .tx_replay_o(tx_replay),
        .ack_valid_i(ack_valid), .ack_seq_i(ack_seq),
        .nak_valid_i(nak_valid), .nak_seq_i(nak_seq),
        .outstanding_o(outstanding), .replay_active_o(replay_active),
        .timeout_replay_pulse_o(timeout_pulse)
    );

    task automatic fail(input string message);
        begin
            $display("ERROR: %s at time %0t", message, $time);
            $display("RESULT: *** FAIL ***");
            $finish;
        end
    endtask

    task automatic check_count;
        begin
            if (outstanding !== model_count[COUNT_W-1:0])
                fail($sformatf("outstanding=%0d expected=%0d", outstanding,
                               model_count));
        end
    endtask

    task automatic send_tlp(input logic [DATA_W-1:0] payload);
        begin
            @(negedge clk);
            tx_ready = 1'b1;
            s_valid = 1'b1;
            s_data = payload;
            while (!s_ready)
                @(negedge clk);
            #1;
            if (!tx_valid || tx_replay || tx_data !== payload ||
                tx_seq !== model_next_seq[SEQ_W-1:0])
                fail("new-transmit channel mismatch");
            @(posedge clk);
            #1;
            model_data[model_count] = payload;
            model_seq[model_count] = model_next_seq[SEQ_W-1:0];
            model_count = model_count + 1;
            model_next_seq = (model_next_seq + 1) & ((1 << SEQ_W)-1);
            check_count();
            @(negedge clk);
            s_valid = 1'b0;
            tests = tests + 1;
        end
    endtask

    task automatic acknowledge(input integer last_index);
        integer free_count;
        integer j;
        begin
            if ((last_index < 0) || (last_index >= model_count))
                fail("testbench requested invalid cumulative ACK");
            free_count = last_index + 1;
            @(negedge clk);
            ack_valid = 1'b1;
            ack_seq = model_seq[last_index];
            @(posedge clk);
            #1;
            for (j = free_count; j < model_count; j = j + 1) begin
                model_data[j-free_count] = model_data[j];
                model_seq[j-free_count] = model_seq[j];
            end
            model_count = model_count - free_count;
            check_count();
            if (replay_active)
                fail("ACK did not terminate an active replay");
            @(negedge clk);
            ack_valid = 1'b0;
            tests = tests + 1;
        end
    endtask

    task automatic ack_and_send(input logic [DATA_W-1:0] payload);
        integer j;
        begin
            if (model_count != DEPTH)
                fail("simultaneous ACK/send test requires a full window");
            @(negedge clk);
            tx_ready = 1'b1;
            ack_valid = 1'b1;
            ack_seq = model_seq[0];
            s_valid = 1'b1;
            s_data = payload;
            #1;
            if (!s_ready || !tx_valid || tx_replay || tx_data !== payload ||
                tx_seq !== model_next_seq[SEQ_W-1:0])
                fail("full-window simultaneous ACK/send mismatch");
            @(posedge clk);
            #1;
            for (j = 1; j < model_count; j = j + 1) begin
                model_data[j-1] = model_data[j];
                model_seq[j-1] = model_seq[j];
            end
            model_data[model_count-1] = payload;
            model_seq[model_count-1] = model_next_seq[SEQ_W-1:0];
            model_next_seq = (model_next_seq + 1) & ((1 << SEQ_W)-1);
            check_count();
            @(negedge clk);
            ack_valid = 1'b0;
            s_valid = 1'b0;
            tests = tests + 1;
        end
    endtask

    task automatic consume_replay(input integer first_index);
        integer j;
        logic [DATA_W-1:0] held_data;
        logic [SEQ_W-1:0] held_seq;
        begin
            tx_ready = 1'b0;
            #1;
            if (!tx_valid || !tx_replay)
                fail("replay did not assert valid while backpressured");
            held_data = tx_data;
            held_seq = tx_seq;
            repeat (2) begin
                @(posedge clk);
                #1;
                if (!tx_valid || tx_data !== held_data || tx_seq !== held_seq)
                    fail("replay payload changed under backpressure");
            end
            for (j = first_index; j < model_count; j = j + 1) begin
                @(negedge clk);
                tx_ready = 1'b1;
                #1;
                if (!tx_valid || !tx_replay || tx_data !== model_data[j] ||
                    tx_seq !== model_seq[j])
                    fail($sformatf("replay mismatch at model index %0d", j));
                @(posedge clk);
                #1;
            end
            if (replay_active)
                fail("replay remained active after final entry");
            check_count();
            tests = tests + 1;
        end
    endtask

    task automatic request_nak(input integer first_index);
        begin
            if ((first_index < 0) || (first_index >= model_count))
                fail("testbench requested invalid NAK");
            @(negedge clk);
            tx_ready = 1'b0;
            nak_valid = 1'b1;
            nak_seq = model_seq[first_index];
            @(posedge clk);
            #1;
            if (!replay_active)
                fail("valid NAK did not start replay");
            @(negedge clk);
            nak_valid = 1'b0;
            consume_replay(first_index);
        end
    endtask

    task automatic wait_for_timeout_replay;
        integer cycles;
        begin
            @(negedge clk);
            tx_ready = 1'b0;
            cycles = 0;
            while (!timeout_pulse && cycles < TIMEOUT + 4) begin
                @(posedge clk);
                #1;
                cycles = cycles + 1;
            end
            if (!timeout_pulse || !replay_active)
                fail("replay timeout did not fire");
            consume_replay(0);
        end
    endtask

    integer i;
    integer action;
    integer index;
    initial begin
        $dumpfile("pcie_replay_engine.vcd");
        $dumpvars(0, tb_pcie_replay_engine);
        s_valid = 1'b0;
        s_data = '0;
        tx_ready = 1'b1;
        ack_valid = 1'b0;
        ack_seq = '0;
        nak_valid = 1'b0;
        nak_seq = '0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        check_count();

        // Directed: cumulative ACK retirement and sequence preservation.
        send_tlp(32'h1000_0001);
        send_tlp(32'h1000_0002);
        send_tlp(32'h1000_0003);
        acknowledge(1);

        // Directed: NAK replays from the requested sequence, not the head.
        send_tlp(32'h2000_0004);
        send_tlp(32'h2000_0005);
        request_nak(1);
        acknowledge(model_count-1);

        // Directed: a missing ACK triggers a full replay from the oldest entry.
        send_tlp(32'h3000_0006);
        send_tlp(32'h3000_0007);
        wait_for_timeout_replay();
        acknowledge(model_count-1);

        // Directed: a full window accepts new traffic when an ACK frees its head.
        for (i = 0; i < DEPTH; i = i + 1)
            send_tlp(32'h4000_0000 + i);
        ack_and_send(32'h4000_00ff);
        acknowledge(model_count-1);

        // Randomized traffic also drives the four-bit sequence number through wrap.
        for (i = 0; i < 48; i = i + 1) begin
            action = $urandom(seed) % 100;
            if ((model_count == 0) || ((action < 58) && (model_count < DEPTH-1))) begin
                send_tlp($urandom(seed));
            end else if (action < 83) begin
                index = $urandom(seed) % model_count;
                acknowledge(index);
            end else begin
                index = $urandom(seed) % model_count;
                request_nak(index);
            end
        end
        if (model_count != 0)
            acknowledge(model_count-1);

        repeat (3) @(posedge clk);
        check_count();
        $display("Checks completed: %0d", tests);
        $display("RESULT: *** PASS ***");
        $finish;
    end

    initial begin
        #200000;
        fail("global timeout");
    end
endmodule
