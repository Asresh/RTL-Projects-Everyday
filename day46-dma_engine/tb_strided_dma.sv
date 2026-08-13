`timescale 1ns/1ps
`default_nettype none

module tb_strided_dma;
    localparam integer ADDR_W = 12;
    localparam integer DATA_W = 32;
    localparam integer LEN_W  = 10;
    localparam integer ROW_W  = 6;
    localparam integer TAG_W  = 8;
    localparam integer CMD_DEPTH = 4;
    localparam integer BYTE_LANES = DATA_W/8;
    localparam integer MEM_BYTES = 4096;
    localparam [ADDR_W-1:0] ERROR_ADDR = 12'hF00;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg cmd_valid;
    wire cmd_ready;
    reg [ADDR_W-1:0] cmd_src_addr;
    reg [ADDR_W-1:0] cmd_dst_addr;
    reg [LEN_W-1:0] cmd_row_bytes;
    reg [ROW_W-1:0] cmd_rows;
    reg signed [ADDR_W-1:0] cmd_src_stride;
    reg signed [ADDR_W-1:0] cmd_dst_stride;
    reg [TAG_W-1:0] cmd_tag;

    wire busy;
    wire [$clog2(CMD_DEPTH+1)-1:0] queue_level;
    wire rd_req_valid;
    reg rd_req_ready;
    wire [ADDR_W-1:0] rd_req_addr;
    reg rd_rsp_valid;
    wire rd_rsp_ready;
    reg [DATA_W-1:0] rd_rsp_data;
    reg rd_rsp_error;
    wire wr_req_valid;
    reg wr_req_ready;
    wire [ADDR_W-1:0] wr_req_addr;
    wire [DATA_W-1:0] wr_req_data;
    wire [BYTE_LANES-1:0] wr_req_strb;
    reg wr_rsp_valid;
    wire wr_rsp_ready;
    reg wr_rsp_error;
    wire done;
    wire error;
    wire [TAG_W-1:0] done_tag;
    wire [31:0] perf_bytes;
    wire [31:0] perf_desc;
    wire [31:0] perf_stall_cycles;

    strided_dma #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .LEN_W(LEN_W),
        .ROW_W(ROW_W), .TAG_W(TAG_W), .CMD_DEPTH(CMD_DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid_i(cmd_valid), .cmd_ready_o(cmd_ready),
        .cmd_src_addr_i(cmd_src_addr), .cmd_dst_addr_i(cmd_dst_addr),
        .cmd_row_bytes_i(cmd_row_bytes), .cmd_rows_i(cmd_rows),
        .cmd_src_stride_i(cmd_src_stride), .cmd_dst_stride_i(cmd_dst_stride),
        .cmd_tag_i(cmd_tag), .busy_o(busy), .queue_level_o(queue_level),
        .rd_req_valid_o(rd_req_valid), .rd_req_ready_i(rd_req_ready),
        .rd_req_addr_o(rd_req_addr), .rd_rsp_valid_i(rd_rsp_valid),
        .rd_rsp_ready_o(rd_rsp_ready), .rd_rsp_data_i(rd_rsp_data),
        .rd_rsp_error_i(rd_rsp_error), .wr_req_valid_o(wr_req_valid),
        .wr_req_ready_i(wr_req_ready), .wr_req_addr_o(wr_req_addr),
        .wr_req_data_o(wr_req_data), .wr_req_strb_o(wr_req_strb),
        .wr_rsp_valid_i(wr_rsp_valid), .wr_rsp_ready_o(wr_rsp_ready),
        .wr_rsp_error_i(wr_rsp_error), .done_o(done), .error_o(error),
        .done_tag_o(done_tag), .perf_bytes_o(perf_bytes),
        .perf_desc_o(perf_desc), .perf_stall_cycles_o(perf_stall_cycles)
    );

    reg [7:0] memory [0:MEM_BYTES-1];
    reg [7:0] golden [0:MEM_BYTES-1];
    reg rd_pending;
    reg [ADDR_W-1:0] rd_addr_q;
    integer rd_delay_q;
    reg wr_pending;
    integer wr_delay_q;
    integer seed;
    integer cycles;
    integer checks;
    integer errors;
    integer i;
    integer j;

    reg [TAG_W-1:0] expected_tag [0:255];
    reg expected_error [0:255];
    integer expected_head;
    integer expected_tail;

    task automatic expect_completion(input [TAG_W-1:0] tag, input reg exp_error);
        begin
            expected_tag[expected_tail] = tag;
            expected_error[expected_tail] = exp_error;
            expected_tail = expected_tail + 1;
        end
    endtask

    task automatic submit_descriptor(
        input [ADDR_W-1:0] src,
        input [ADDR_W-1:0] dst,
        input [LEN_W-1:0] row_bytes,
        input [ROW_W-1:0] rows,
        input signed [ADDR_W-1:0] src_stride,
        input signed [ADDR_W-1:0] dst_stride,
        input [TAG_W-1:0] tag,
        input reg exp_error
    );
        begin
            @(negedge clk);
            cmd_src_addr = src;
            cmd_dst_addr = dst;
            cmd_row_bytes = row_bytes;
            cmd_rows = rows;
            cmd_src_stride = src_stride;
            cmd_dst_stride = dst_stride;
            cmd_tag = tag;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(negedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
            expect_completion(tag, exp_error);
        end
    endtask

    task automatic golden_copy(
        input integer src,
        input integer dst,
        input integer row_bytes,
        input integer rows,
        input integer src_stride,
        input integer dst_stride
    );
        integer r;
        integer b;
        begin
            for (r = 0; r < rows; r = r + 1)
                for (b = 0; b < row_bytes; b = b + 1)
                    golden[dst + r*dst_stride + b] = golden[src + r*src_stride + b];
        end
    endtask

    task automatic compare_memory;
        begin
            for (i = 0; i < MEM_BYTES; i = i + 1) begin
                checks = checks + 1;
                if (memory[i] !== golden[i]) begin
                    if (errors < 12)
                        $display("ERROR memory[%0d] got=%02x expected=%02x", i, memory[i], golden[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_req_ready <= 1'b0;
            rd_rsp_valid <= 1'b0;
            rd_rsp_data <= {DATA_W{1'b0}};
            rd_rsp_error <= 1'b0;
            rd_pending <= 1'b0;
            rd_addr_q <= {ADDR_W{1'b0}};
            rd_delay_q <= 0;
            wr_req_ready <= 1'b0;
            wr_rsp_valid <= 1'b0;
            wr_rsp_error <= 1'b0;
            wr_pending <= 1'b0;
            wr_delay_q <= 0;
        end else begin
            rd_req_ready <= !rd_pending && !rd_rsp_valid && (($urandom(seed) % 4) != 0);
            wr_req_ready <= !wr_pending && !wr_rsp_valid && (($urandom(seed) % 3) != 0);

            if (rd_req_valid && rd_req_ready) begin
                rd_pending <= 1'b1;
                rd_addr_q <= rd_req_addr;
                rd_delay_q <= $urandom(seed) % 4;
            end
            if (rd_pending) begin
                if (rd_delay_q == 0 && !rd_rsp_valid) begin
                    for (j = 0; j < BYTE_LANES; j = j + 1)
                        rd_rsp_data[j*8 +: 8] <= memory[rd_addr_q + j];
                    rd_rsp_error <= (rd_addr_q == ERROR_ADDR);
                    rd_rsp_valid <= 1'b1;
                    rd_pending <= 1'b0;
                end else if (rd_delay_q != 0) begin
                    rd_delay_q <= rd_delay_q - 1;
                end
            end
            if (rd_rsp_valid && rd_rsp_ready) begin
                rd_rsp_valid <= 1'b0;
                rd_rsp_error <= 1'b0;
            end

            if (wr_req_valid && wr_req_ready) begin
                for (j = 0; j < BYTE_LANES; j = j + 1)
                    if (wr_req_strb[j])
                        memory[wr_req_addr + j] <= wr_req_data[j*8 +: 8];
                wr_pending <= 1'b1;
                wr_delay_q <= $urandom(seed) % 4;
            end
            if (wr_pending) begin
                if (wr_delay_q == 0 && !wr_rsp_valid) begin
                    wr_rsp_valid <= 1'b1;
                    wr_rsp_error <= 1'b0;
                    wr_pending <= 1'b0;
                end else if (wr_delay_q != 0) begin
                    wr_delay_q <= wr_delay_q - 1;
                end
            end
            if (wr_rsp_valid && wr_rsp_ready)
                wr_rsp_valid <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycles <= cycles + 1;
            if (cycles > 200000) begin
                $display("RESULT: *** FAIL *** timeout");
                $finish;
            end
            if (done) begin
                checks <= checks + 2;
                if (expected_head >= expected_tail) begin
                    $display("ERROR unexpected completion tag=%0d", done_tag);
                    errors <= errors + 1;
                end else begin
                    if (done_tag !== expected_tag[expected_head]) begin
                        $display("ERROR completion order got tag=%0d expected=%0d", done_tag, expected_tag[expected_head]);
                        errors <= errors + 1;
                    end
                    if (error !== expected_error[expected_head]) begin
                        $display("ERROR tag=%0d error=%0b expected=%0b", done_tag, error, expected_error[expected_head]);
                        errors <= errors + 1;
                    end
                    expected_head <= expected_head + 1;
                end
            end
        end
    end

    initial begin : stimulus
        integer n;
        integer src;
        integer dst;
        integer row_bytes;
        integer rows;
        integer src_stride;
        integer dst_stride;
        integer expected_bytes;

        if (!$value$plusargs("seed=%d", seed))
            seed = 46;
        cycles = 0;
        checks = 0;
        errors = 0;
        expected_head = 0;
        expected_tail = 0;
        cmd_valid = 1'b0;
        cmd_src_addr = 0;
        cmd_dst_addr = 0;
        cmd_row_bytes = 0;
        cmd_rows = 0;
        cmd_src_stride = 0;
        cmd_dst_stride = 0;
        cmd_tag = 0;
        expected_bytes = 0;

        for (i = 0; i < MEM_BYTES; i = i + 1) begin
            memory[i] = (i * 73 + 19) & 8'hff;
            golden[i] = memory[i];
        end

        $dumpfile("strided_dma.vcd");
        $dumpvars(0, tb_strided_dma);

        repeat (4) @(negedge clk);
        rst_n = 1'b1;

        // Directed: unaligned 13-byte rows exercise 0x1 last-beat strobe.
        golden_copy(16, 2048, 13, 3, 32, 40);
        expected_bytes = expected_bytes + 39;
        submit_descriptor(16, 2048, 13, 3, 32, 40, 8'h01, 1'b0);

        // Queue descriptors while the first is still moving.
        golden_copy(200, 2300, 16, 2, 24, 28);
        expected_bytes = expected_bytes + 32;
        submit_descriptor(200, 2300, 16, 2, 24, 28, 8'h02, 1'b0);
        golden_copy(400, 2500, 7, 4, 12, 19);
        expected_bytes = expected_bytes + 28;
        submit_descriptor(400, 2500, 7, 4, 12, 19, 8'h03, 1'b0);

        // Illegal zero-length descriptor must fail without touching memory.
        submit_descriptor(0, 2800, 0, 2, 8, 8, 8'h04, 1'b1);

        // A read response error must abort only its descriptor.
        submit_descriptor(ERROR_ADDR, 2900, 8, 1, 8, 8, 8'h05, 1'b1);

        // Recovery after an error.
        golden_copy(700, 3000, 11, 2, 16, 20);
        expected_bytes = expected_bytes + 22;
        submit_descriptor(700, 3000, 11, 2, 16, 20, 8'h06, 1'b0);

        // Randomized 2D copies with source/destination separation and stalls.
        for (n = 0; n < 80; n = n + 1) begin
            row_bytes = 1 + ($urandom(seed) % 29);
            rows = 1 + ($urandom(seed) % 4);
            src_stride = row_bytes + ($urandom(seed) % 13);
            dst_stride = row_bytes + ($urandom(seed) % 17);
            src = $urandom(seed) % (900 - rows*src_stride);
            dst = 3072 + ($urandom(seed) % (850 - rows*dst_stride));
            golden_copy(src, dst, row_bytes, rows, src_stride, dst_stride);
            expected_bytes = expected_bytes + row_bytes*rows;
            submit_descriptor(src[ADDR_W-1:0], dst[ADDR_W-1:0],
                              row_bytes[LEN_W-1:0], rows[ROW_W-1:0],
                              src_stride[ADDR_W-1:0], dst_stride[ADDR_W-1:0],
                              (8'h20+n), 1'b0);
        end

        while ((expected_head != expected_tail) || busy)
            @(negedge clk);
        repeat (3) @(negedge clk);

        compare_memory();
        checks = checks + 3;
        if (perf_desc !== expected_tail) begin
            $display("ERROR perf_desc=%0d expected=%0d", perf_desc, expected_tail);
            errors = errors + 1;
        end
        if (perf_bytes !== expected_bytes) begin
            $display("ERROR perf_bytes=%0d expected=%0d", perf_bytes, expected_bytes);
            errors = errors + 1;
        end
        if (perf_stall_cycles == 0) begin
            $display("ERROR randomized memory model produced no stalls");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** %0d descriptors, %0d checks, %0d bytes, %0d stall cycles", expected_tail, checks, perf_bytes, perf_stall_cycles);
        else
            $display("RESULT: *** FAIL *** %0d errors in %0d checks", errors, checks);
        $finish;
    end

endmodule

`default_nettype wire
