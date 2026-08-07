`timescale 1ns/1ps
`default_nettype none

module tb_simt_operand_collector;
    localparam int DW = 32;
    localparam int NR = 32;
    localparam int NW = 4;
    localparam int NB = 4;
    localparam int NC = 4;
    localparam int NS = 3;
    localparam int TW = 12;
    localparam int RW = $clog2(NR);
    localparam int WW = $clog2(NW);
    localparam int RANDOM_REQUESTS = 1200;

    logic clk = 0;
    logic rst_n = 0;
    logic flush_i;
    logic wr_en_i;
    logic [WW-1:0] wr_warp_i;
    logic [RW-1:0] wr_reg_i;
    logic [DW-1:0] wr_data_i;
    logic req_valid_i, req_ready_o;
    logic [WW-1:0] req_warp_i;
    logic [TW-1:0] req_tag_i;
    logic [NS-1:0] req_src_valid_i;
    logic [NS*RW-1:0] req_src_reg_i;
    logic issue_valid_o, issue_ready_i;
    logic [WW-1:0] issue_warp_o;
    logic [TW-1:0] issue_tag_o;
    logic [NS*DW-1:0] issue_operand_o;
    logic [NS-1:0] issue_src_valid_o;
    logic [NC-1:0] dbg_busy_o;
    logic [NC*NS-1:0] dbg_pending_o;
    logic [31:0] perf_bank_reads_o, perf_reuse_hits_o, perf_conflict_cycles_o;

    logic [DW-1:0] model_rf [0:NW-1][0:NR-1];
    logic exp_live [0:(1<<TW)-1];
    logic [WW-1:0] exp_warp [0:(1<<TW)-1];
    logic [NS-1:0] exp_valid [0:(1<<TW)-1];
    logic [DW-1:0] exp_operand [0:(1<<TW)-1][0:NS-1];
    integer checks = 0;
    integer errors = 0;
    integer sent = 0;
    integer received = 0;
    integer outstanding = 0;
    integer squashed = 0;
    integer seed = 32'h42c011ec;
    integer cycle = 0;
    integer i, j;

    always #5 clk = ~clk;

    simt_operand_collector #(
        .DATA_WIDTH(DW), .REG_COUNT(NR), .WARP_COUNT(NW), .BANKS(NB),
        .COLLECTORS(NC), .TAG_WIDTH(TW), .SOURCES(NS)
    ) dut (.*);

    task automatic fail(input string msg);
        begin
            $display("ERROR cycle=%0d: %s", cycle, msg);
            errors = errors + 1;
        end
    endtask

    task automatic write_reg(input int warp, input int regno, input logic [DW-1:0] value);
        begin
            @(negedge clk);
            wr_en_i = 1'b1; wr_warp_i = warp[WW-1:0]; wr_reg_i = regno[RW-1:0]; wr_data_i = value;
            model_rf[warp][regno] = value;
            @(negedge clk);
            wr_en_i = 1'b0;
        end
    endtask

    task automatic send_req(
        input int warp, input int r0, input int r1, input int r2,
        input logic [NS-1:0] valid_mask, input int tag
    );
        integer s;
        integer rr[0:NS-1];
        begin
            rr[0] = r0; rr[1] = r1; rr[2] = r2;
            @(negedge clk);
            while (!req_ready_o) @(negedge clk);
            req_valid_i = 1'b1;
            req_warp_i = warp[WW-1:0];
            req_tag_i = tag[TW-1:0];
            req_src_valid_i = valid_mask;
            for (s = 0; s < NS; s = s + 1)
                req_src_reg_i[s*RW +: RW] = rr[s][RW-1:0];
            exp_live[tag] = 1'b1;
            exp_warp[tag] = warp[WW-1:0];
            exp_valid[tag] = valid_mask;
            for (s = 0; s < NS; s = s + 1)
                exp_operand[tag][s] = valid_mask[s] ? model_rf[warp][rr[s]] : '0;
            sent = sent + 1;
            outstanding = outstanding + 1;
            @(negedge clk);
            req_valid_i = 1'b0;
        end
    endtask

    always @(posedge clk) begin
        integer s;
        cycle = cycle + 1;
        if (rst_n && issue_valid_o && issue_ready_i) begin
            checks = checks + 1;
            if (!exp_live[issue_tag_o])
                fail($sformatf("unexpected/duplicate issue tag %0d", issue_tag_o));
            else begin
                if (issue_warp_o !== exp_warp[issue_tag_o])
                    fail($sformatf("tag %0d warp got %0d expected %0d", issue_tag_o,
                                   issue_warp_o, exp_warp[issue_tag_o]));
                if (issue_src_valid_o !== exp_valid[issue_tag_o])
                    fail($sformatf("tag %0d source-valid mismatch", issue_tag_o));
                for (s = 0; s < NS; s = s + 1) begin
                    checks = checks + 1;
                    if (issue_operand_o[s*DW +: DW] !== exp_operand[issue_tag_o][s])
                        fail($sformatf("tag %0d src%0d got %08x expected %08x",
                                      issue_tag_o, s, issue_operand_o[s*DW +: DW],
                                      exp_operand[issue_tag_o][s]));
                end
                exp_live[issue_tag_o] = 1'b0;
                received = received + 1;
                outstanding = outstanding - 1;
            end
        end
        if (rst_n) begin
            for (i = 0; i < NB; i = i + 1) begin
                integer grants;
                grants = 0;
                for (j = 0; j < NC; j = j + 1)
                    for (s = 0; s < NS; s = s + 1)
                        if (dut.grant_valid[i] && dut.grant_coll[i] == j && dut.grant_src[i] == s)
                            grants = grants + 1;
                checks = checks + 1;
                if (grants > 1) fail($sformatf("bank %0d issued %0d reads", i, grants));
            end
        end
    end

    initial begin : stimulus
        integer w, r, n, tag, rv, rs0, rs1, rs2, wm;
        if ($value$plusargs("seed=%d", seed))
            $display("Using random seed %0d", seed);
        $dumpfile("simt_operand_collector.vcd");
        $dumpvars(0, tb_simt_operand_collector);
        flush_i = 0; wr_en_i = 0; req_valid_i = 0; issue_ready_i = 1;
        wr_warp_i = 0; wr_reg_i = 0; wr_data_i = 0;
        req_warp_i = 0; req_tag_i = 0; req_src_valid_i = 0; req_src_reg_i = 0;
        for (n = 0; n < (1<<TW); n = n + 1) exp_live[n] = 0;
        for (w = 0; w < NW; w = w + 1)
            for (r = 0; r < NR; r = r + 1) model_rf[w][r] = '0;

        repeat (4) @(negedge clk);
        rst_n = 1;

        // Deterministic initialization: the data identifies both warp and register.
        for (w = 0; w < NW; w = w + 1)
            for (r = 0; r < NR; r = r + 1)
                write_reg(w, r, 32'h1000_0000 + (w << 16) + r);

        // Capture a reset adjacent to useful traffic; the RF contents intentionally survive.
        @(negedge clk); rst_n = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        tag = 1;
        // Three source registers in bank 1: necessarily serialized over three cycles.
        send_req(0, 1, 5, 9, 3'b111, tag); tag = tag + 1;
        // Repeating two operands exercises the two-entry warp-private reuse cache.
        repeat (5) @(negedge clk);
        send_req(0, 9, 5, 2, 3'b111, tag); tag = tag + 1;
        while (outstanding != 0) @(negedge clk);
        // A writeback must invalidate an older reuse-cache copy of r9.
        write_reg(0, 9, 32'hcafe_0009);
        send_req(0, 9, 0, 0, 3'b001, tag); tag = tag + 1;
        // Independent banks should collect in parallel; unused operands must be zero.
        send_req(1, 0, 1, 2, 3'b101, tag); tag = tag + 1;
        send_req(2, 4, 13, 22, 3'b111, tag); tag = tag + 1;
        send_req(3, 7, 15, 23, 3'b111, tag); tag = tag + 1;

        // Exercise output backpressure with completed collectors held intact.
        @(negedge clk); issue_ready_i = 0;
        repeat (8) @(negedge clk);
        issue_ready_i = 1;
        while (outstanding != 0) @(negedge clk);

        // Flush must atomically discard in-flight collectors and their pending reads.
        issue_ready_i = 0;
        send_req(0, 3, 11, 19, 3'b111, tag); tag = tag + 1;
        send_req(1, 6, 14, 22, 3'b111, tag); tag = tag + 1;
        @(negedge clk);
        flush_i = 1;
        for (n = tag-2; n < tag; n = n + 1) begin
            if (exp_live[n]) begin
                exp_live[n] = 0;
                outstanding = outstanding - 1;
                squashed = squashed + 1;
            end
        end
        @(negedge clk);
        flush_i = 0;
        issue_ready_i = 1;
        repeat (3) @(negedge clk);

        // Random concurrent pressure. Bias one third of traffic to bank 0 conflicts.
        for (n = 0; n < RANDOM_REQUESTS; n = n + 1) begin
            rv = $random(seed);
            wm = (rv < 0 ? -rv : rv) % NW;
            rs0 = (($random(seed) & 32'h7fff_ffff) % NR);
            rs1 = (($random(seed) & 32'h7fff_ffff) % NR);
            rs2 = (($random(seed) & 32'h7fff_ffff) % NR);
            if ((n % 3) == 0) begin
                rs0 = ((n+0) % (NR/NB)) * NB;
                rs1 = ((n+1) % (NR/NB)) * NB;
                rs2 = ((n+2) % (NR/NB)) * NB;
            end
            if ((n % 29) == 0) begin
                @(negedge clk); issue_ready_i = 0;
                repeat (2) @(negedge clk);
                issue_ready_i = 1;
            end
            send_req(wm, rs0, rs1, rs2, 3'b001 | (($random(seed) & 3) << 1), tag);
            tag = tag + 1;
        end

        while (outstanding != 0) @(negedge clk);
        repeat (5) @(negedge clk);
        checks = checks + 3;
        if (perf_bank_reads_o == 0) fail("bank-read counter never advanced");
        if (perf_reuse_hits_o == 0) fail("reuse cache never hit");
        if (perf_conflict_cycles_o == 0) fail("bank-conflict counter never advanced");
        if (sent != received + squashed)
            fail($sformatf("sent=%0d received=%0d squashed=%0d", sent, received, squashed));

        $display("SUMMARY: sent=%0d received=%0d squashed=%0d checks=%0d bank_reads=%0d reuse_hits=%0d conflict_bank_cycles=%0d",
                 sent, received, squashed, checks, perf_bank_reads_o, perf_reuse_hits_o,
                 perf_conflict_cycles_o);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else begin
            $display("RESULT: *** FAIL *** errors=%0d", errors);
            $fatal(1, "self-check failed");
        end
        $finish;
    end

    initial begin
        repeat (100000) @(posedge clk);
        $fatal(1, "TIMEOUT: sent=%0d received=%0d outstanding=%0d", sent, received, outstanding);
    end
endmodule

`default_nettype wire
