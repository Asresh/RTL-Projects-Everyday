// =============================================================================
// tb_crc32_parallel.sv
// -----------------------------------------------------------------------------
// Self-checking testbench for crc32_parallel.
//
//   Golden model : an independent *bit-serial* reflected CRC-32 reference
//                  (ref_crc32) — deliberately written a different way from the
//                  unrolled DUT so a shared bug cannot hide.
//   Checks       : 1) IEEE check vector  "123456789" -> 0xCBF43926
//                  2) empty frame (init+last only)   -> 0x00000000
//                  3) directed byte patterns (0x00.., 0xFF.., incrementing)
//                  4) randomized frames, byte-granular  (W=8  instance)
//                  5) randomized frames, 4-byte slices   (W=32 instance)
//   Infra        : global timeout, VCD dump, PASS/FAIL counters.
//
//   Prints "RESULT: *** PASS ***" only if every comparison matched.
// =============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_crc32_parallel;

    // ------------------------------------------------------------------
    // Clock / reset
    // ------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;              // 100 MHz

    // ------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------
    int unsigned checks = 0;
    int unsigned errors = 0;

    task automatic score(input string tag,
                         input logic [31:0] got,
                         input logic [31:0] exp);
        checks++;
        if (got !== exp) begin
            errors++;
            $error("[%0t] %-28s MISMATCH got=%08h exp=%08h", $time, tag, got, exp);
        end else begin
            $display("[%0t] %-28s OK  crc=%08h", $time, tag, got);
        end
    endtask

    // ------------------------------------------------------------------
    // Golden reference: bit-serial reflected CRC-32 over a byte array.
    // ------------------------------------------------------------------
    function automatic logic [31:0] ref_crc32(input byte unsigned b[],
                                              input int             n);
        logic [31:0]  c;
        logic         fb;
        byte unsigned cur;
        begin
            c = 32'hFFFF_FFFF;
            for (int k = 0; k < n; k++) begin
                cur = b[k];
                for (int i = 0; i < 8; i++) begin
                    fb = c[0] ^ cur[i];
                    c  = (c >> 1) ^ (fb ? 32'hEDB8_8320 : 32'h0);
                end
            end
            ref_crc32 = c ^ 32'hFFFF_FFFF;
        end
    endfunction

    // ==================================================================
    // DUT A : 8-bit slice (1 byte / clock)
    // ==================================================================
    logic        a_init, a_en, a_last;
    logic [7:0]  a_data;
    logic [31:0] a_crc, a_result;
    logic        a_rvalid;

    crc32_parallel #(.DATA_WIDTH(8)) dut_a (
        .clk(clk), .rst_n(rst_n),
        .init(a_init), .en(a_en), .last(a_last), .data(a_data),
        .crc_o(a_crc), .result_o(a_result), .result_valid_o(a_rvalid)
    );

    // ==================================================================
    // DUT B : 32-bit slice (4 bytes / clock)
    // ==================================================================
    logic        b_init, b_en, b_last;
    logic [31:0] b_data;
    logic [31:0] b_crc, b_result;
    logic        b_rvalid;

    crc32_parallel #(.DATA_WIDTH(32)) dut_b (
        .clk(clk), .rst_n(rst_n),
        .init(b_init), .en(b_en), .last(b_last), .data(b_data),
        .crc_o(b_crc), .result_o(b_result), .result_valid_o(b_rvalid)
    );

    // ------------------------------------------------------------------
    // Driver A: push a byte array through the 8-bit DUT, return DUT result.
    // ------------------------------------------------------------------
    task automatic run_a(input byte unsigned b[], input int n,
                         output logic [31:0] res);
        begin
            @(negedge clk);
            if (n == 0) begin
                // empty frame: seed and mark last in the same beat with en=0
                a_init = 1'b1; a_en = 1'b0; a_last = 1'b1; a_data = '0;
                @(negedge clk);
                a_init = 1'b0; a_last = 1'b0;
            end else begin
                for (int k = 0; k < n; k++) begin
                    a_init = (k == 0);
                    a_en   = 1'b1;
                    a_last = (k == n-1);
                    a_data = b[k];
                    @(negedge clk);
                end
                a_init = 1'b0; a_en = 1'b0; a_last = 1'b0; a_data = '0;
            end
            // capture the one-cycle registered result strobe
            while (!a_rvalid) @(negedge clk);
            res = a_result;
            @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Driver B: push a byte array (length multiple of 4) through 32-bit DUT.
    // ------------------------------------------------------------------
    task automatic run_b(input byte unsigned b[], input int n,
                         output logic [31:0] res);
        int beats;
        logic [31:0] word;
        begin
            beats = n / 4;
            @(negedge clk);
            for (int j = 0; j < beats; j++) begin
                word = { b[4*j+3], b[4*j+2], b[4*j+1], b[4*j+0] };
                b_init = (j == 0);
                b_en   = 1'b1;
                b_last = (j == beats-1);
                b_data = word;
                @(negedge clk);
            end
            b_init = 1'b0; b_en = 1'b0; b_last = 1'b0; b_data = '0;
            while (!b_rvalid) @(negedge clk);
            res = b_result;
            @(negedge clk);
        end
    endtask

    // ------------------------------------------------------------------
    // Stimulus
    // ------------------------------------------------------------------
    byte unsigned msg[];
    logic [31:0]  got, exp;
    string        s;

    initial begin
        $dumpfile("crc32_parallel.vcd");
        $dumpvars(0, tb_crc32_parallel);

        a_init=0; a_en=0; a_last=0; a_data='0;
        b_init=0; b_en=0; b_last=0; b_data='0;

        // reset
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- 1) canonical IEEE check vector "123456789" (W=8) -----------
        s = "123456789";
        msg = new[s.len()];
        foreach (msg[i]) msg[i] = s[i];
        run_a(msg, msg.size(), got);
        score("IEEE '123456789'", got, 32'hCBF4_3926);

        // ---- 2) empty frame -> 0x00000000 ------------------------------
        msg = new[0];
        run_a(msg, 0, got);
        score("empty frame", got, 32'h0000_0000);

        // ---- 3) directed patterns (W=8) --------------------------------
        // all zeros (16 bytes)
        msg = new[16]; foreach (msg[i]) msg[i] = 8'h00;
        run_a(msg, msg.size(), got); score("16x 0x00", got, ref_crc32(msg, msg.size()));
        // all ones
        msg = new[16]; foreach (msg[i]) msg[i] = 8'hFF;
        run_a(msg, msg.size(), got); score("16x 0xFF", got, ref_crc32(msg, msg.size()));
        // incrementing
        msg = new[32]; foreach (msg[i]) msg[i] = i[7:0];
        run_a(msg, msg.size(), got); score("00..1F ramp", got, ref_crc32(msg, msg.size()));
        // single byte
        msg = new[1]; msg[0] = 8'hA5;
        run_a(msg, msg.size(), got); score("single 0xA5", got, ref_crc32(msg, msg.size()));

        // ---- 4) randomized frames, byte-granular (W=8) -----------------
        for (int t = 0; t < 60; t++) begin
            int len = 1 + {$random} % 40;
            msg = new[len];
            foreach (msg[i]) msg[i] = {$random} & 8'hFF;
            exp = ref_crc32(msg, msg.size());
            run_a(msg, msg.size(), got);
            score($sformatf("rand8 t=%0d len=%0d", t, len), got, exp);
        end

        // ---- 5) randomized frames, 32-bit slices (W=32) ----------------
        for (int t = 0; t < 60; t++) begin
            int words = 1 + {$random} % 10;   // 4..40 bytes, multiple of 4
            int len   = words * 4;
            msg = new[len];
            foreach (msg[i]) msg[i] = {$random} & 8'hFF;
            exp = ref_crc32(msg, msg.size());
            run_b(msg, msg.size(), got);
            score($sformatf("rand32 t=%0d bytes=%0d", t, len), got, exp);
        end

        // cross-check: same message through both engines must agree
        msg = new[8]; foreach (msg[i]) msg[i] = ("A" + i);
        run_a(msg, msg.size(), got);
        run_b(msg, msg.size(), exp);
        score("W8-vs-W32 agree", got, exp);

        // ------------------------------------------------------------------
        $display("--------------------------------------------------");
        $display("checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ------------------------------------------------------------------
    // Global timeout
    // ------------------------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1, "timeout");
    end

endmodule

`default_nettype wire
