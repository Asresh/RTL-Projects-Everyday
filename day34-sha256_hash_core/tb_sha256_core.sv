// =============================================================================
// Day 34 : tb_sha256_core -- self-checking testbench for the SHA-256 core
// -----------------------------------------------------------------------------
// Strategy
//   * An INDEPENDENT golden SHA-256 model lives in the TB. It is structurally
//     different from the DUT: it materialises the FULL 64-word message schedule
//     W[0..63] in an array (the DUT keeps only a rolling 16-word window), so a
//     bug in the DUT's window recurrence cannot be masked by a matching bug in
//     the reference.
//   * The golden model is ANCHORED to the three canonical FIPS 180-4 / NIST
//     known-answer tests via $fatal BEFORE it is ever trusted to judge the DUT:
//       ""                                   -> e3b0c442...7852b855
//       "abc"                                -> ba7816bf...f20015ad
//       56-byte "abcdbcde...nomnopnopq"      -> 248d6a61...19db06c1  (2 blocks)
//   * For every stimulus message the TB pads it into 512-bit blocks, streams the
//     blocks through the DUT (first_i on block 0, chaining the rest) and checks
//     the final digest_o against the golden digest.
//   * Directed corners (empty, single/partial/exactly-full blocks, multi-block
//     KATs) + 300 random messages of random length. Per-block + global timeouts.
//     A VCD is dumped so the waveform image is a REAL captured trace.
// =============================================================================
`timescale 1ns/1ps

module tb_sha256_core;

    // ---- DUT I/O ------------------------------------------------------------
    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          start_i = 1'b0;
    reg          first_i = 1'b0;
    reg  [511:0] block_i = '0;
    wire         busy_o;
    wire         done_o;
    wire         valid_o;
    wire [255:0] digest_o;

    integer checks = 0;
    integer errors = 0;

    sha256_core dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .start_i (start_i),
        .first_i (first_i),
        .block_i (block_i),
        .busy_o  (busy_o),
        .done_o  (done_o),
        .valid_o (valid_o),
        .digest_o(digest_o)
    );

    always #5 clk = ~clk;                       // 100 MHz

    // =====================================================================
    //  Independent golden SHA-256 model (full 64-word schedule)
    // =====================================================================
    function logic [31:0] grotr(input logic [31:0] x, input int n);
        grotr = (x >> n) | (x << (32 - n));
    endfunction
    function logic [31:0] gbs0(input logic [31:0] x);
        gbs0 = grotr(x,2) ^ grotr(x,13) ^ grotr(x,22);
    endfunction
    function logic [31:0] gbs1(input logic [31:0] x);
        gbs1 = grotr(x,6) ^ grotr(x,11) ^ grotr(x,25);
    endfunction
    function logic [31:0] gss0(input logic [31:0] x);
        gss0 = grotr(x,7) ^ grotr(x,18) ^ (x >> 3);
    endfunction
    function logic [31:0] gss1(input logic [31:0] x);
        gss1 = grotr(x,17) ^ grotr(x,19) ^ (x >> 10);
    endfunction
    function logic [31:0] gk(input int t);
        case (t)
            0:gk=32'h428a2f98; 1:gk=32'h71374491; 2:gk=32'hb5c0fbcf; 3:gk=32'he9b5dba5;
            4:gk=32'h3956c25b; 5:gk=32'h59f111f1; 6:gk=32'h923f82a4; 7:gk=32'hab1c5ed5;
            8:gk=32'hd807aa98; 9:gk=32'h12835b01; 10:gk=32'h243185be; 11:gk=32'h550c7dc3;
            12:gk=32'h72be5d74; 13:gk=32'h80deb1fe; 14:gk=32'h9bdc06a7; 15:gk=32'hc19bf174;
            16:gk=32'he49b69c1; 17:gk=32'hefbe4786; 18:gk=32'h0fc19dc6; 19:gk=32'h240ca1cc;
            20:gk=32'h2de92c6f; 21:gk=32'h4a7484aa; 22:gk=32'h5cb0a9dc; 23:gk=32'h76f988da;
            24:gk=32'h983e5152; 25:gk=32'ha831c66d; 26:gk=32'hb00327c8; 27:gk=32'hbf597fc7;
            28:gk=32'hc6e00bf3; 29:gk=32'hd5a79147; 30:gk=32'h06ca6351; 31:gk=32'h14292967;
            32:gk=32'h27b70a85; 33:gk=32'h2e1b2138; 34:gk=32'h4d2c6dfc; 35:gk=32'h53380d13;
            36:gk=32'h650a7354; 37:gk=32'h766a0abb; 38:gk=32'h81c2c92e; 39:gk=32'h92722c85;
            40:gk=32'ha2bfe8a1; 41:gk=32'ha81a664b; 42:gk=32'hc24b8b70; 43:gk=32'hc76c51a3;
            44:gk=32'hd192e819; 45:gk=32'hd6990624; 46:gk=32'hf40e3585; 47:gk=32'h106aa070;
            48:gk=32'h19a4c116; 49:gk=32'h1e376c08; 50:gk=32'h2748774c; 51:gk=32'h34b0bcb5;
            52:gk=32'h391c0cb3; 53:gk=32'h4ed8aa4a; 54:gk=32'h5b9cca4f; 55:gk=32'h682e6ff3;
            56:gk=32'h748f82ee; 57:gk=32'h78a5636f; 58:gk=32'h84c87814; 59:gk=32'h8cc70208;
            60:gk=32'h90befffa; 61:gk=32'ha4506ceb; 62:gk=32'hbef9a3f7; 63:gk=32'hc67178f2;
            default: gk = 32'h0;
        endcase
    endfunction

    // pad a byte message into 512-bit blocks (SHA-256 / MD padding), returned in
    // the module scratch array pad_blk[0..pad_nb-1]. Used by BOTH the golden
    // model and the DUT driver (padding is not the DUT's job -- it absorbs
    // already-padded blocks -- and the KAT anchors validate the whole chain).
    logic [511:0] pad_blk [0:4095];
    integer       pad_nb;
    logic [255:0] gold;                         // golden digest of module `msg`
    byte          msg [$];                       // current stimulus message bytes

    // pads the module-level `msg` byte queue into pad_blk[0..pad_nb-1].
    // (Icarus can't pass a queue by value to a function, so the message travels
    //  through the module-level `msg` queue instead of an argument.)
    task pad_message();
        byte             pb [$];
        longint unsigned ml;
        integer          j, base, blk;
        logic [31:0]     word;
        pb = {};
        foreach (msg[j]) pb.push_back(msg[j]);
        ml = longint'(msg.size()) * 64'd8;      // message length in BITS
        pb.push_back(8'h80);                    // append the '1' bit + 7 zeros
        while (pb.size() % 64 != 56) pb.push_back(8'h00);
        for (j = 7; j >= 0; j = j - 1)          // 64-bit big-endian bit length
            pb.push_back(ml[j*8 +: 8]);
        pad_nb = pb.size() / 64;
        for (blk = 0; blk < pad_nb; blk = blk + 1) begin
            pad_blk[blk] = '0;
            for (j = 0; j < 16; j = j + 1) begin
                base = blk*64 + j*4;
                word = {pb[base], pb[base+1], pb[base+2], pb[base+3]};
                pad_blk[blk][511 - j*32 -: 32] = word;
            end
        end
    endtask

    // fully independent golden digest of the module-level `msg` -> `gold`.
    // Re-implements padding locally (shares NO state path with pad_message) and
    // uses the FULL 64-word schedule (vs the DUT's rolling 16-word window).
    task sha256_model();
        byte             pb [$];
        longint unsigned ml;
        integer          j, base, blk, nb, t;
        logic [31:0]     W [0:63];
        logic [31:0]     H0,H1,H2,H3,H4,H5,H6,H7;
        logic [31:0]     a,b,c,d,e,f,g,h,T1,T2;
        pb = {};
        foreach (msg[j]) pb.push_back(msg[j]);
        ml = longint'(msg.size()) * 64'd8;
        pb.push_back(8'h80);
        while (pb.size() % 64 != 56) pb.push_back(8'h00);
        for (j = 7; j >= 0; j = j - 1) pb.push_back(ml[j*8 +: 8]);
        nb = pb.size() / 64;
        H0=32'h6a09e667; H1=32'hbb67ae85; H2=32'h3c6ef372; H3=32'ha54ff53a;
        H4=32'h510e527f; H5=32'h9b05688c; H6=32'h1f83d9ab; H7=32'h5be0cd19;
        for (blk = 0; blk < nb; blk = blk + 1) begin
            for (t = 0; t < 16; t = t + 1) begin
                base = blk*64 + t*4;
                W[t] = {pb[base], pb[base+1], pb[base+2], pb[base+3]};
            end
            for (t = 16; t < 64; t = t + 1)
                W[t] = gss1(W[t-2]) + W[t-7] + gss0(W[t-15]) + W[t-16];
            a=H0; b=H1; c=H2; d=H3; e=H4; f=H5; g=H6; h=H7;
            for (t = 0; t < 64; t = t + 1) begin
                T1 = h + gbs1(e) + ((e & f) ^ (~e & g)) + gk(t) + W[t];
                T2 = gbs0(a) + ((a & b) ^ (a & c) ^ (b & c));
                h=g; g=f; f=e; e=d+T1; d=c; c=b; b=a; a=T1+T2;
            end
            H0+=a; H1+=b; H2+=c; H3+=d; H4+=e; H5+=f; H6+=g; H7+=h;
        end
        gold = {H0,H1,H2,H3,H4,H5,H6,H7};
    endtask

    // =====================================================================
    //  DUT driver + scoreboard
    // =====================================================================
    task drive_block(input logic [511:0] blk, input logic first);
        integer guard;
        @(negedge clk);
        block_i <= blk;
        first_i <= first;
        start_i <= 1'b1;
        @(negedge clk);
        start_i <= 1'b0;
        first_i <= 1'b0;
        // wait for done_o (deterministic 66 clocks -- guard well above that)
        guard = 0;
        while (done_o !== 1'b1) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 200)
                $fatal(1, "[%0t] TIMEOUT waiting for done_o", $time);
        end
        @(negedge clk);
    endtask

    // hash the module-level `msg` through the DUT and compare vs golden model
    task check(input string name);
        logic [255:0] got;
        integer       blk;
        sha256_model();                         // -> gold
        pad_message();                          // -> pad_blk / pad_nb
        for (blk = 0; blk < pad_nb; blk = blk + 1)
            drive_block(pad_blk[blk], (blk == 0));
        got = digest_o;
        checks = checks + 1;
        if (got !== gold) begin
            errors = errors + 1;
            $display("  [FAIL] %-28s len=%0d blocks=%0d", name, msg.size(), pad_nb);
            $display("         exp=%064h", gold);
            $display("         got=%064h", got);
        end else begin
            $display("  [ ok ] %-28s len=%0d blocks=%0d  %08h...", name,
                     msg.size(), pad_nb, got[255:224]);
        end
    endtask

    // =====================================================================
    //  Stimulus
    // =====================================================================
    integer it, len, k;

    // fill the module-level `msg` queue from an ASCII string literal
    task load_str(input string s);
        integer i;
        msg = {};
        for (i = 0; i < s.len(); i = i + 1) msg.push_back(s[i]);
    endtask

    initial begin
        $dumpfile("sha256_core.vcd");
        $dumpvars(0, tb_sha256_core);

        // ---- anchor the golden model to published NIST KATs -------------
        // "abc"
        load_str("abc"); sha256_model();
        if (gold !== 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad)
            $fatal(1, "GOLDEN MODEL failed NIST KAT \"abc\" (got %064h)", gold);
        // empty string
        msg = {}; sha256_model();
        if (gold !== 256'he3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855)
            $fatal(1, "GOLDEN MODEL failed NIST KAT \"\" (got %064h)", gold);
        // 56-byte two-block KAT
        load_str("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"); sha256_model();
        if (gold !== 256'h248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1)
            $fatal(1, "GOLDEN MODEL failed NIST 2-block KAT (got %064h)", gold);
        $display("Golden model anchored to 3 NIST known-answer tests: OK");

        // ---- reset ------------------------------------------------------
        rst_n = 1'b0;
        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        $display("---- directed messages ----");
        // empty message (single all-padding block)
        msg = {}; check("empty");
        // classic single-block KAT
        load_str("abc");                        check("\"abc\"");
        // one byte
        msg = {8'h61};                          check("single 'a'");
        // 55 bytes: largest single-block message (55 + 0x80 + 8 = 64)
        msg = {}; for (k=0;k<55;k=k+1) msg.push_back(8'h41+(k%26)); check("55B (fits 1 block)");
        // 56 bytes: smallest TWO-block message (the length no longer fits)
        load_str("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq");
        check("56B 2-block KAT");
        // 64 bytes: exactly one full data block + a full padding block
        msg = {}; for (k=0;k<64;k=k+1) msg.push_back(8'h30+(k%10)); check("64B (exact block)");
        // 112-byte 2-block KAT (896-bit message)
        load_str("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu");
        check("112B 2-block KAT");
        // all-zero 200-byte message (multi-block, tests carry/chaining)
        msg = {}; for (k=0;k<200;k=k+1) msg.push_back(8'h00); check("200B zeros");
        // all-0xFF 130-byte message
        msg = {}; for (k=0;k<130;k=k+1) msg.push_back(8'hFF); check("130B ones");

        $display("---- 300 random messages (random length, random bytes) ----");
        for (it = 0; it < 300; it = it + 1) begin
            len = $urandom_range(0, 300);
            msg = {};
            for (k = 0; k < len; k = k + 1) msg.push_back($urandom_range(0,255));
            check($sformatf("rand#%0d", it));
        end

        $display("========================================================");
        $display("SHA-256 hash core : %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- global watchdog ----------------------------------------------------
    initial begin
        #50_000_000;
        $fatal(1, "GLOBAL TIMEOUT: simulation did not finish");
    end

endmodule
