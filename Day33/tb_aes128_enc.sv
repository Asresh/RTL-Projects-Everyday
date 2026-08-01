// =============================================================================
// Day 33 : Self-checking testbench for the AES-128 encryption core.
// -----------------------------------------------------------------------------
// The golden model here is INDEPENDENT of the DUT in the way that matters most:
// its S-box is not copied from the DUT's ROM, it is DERIVED from first
// principles -- the multiplicative inverse in GF(2^8) (mod 0x11B) followed by the
// AES affine transform. If a single byte of the DUT's 256-entry S-box ROM were
// wrong, this testbench would catch it. The whole golden encryptor is then
// ANCHORED to the two published FIPS-197 known-answer vectors before it is ever
// used to judge the DUT, so the reference itself is proven against the standard.
//
// Stimulus: the two FIPS-197 vectors + directed corners (all-zero / all-ones /
// key==pt / unit patterns) + randomized (key, plaintext) pairs. A watchdog
// $fatal-timeout guards every block, and a VCD is dumped for the waveform.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_aes128_enc;

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;               // 100 MHz

    // ---- DUT I/O ------------------------------------------------------------
    logic         start_i;
    logic [127:0] key_i, pt_i;
    wire          busy_o, done_o, valid_o;
    wire  [127:0] ct_o;

    aes128_enc dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .start_i(start_i),
        .key_i  (key_i),
        .pt_i   (pt_i),
        .busy_o (busy_o),
        .done_o (done_o),
        .valid_o(valid_o),
        .ct_o   (ct_o)
    );

    // ---- waveform probes into the DUT (depth-1 names for the plotter) -------
    wire [3:0]   w_round = dut.round_r;
    wire [127:0] w_state = dut.state_r;
    wire [127:0] w_key   = dut.key_r;

    // scoreboard
    int checks = 0;
    int errors = 0;

    // =========================================================================
    //  INDEPENDENT GOLDEN MODEL
    // =========================================================================
    logic [7:0] gsbox [0:255];          // S-box derived below, NOT copied

    // GF(2^8) multiply mod x^8+x^4+x^3+x+1 (0x11B)
    function automatic [7:0] gf_mul (input [7:0] a_in, input [7:0] b_in);
        logic [7:0] a, b, p;
        a = a_in; b = b_in; p = 8'h00;
        for (int i = 0; i < 8; i++) begin
            if (b[0]) p = p ^ a;
            b = b >> 1;
            if (a[7]) a = (a << 1) ^ 8'h1b;
            else      a = (a << 1);
        end
        return p;
    endfunction

    // multiplicative inverse in GF(2^8) by exhaustive search (inv(0)=0)
    function automatic [7:0] gf_inv (input [7:0] x);
        gf_inv = 8'h00;
        if (x != 8'h00)
            for (int y = 1; y < 256; y++)
                if (gf_mul(x, y[7:0]) == 8'h01) return y[7:0];
    endfunction

    function automatic [7:0] rotl8 (input [7:0] x, input int n);
        rotl8 = (x << n) | (x >> (8 - n));
    endfunction

    // derive the whole S-box: s = inv ^ rotl(inv,1..4) ^ 0x63
    task automatic build_sbox;
        logic [7:0] v, s;
        for (int i = 0; i < 256; i++) begin
            v = gf_inv(i[7:0]);
            s = v ^ rotl8(v,1) ^ rotl8(v,2) ^ rotl8(v,3) ^ rotl8(v,4) ^ 8'h63;
            gsbox[i] = s;
        end
    endtask

    // 32-bit word helpers for the key schedule
    function automatic [31:0] g_subword (input [31:0] w);
        g_subword = {gsbox[w[31:24]], gsbox[w[23:16]], gsbox[w[15:8]], gsbox[w[7:0]]};
    endfunction
    function automatic [31:0] g_rotword (input [31:0] w);
        g_rotword = {w[23:0], w[31:24]};
    endfunction
    function automatic [7:0] g_rcon (input int i);   // i = 1..10
        logic [7:0] c;
        c = 8'h01;
        for (int k = 1; k < i; k++)
            c = (c & 8'h80) ? ((c << 1) ^ 8'h1b) : (c << 1);
        return c;
    endfunction

    // byte get/set in FIPS order (byte 0 = MSB)
    function automatic [7:0] gbyte (input [127:0] s, input int i);
        gbyte = s[(15-i)*8 +: 8];
    endfunction

    function automatic [127:0] g_subbytes (input [127:0] s);
        for (int i = 0; i < 16; i++)
            g_subbytes[(15-i)*8 +: 8] = gsbox[gbyte(s,i)];
    endfunction

    function automatic [127:0] g_shiftrows (input [127:0] s);
        logic [7:0] o [0:15];
        for (int c = 0; c < 4; c++)
            for (int r = 0; r < 4; r++)
                o[r+4*c] = gbyte(s, r + 4*((c+r)%4));
        for (int i = 0; i < 16; i++)
            g_shiftrows[(15-i)*8 +: 8] = o[i];
    endfunction

    function automatic [127:0] g_mixcolumns (input [127:0] s);
        logic [7:0] a0,a1,a2,a3;
        for (int c = 0; c < 4; c++) begin
            a0=gbyte(s,4*c+0); a1=gbyte(s,4*c+1);
            a2=gbyte(s,4*c+2); a3=gbyte(s,4*c+3);
            g_mixcolumns[(15-(4*c+0))*8 +: 8] = gf_mul(2,a0)^gf_mul(3,a1)^a2^a3;
            g_mixcolumns[(15-(4*c+1))*8 +: 8] = a0^gf_mul(2,a1)^gf_mul(3,a2)^a3;
            g_mixcolumns[(15-(4*c+2))*8 +: 8] = a0^a1^gf_mul(2,a2)^gf_mul(3,a3);
            g_mixcolumns[(15-(4*c+3))*8 +: 8] = gf_mul(3,a0)^a1^a2^gf_mul(2,a3);
        end
    endfunction

    // full AES-128 encrypt (independent code path); key schedule inlined so the
    // model needs no array-valued subroutine ports (Icarus-friendly).
    function automatic [127:0] aes_encrypt (input [127:0] key, input [127:0] pt);
        logic [31:0]  w [0:43];
        logic [127:0] rk [0:10];
        logic [31:0]  t;
        logic [127:0] st;
        // key expansion -> 44 words -> 11 round keys
        w[0]=key[127:96]; w[1]=key[95:64]; w[2]=key[63:32]; w[3]=key[31:0];
        for (int i = 4; i < 44; i++) begin
            t = w[i-1];
            if (i % 4 == 0)
                t = g_subword(g_rotword(t)) ^ {g_rcon(i/4), 24'h000000};
            w[i] = w[i-4] ^ t;
        end
        for (int r = 0; r <= 10; r++)
            rk[r] = {w[4*r], w[4*r+1], w[4*r+2], w[4*r+3]};
        // rounds
        st = pt ^ rk[0];
        for (int r = 1; r <= 9; r++)
            st = g_mixcolumns(g_shiftrows(g_subbytes(st))) ^ rk[r];
        st = g_shiftrows(g_subbytes(st)) ^ rk[10];
        return st;
    endfunction

    // =========================================================================
    //  DRIVE + CHECK
    // =========================================================================
    task automatic run_block (input [127:0] key, input [127:0] pt,
                              input string tag);
        logic [127:0] exp;
        int wd;
        exp = aes_encrypt(key, pt);

        @(posedge clk);
        key_i   <= key;
        pt_i    <= pt;
        start_i <= 1'b1;
        @(posedge clk);
        start_i <= 1'b0;

        // watchdog: must finish within 40 clocks (spec latency is 11)
        wd = 0;
        while (!done_o) begin
            @(posedge clk);
            wd++;
            if (wd > 40) begin
                $fatal(1, "[%0t] TIMEOUT waiting for done_o on '%s'", $time, tag);
            end
        end

        checks++;
        if (ct_o !== exp) begin
            errors++;
            $error("MISMATCH [%s]\n  key=%032h\n  pt =%032h\n  got=%032h\n  exp=%032h",
                   tag, key, pt, ct_o, exp);
        end
    endtask

    // known-answer directed vectors (proven against FIPS-197 first)
    task automatic anchor_and_directed;
        logic [127:0] k, p, c;

        // ---- FIPS-197 App. B worked example -------------------------------
        k = 128'h2b7e151628aed2a6abf7158809cf4f3c;
        p = 128'h3243f6a8885a308d313198a2e0370734;
        c = 128'h3925841d02dc09fbdc118597196a0b32;
        if (aes_encrypt(k,p) !== c)
            $fatal(1, "GOLDEN MODEL failed FIPS-197 App.B anchor (got %032h)", aes_encrypt(k,p));
        checks++;                         // the model self-test counts as a check
        run_block(k, p, "FIPS-197 App.B");

        // ---- FIPS-197 App. C.1 (AES-128 example) --------------------------
        k = 128'h000102030405060708090a0b0c0d0e0f;
        p = 128'h00112233445566778899aabbccddeeff;
        c = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
        if (aes_encrypt(k,p) !== c)
            $fatal(1, "GOLDEN MODEL failed FIPS-197 App.C.1 anchor (got %032h)", aes_encrypt(k,p));
        checks++;
        run_block(k, p, "FIPS-197 App.C.1");

        // ---- directed corners --------------------------------------------
        run_block(128'h0, 128'h0, "all-zero");
        run_block({4{32'hffffffff}}, {4{32'hffffffff}}, "all-ones");
        run_block(128'h000102030405060708090a0b0c0d0e0f,
                  128'h000102030405060708090a0b0c0d0e0f, "key==pt");
        run_block(128'h1, 128'h0, "unit-key-lsb");
        run_block(128'h0, 128'h80000000000000000000000000000000, "unit-pt-msb");
        run_block(128'hffffffffffffffff0000000000000000,
                  128'h0f0f0f0f0f0f0f0ff0f0f0f0f0f0f0f0, "split-pattern");
    endtask

    // =========================================================================
    //  MAIN
    // =========================================================================
    localparam int NRAND = 500;

    initial begin
        $dumpfile("aes128_enc.vcd");
        $dumpvars(0, tb_aes128_enc);

        build_sbox;

        // reset
        start_i = 1'b0;
        key_i   = '0;
        pt_i    = '0;
        rst_n   = 1'b0;
        repeat (4) @(posedge clk);
        rst_n   = 1'b1;
        @(posedge clk);

        // directed + anchors
        anchor_and_directed;

        // randomized
        for (int t = 0; t < NRAND; t++) begin
            logic [127:0] rk, rp;
            rk = {$random,$random,$random,$random};
            rp = {$random,$random,$random,$random};
            run_block(rk, rp, $sformatf("rand#%0d", t));
        end

        // ---- report -------------------------------------------------------
        $display("--------------------------------------------------------");
        $display("AES-128 encryption core : %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $display("--------------------------------------------------------");
        $finish;
    end

    // global safety watchdog
    initial begin
        #500000;
        $fatal(1, "GLOBAL TIMEOUT: simulation did not finish");
    end

endmodule

`default_nettype wire
