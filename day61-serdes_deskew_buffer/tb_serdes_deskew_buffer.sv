// Author: Asresh Kuricheti
// Directed and randomized self-checking testbench.

`timescale 1ns/1ps

module tb_serdes_deskew_buffer;
    localparam int LANES = 4;
    localparam int DW = 8;
    localparam int DEPTH = 8;
    localparam int SYMBOLS = 64;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic retrain = 1'b0;
    logic [LANES-1:0] rx_valid;
    logic [LANES-1:0] rx_ready;
    logic [LANES-1:0][DW-1:0] rx_data;
    logic [LANES-1:0] rx_marker;
    logic aligned_valid;
    logic aligned_ready;
    logic [LANES-1:0][DW-1:0] aligned_data;
    logic [LANES-1:0] aligned_marker;
    logic locked;
    logic deskew_error;
    logic [LANES-1:0] fifo_overflow;
    logic [LANES-1:0][15:0] drop_count;

    integer lane_pos [0:LANES-1];
    integer preamble [0:LANES-1];
    integer checks = 0;
    integer errors = 0;
    integer output_index = 0;
    integer cycles = 0;
    integer seed = 32'h60d35e2;
    logic started = 1'b0;

    serdes_deskew_buffer #(
        .LANES(LANES), .DATA_WIDTH(DW), .FIFO_DEPTH(DEPTH)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic [DW-1:0] symbol_data(input integer lane, input integer idx);
        symbol_data = (8'h31 + idx + (lane * 8'h29)) & 8'hff;
    endfunction

    task automatic check(input logic condition, input string message);
        checks = checks + 1;
        if (!condition) begin
            errors = errors + 1;
            $display("ERROR @ %0t: %s", $time, message);
        end
    endtask

    always @(negedge clk) begin
        if (!rst_n) begin
            rx_valid      <= '0;
            rx_marker     <= '0;
            rx_data       <= '0;
            aligned_ready <= 1'b0;
        end else begin
            aligned_ready <= (($urandom(seed) % 5) != 0);
            for (int lane = 0; lane < LANES; lane++) begin
                if (lane_pos[lane] < SYMBOLS &&
                    (!rx_valid[lane] || rx_ready[lane])) begin
                    if (($urandom(seed) % 4) != 0) begin
                        rx_valid[lane] <= 1'b1;
                        if (lane_pos[lane] < 0) begin
                            rx_data[lane]   <= 8'he0 + lane_pos[lane] + lane;
                            rx_marker[lane] <= 1'b0;
                        end else begin
                            rx_data[lane]   <= symbol_data(lane, lane_pos[lane]);
                            rx_marker[lane] <= ((lane_pos[lane] % 16) == 0);
                        end
                    end else begin
                        rx_valid[lane] <= 1'b0;
                    end
                end
                if (rx_valid[lane] && rx_ready[lane]) begin
                    lane_pos[lane] <= lane_pos[lane] + 1;
                    rx_valid[lane] <= 1'b0;
                end
            end
        end
    end

    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (rst_n) begin
            check(!(aligned_valid && !locked), "valid asserted while unlocked");
            check(fifo_overflow == '0, "legal ready/valid traffic overflowed a FIFO");
            check(!deskew_error, "unexpected deskew error");

            if (locked)
                started <= 1'b1;

            if (aligned_valid && aligned_ready) begin
                check(aligned_marker == (((output_index % 16) == 0) ? '1 : '0),
                      "marker vector differs from golden model");
                for (int lane = 0; lane < LANES; lane++)
                    check(aligned_data[lane] == symbol_data(lane, output_index),
                          $sformatf("lane %0d data mismatch at symbol %0d", lane,
                                    output_index));
                output_index <= output_index + 1;
            end

            if (cycles > 3000) begin
                $display("ERROR: timeout");
                $display("RESULT: *** FAIL ***");
                $finish;
            end
        end
    end

    initial begin
        $dumpfile("serdes_deskew_buffer.vcd");
        $dumpvars(0, tb_serdes_deskew_buffer);

        preamble[0] = 1;
        preamble[1] = 4;
        preamble[2] = 2;
        preamble[3] = 6;
        for (int lane = 0; lane < LANES; lane++)
            lane_pos[lane] = -preamble[lane];

        rx_valid = '0;
        rx_marker = '0;
        rx_data = '0;
        aligned_ready = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        wait (output_index == SYMBOLS);
        repeat (4) @(posedge clk);

        check(started, "receiver never acquired deskew lock");
        check(drop_count[0] == preamble[0], "lane 0 drop count mismatch");
        check(drop_count[1] == preamble[1], "lane 1 drop count mismatch");
        check(drop_count[2] == preamble[2], "lane 2 drop count mismatch");
        check(drop_count[3] == preamble[3], "lane 3 drop count mismatch");
        check(checks > 250, "insufficient checks executed");

        if (errors == 0) begin
            $display("Completed %0d aligned symbols and %0d checks", output_index, checks);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("Completed with %0d errors across %0d checks", errors, checks);
            $display("RESULT: *** FAIL ***");
        end
        $finish;
    end
endmodule
