// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_axi_read_reorder_buffer;
    localparam integer DATA_W = 32;
    localparam integer ID_W = 2;
    localparam integer SLOTS = 8;
    localparam integer MAX_BEATS = 4;
    localparam integer SLOT_W = $clog2(SLOTS);
    localparam integer BEAT_W = $clog2(MAX_BEATS);
    localparam integer LEN_W = $clog2(MAX_BEATS + 1);
    localparam integer IDS = (1 << ID_W);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic alloc_valid_i;
    wire alloc_ready_o;
    logic [ID_W-1:0] alloc_id_i;
    logic [LEN_W-1:0] alloc_beats_i;
    wire [SLOT_W-1:0] alloc_slot_o;
    logic fill_valid_i;
    wire fill_ready_o;
    logic [SLOT_W-1:0] fill_slot_i;
    logic [BEAT_W-1:0] fill_beat_i;
    logic [DATA_W-1:0] fill_data_i;
    logic [1:0] fill_resp_i;
    logic fill_last_i;
    wire rvalid_o;
    logic rready_i;
    wire [ID_W-1:0] rid_o;
    wire [DATA_W-1:0] rdata_o;
    wire [1:0] rresp_o;
    wire rlast_o;
    wire [$clog2(SLOTS+1)-1:0] outstanding_o;
    wire protocol_error_pulse_o;

    integer checks = 0;
    integer errors = 0;
    integer protocol_pulses = 0;
    integer seed = 32'h52a11d;
    integer id_head [0:IDS-1];
    integer id_tail [0:IDS-1];
    integer id_queue [0:IDS-1][0:127];
    integer model_len [0:SLOTS-1];
    integer model_id [0:SLOTS-1];
    integer model_beat [0:IDS-1];
    logic [DATA_W-1:0] model_data [0:SLOTS-1][0:MAX_BEATS-1];
    logic [1:0] model_resp [0:SLOTS-1][0:MAX_BEATS-1];
    logic [SLOT_W-1:0] tags [0:SLOTS-1];
    integer i, j, k, batch, request_count, completed_count;
    integer expected_slot;
    logic stalled;
    logic [ID_W-1:0] held_id;
    logic [DATA_W-1:0] held_data;
    logic [1:0] held_resp;
    logic held_last;

    always #5 clk = ~clk;

    axi_read_reorder_buffer #(
        .DATA_W(DATA_W), .ID_W(ID_W), .SLOTS(SLOTS),
        .MAX_BEATS(MAX_BEATS), .SEQ_W(4)
    ) dut (.*);

    task automatic fail(input string message);
        begin
            errors = errors + 1;
            $display("ERROR @ %0t: %s", $time, message);
        end
    endtask

    task automatic allocate_request(
        input integer id_value,
        input integer beats_value,
        output logic [SLOT_W-1:0] slot_value
    );
        begin
            @(negedge clk);
            alloc_valid_i = 1'b1;
            alloc_id_i = id_value[ID_W-1:0];
            alloc_beats_i = beats_value[LEN_W-1:0];
            do @(posedge clk); while (!alloc_ready_o);
            slot_value = alloc_slot_o;
            #1 alloc_valid_i = 1'b0;
            model_id[slot_value] = id_value;
            model_len[slot_value] = beats_value;
            id_queue[id_value][id_tail[id_value]] = slot_value;
            id_tail[id_value] = id_tail[id_value] + 1;
            for (j = 0; j < beats_value; j = j + 1) begin
                model_data[slot_value][j] = {8'h52, slot_value, j[BEAT_W-1:0], 19'(batch * 97 + k * 11 + j)};
                model_resp[slot_value][j] = ((batch + k + j) % 13 == 0) ? 2'b10 : 2'b00;
            end
        end
    endtask

    task automatic fill_beat(input integer slot_value, input integer beat_value);
        begin
            @(negedge clk);
            fill_valid_i = 1'b1;
            fill_slot_i = slot_value[SLOT_W-1:0];
            fill_beat_i = beat_value[BEAT_W-1:0];
            fill_data_i = model_data[slot_value][beat_value];
            fill_resp_i = model_resp[slot_value][beat_value];
            fill_last_i = (beat_value == model_len[slot_value] - 1);
            @(posedge clk);
            #1 fill_valid_i = 1'b0;
        end
    endtask

    task automatic send_bad_fill(
        input integer slot_value,
        input integer beat_value,
        input logic last_value
    );
        begin
            @(negedge clk);
            fill_valid_i = 1'b1;
            fill_slot_i = slot_value[SLOT_W-1:0];
            fill_beat_i = beat_value[BEAT_W-1:0];
            fill_data_i = 32'hbad0_0000 | beat_value;
            fill_resp_i = 2'b00;
            fill_last_i = last_value;
            @(posedge clk);
            #1 fill_valid_i = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (protocol_error_pulse_o)
            protocol_pulses = protocol_pulses + 1;

        if (!rst_n) begin
            stalled <= 1'b0;
        end else begin
            if (stalled) begin
                checks = checks + 1;
                if (!rvalid_o || rid_o !== held_id || rdata_o !== held_data ||
                    rresp_o !== held_resp || rlast_o !== held_last)
                    fail("R channel changed while stalled");
            end
            stalled <= rvalid_o && !rready_i;
            if (rvalid_o && !rready_i) begin
                held_id <= rid_o;
                held_data <= rdata_o;
                held_resp <= rresp_o;
                held_last <= rlast_o;
            end

            if (rvalid_o && rready_i) begin
                checks = checks + 5;
                if (id_head[rid_o] >= id_tail[rid_o]) begin
                    fail("response appeared for an ID with no queued request");
                end else begin
                    expected_slot = id_queue[rid_o][id_head[rid_o]];
                    if (rid_o !== model_id[expected_slot][ID_W-1:0]) fail("RID mismatch");
                    if (rdata_o !== model_data[expected_slot][model_beat[rid_o]]) fail("RDATA mismatch");
                    if (rresp_o !== model_resp[expected_slot][model_beat[rid_o]]) fail("RRESP mismatch");
                    if (rlast_o !== (model_beat[rid_o] == model_len[expected_slot]-1)) fail("RLAST mismatch");
                    if (rlast_o) begin
                        id_head[rid_o] = id_head[rid_o] + 1;
                        model_beat[rid_o] = 0;
                        completed_count = completed_count + 1;
                    end else begin
                        model_beat[rid_o] = model_beat[rid_o] + 1;
                    end
                end
            end
        end
    end

    always @(negedge clk) begin
        if (rst_n)
            rready_i <= (($urandom(seed) % 4) != 0);
    end

    initial begin
        $dumpfile("axi_read_reorder_buffer.vcd");
        $dumpvars(0, tb_axi_read_reorder_buffer);
        alloc_valid_i = 0;
        alloc_id_i = 0;
        alloc_beats_i = 0;
        fill_valid_i = 0;
        fill_slot_i = 0;
        fill_beat_i = 0;
        fill_data_i = 0;
        fill_resp_i = 0;
        fill_last_i = 0;
        rready_i = 0;
        completed_count = 0;
        batch = 0;
        k = 0;
        for (i = 0; i < IDS; i = i + 1) begin
            id_head[i] = 0;
            id_tail[i] = 0;
            model_beat[i] = 0;
        end

        repeat (4) @(negedge clk);
        rst_n = 1;
        rready_i = 1;

        // Directed: two requests share ID 1; a younger completion must wait.
        allocate_request(1, 3, tags[0]);
        k = 1;
        allocate_request(1, 2, tags[1]);
        k = 2;
        allocate_request(2, 4, tags[2]);
        fill_beat(tags[1], 1);
        fill_beat(tags[1], 0);
        fill_beat(tags[2], 3);
        fill_beat(tags[2], 1);
        fill_beat(tags[2], 2);
        fill_beat(tags[2], 0);
        repeat (4) @(negedge clk);
        checks = checks + 1;
        if (id_head[1] != 0) fail("younger same-ID request bypassed the older request");
        fill_beat(tags[0], 2);
        fill_beat(tags[0], 0);
        fill_beat(tags[0], 1);

        wait (completed_count == 3);
        $display("Directed ordering scenario completed @ %0t", $time);
        repeat (2) @(negedge clk);

        // Malformed traffic: inactive slot and wrong LAST must pulse an error.
        send_bad_fill(tags[0], 0, 1'b0);
        k = 3;
        allocate_request(3, 2, tags[3]);
        send_bad_fill(tags[3], 0, 1'b1);
        fill_beat(tags[3], 1);
        fill_beat(tags[3], 0);
        wait (completed_count == 4);
        $display("Protocol-error scenario completed @ %0t", $time);
        checks = checks + 1;
        if (protocol_pulses != 2) fail("expected exactly two protocol-error pulses");

        // Randomized batches vary IDs, lengths, beat order, response codes, and backpressure.
        for (batch = 1; batch <= 10; batch = batch + 1) begin
            request_count = 4 + ($urandom(seed) % 4);
            for (k = 0; k < request_count; k = k + 1)
                allocate_request($urandom(seed) % IDS,
                                 1 + ($urandom(seed) % MAX_BEATS), tags[k]);

            for (k = request_count-1; k >= 0; k = k - 1) begin
                if (($urandom(seed) & 1) != 0) begin
                    for (j = model_len[tags[k]]-1; j >= 0; j = j - 1)
                        fill_beat(tags[k], j);
                end else begin
                    for (j = 0; j < model_len[tags[k]]; j = j + 1)
                        fill_beat(tags[k], j);
                end
            end
            wait (outstanding_o == 0);
            $display("Random batch %0d completed @ %0t", batch, $time);
            repeat (2) @(negedge clk);
        end

        checks = checks + 1;
        if (outstanding_o != 0) fail("outstanding count did not drain");
        for (i = 0; i < IDS; i = i + 1) begin
            checks = checks + 1;
            if (id_head[i] != id_tail[i]) fail("per-ID golden queue did not drain");
        end

        if (errors == 0) begin
            $display("Completed %0d requests with %0d checks", completed_count, checks);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #500000;
        $display("DEBUG: outstanding=%0d completed=%0d", outstanding_o, completed_count);
        for (i = 0; i < IDS; i = i + 1)
            $display("DEBUG: id=%0d head=%0d tail=%0d beat=%0d", i, id_head[i], id_tail[i], model_beat[i]);
        for (i = 0; i < SLOTS; i = i + 1)
            $display("DEBUG: slot=%0d active=%0b complete=%0b id=%0d seq=%0d len=%0d bitmap=%b", i,
                     dut.slot_active_q[i], dut.slot_complete_q[i], dut.slot_id_q[i],
                     dut.slot_seq_q[i], dut.slot_len_q[i], dut.slot_received_q[i]);
        $display("DEBUG: out_active=%0b out_slot=%0d out_beat=%0d retire_seq1=%0d candidate=%0b/%0d count=%0d",
                 dut.output_active_q, dut.output_slot_q, dut.output_beat_q,
                 dut.retire_seq_q[1], dut.candidate_found, dut.candidate_slot, dut.count_q);
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1);
    end
endmodule
