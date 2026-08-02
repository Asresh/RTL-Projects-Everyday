// ============================================================================
// Day 36 : Self-checking testbench for the hard-decision Viterbi decoder.
// ----------------------------------------------------------------------------
// Reference model : a golden rate-1/2, K=3 (7,5) convolutional ENCODER written
// straight in the TB.  Random message bits are encoded, optionally corrupted by
// a controlled (correctable) channel-error pattern, and streamed into the DUT.
// The decoded bit stream is aligned to the transmitted message and every bit is
// compared.  Because the (7,5) code has free distance 5, isolated single-symbol
// errors are guaranteed correctable, so the expected message-bit error count is
// exactly zero in all tests.
//
//   Test 1 : clean channel, long random stream        -> 0 decoded-bit errors
//   Test 2 : sparse isolated single-bit channel errors -> 0 decoded-bit errors
//   Test 3 : a second clean stream (fresh seed)        -> 0 decoded-bit errors
//
// Prints "RESULT: *** PASS ***" only if every test passes.  Dumps viterbi_decoder.vcd.
// ============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_viterbi_decoder;
    localparam int unsigned G0     = 3'o7;
    localparam int unsigned G1     = 3'o5;
    localparam int unsigned TB_LEN = 16;
    localparam int unsigned PM_W   = 8;

    localparam int unsigned MAXMSG = 512;   // max message bits per test
    localparam int unsigned MAXLAT = 8;     // alignment search window

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    always #5 clk = ~clk;                    // 100 MHz

    logic       rst_n;
    logic       in_valid;
    logic [1:0] sym_in;
    logic       out_valid;
    logic       bit_out;
    logic [1:0] state_min;

    viterbi_decoder #(
        .G0(G0), .G1(G1), .TB_LEN(TB_LEN), .PM_W(PM_W)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (in_valid),
        .sym_in   (sym_in),
        .out_valid(out_valid),
        .bit_out  (bit_out),
        .state_min(state_min)
    );

    // ---- scoreboard storage -------------------------------------------------
    logic       ref_bits [MAXMSG];   // transmitted message bits
    logic [1:0] tx_sym   [MAXMSG];   // clean encoded symbols
    logic [1:0] ch_sym   [MAXMSG];   // channel (possibly corrupted) symbols
    logic       out_bits [MAXMSG+MAXLAT+4];
    int         out_cnt;

    int total_errors = 0;

    // golden encoder state
    logic [1:0] enc_sr;

    // ---- golden reference encoder ------------------------------------------
    function automatic [1:0] gold_enc(input logic u);
        logic sr0, sr1, o0, o1;
        begin
            sr0 = enc_sr[0];
            sr1 = enc_sr[1];
            o0  = (G0[2] & u) ^ (G0[1] & sr0) ^ (G0[0] & sr1);
            o1  = (G1[2] & u) ^ (G1[1] & sr0) ^ (G1[0] & sr1);
            enc_sr  = {sr0, u};              // shift : next = {sr0, u}
            gold_enc = {o0, o1};
        end
    endfunction

    // ---- capture decoder output on valid cycles -----------------------------
    always @(posedge clk)
        if (rst_n && out_valid) begin
            if (out_cnt < MAXMSG+MAXLAT+4) out_bits[out_cnt] = bit_out;
            out_cnt++;
        end

    // ---- drive one stream through the DUT -----------------------------------
    // Builds a random message, encodes it, applies error pattern `err_period`
    // (0 = clean; else flip one bit of every err_period-th symbol), streams it,
    // aligns the decoded output and counts mismatches.
    task automatic run_stream(input string name,
                              input int    nbits,
                              input int    err_period,
                              input int    seed);
        int i, o, best_off, best_err, errs;
        logic [1:0] s;
        begin
            // deterministic seeding
            void'($urandom(seed));

            enc_sr  = 2'b00;
            out_cnt = 0;

            // build message + clean/channel symbols
            for (i = 0; i < nbits; i++) begin
                ref_bits[i] = $urandom_range(0, 1);
                s           = gold_enc(ref_bits[i]);
                tx_sym[i]   = s;
                ch_sym[i]   = s;
            end
            // inject isolated single-bit channel errors (well separated -> correctable)
            if (err_period > 0)
                for (i = err_period; i < nbits; i += err_period)
                    ch_sym[i] = tx_sym[i] ^ (2'b01 << $urandom_range(0, 1));

            // reset the DUT
            in_valid = 1'b0; sym_in = 2'b00; rst_n = 1'b0;
            @(posedge clk); @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            // stream all symbols, one per cycle
            for (i = 0; i < nbits; i++) begin
                in_valid = 1'b1;
                sym_in   = ch_sym[i];
                @(posedge clk);
            end
            in_valid = 1'b0;
            // zero-tail termination + drain : feed encoded 0-bits so the trellis
            // is consistently extended back toward state 0 and the genuine last
            // message bits ripple out of the TB_LEN-deep survivor registers.
            for (i = 0; i < TB_LEN+4; i++) begin
                in_valid = 1'b1;
                sym_in   = gold_enc(1'b0);  // properly encoded tail (input bit 0)
                @(posedge clk);
            end
            in_valid = 1'b0;
            @(posedge clk);

            // align decoded stream to the message (search small latency window)
            best_err = 1<<30; best_off = 0;
            for (o = 0; o <= MAXLAT; o++) begin
                errs = 0;
                for (i = 0; (i + o) < out_cnt && i < nbits; i++)
                    if (out_bits[i+o] !== ref_bits[i]) errs++;
                if (errs < best_err) begin best_err = errs; best_off = o; end
            end

            $display("  [%-8s] nbits=%0d  err_period=%0d  detected_latency=%0d  bit_errors=%0d",
                     name, nbits, err_period, best_off, best_err);
            if (best_err != 0) begin
                total_errors += best_err;
                // show first few mismatches for debug
                errs = 0;
                for (i = 0; (i + best_off) < out_cnt && i < nbits && errs < 6; i++)
                    if (out_bits[i+best_off] !== ref_bits[i]) begin
                        $display("      mismatch @msg[%0d] : got=%b exp=%b",
                                 i, out_bits[i+best_off], ref_bits[i]);
                        errs++;
                    end
            end
        end
    endtask

    // ---- main ---------------------------------------------------------------
    initial begin
        $dumpfile("viterbi_decoder.vcd");
        $dumpvars(0, tb_viterbi_decoder);
        // explicitly dump the four per-state path metrics (unpacked array
        // elements are not captured by the recursive $dumpvars above)
        $dumpvars(0, dut.pm[0], dut.pm[1], dut.pm[2], dut.pm[3]);

        $display("Day36 Viterbi decoder  (rate-1/2, K=3, (7,5) code, TB_LEN=%0d)", TB_LEN);
        $display("-----------------------------------------------------------------");

        run_stream("clean-A", 400, 0,  32'hC0FFEE01);
        run_stream("errors",  400, 25, 32'h1BADB002);   // 1 flip / 25 symbols
        run_stream("clean-B", 300, 0,  32'h5EED1234);

        $display("-----------------------------------------------------------------");
        if (total_errors == 0)
            $display("RESULT: *** PASS *** (all decoded streams matched the transmitted message)");
        else
            $display("RESULT: *** FAIL *** (%0d decoded-bit errors)", total_errors);

        $finish;
    end

    // ---- global timeout -----------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end
endmodule

`default_nettype wire
