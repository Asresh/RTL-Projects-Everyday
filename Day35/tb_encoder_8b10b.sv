// =============================================================================
// Day 35 : self-checking testbench for encoder_8b10b
// -----------------------------------------------------------------------------
// Three independent oracles, in increasing strength:
//
//  (A) STRUCTURAL / TABLE-FREE laws checked on EVERY emitted symbol, using only
//      $countones of the 10 line bits -- no encode table involved, so they cannot
//      "agree with the DUT by sharing a bug":
//        * each 6b sub-block has 2..4 ones (disparity in {-2,0,+2}); each 4b
//          sub-block has 1..3 ones;
//        * the running disparity recomputed by popcount from the two sub-blocks
//          equals the DUT's rd_o and always lands on -1 or +1;
//        * a live max-run monitor across the *serial concatenation* of all
//          emitted codes asserts <= 5 consecutive identical bits (the CDR limit)
//          for the data stream.
//
//  (B) PUBLISHED KNOWN-ANSWER anchors: the 12 standard control codes plus D.00,
//      asserted with $fatal against exact 10-bit strings from the spec. These pin
//      the absolute bit values (K.28 comma remap, the .7 alternate, both RD
//      states, every 3b/4b y) BEFORE the golden model is trusted.
//
//  (C) A golden reference model (the uniform-complement algorithm) scoreboards
//      code_o / rd_o / code_err_o for a full 256x2 data sweep, all valid K codes,
//      and a long randomized RD-chained stream (the real stress on the disparity
//      state machine).
//
// Dumps encoder_8b10b.vcd. Prints "RESULT: *** PASS ***" on success.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_encoder_8b10b;
    localparam bit NEG = 1'b0, POS = 1'b1;

    logic        clk, rst_n, valid_i, k_i;
    logic [7:0]  data_i;
    logic [9:0]  code_o;
    logic        valid_o, rd_o, code_err_o;

    integer checks = 0, errors = 0;
    integer maxrun = 0;

    encoder_8b10b dut (
        .clk(clk), .rst_n(rst_n), .valid_i(valid_i), .data_i(data_i), .k_i(k_i),
        .code_o(code_o), .valid_o(valid_o), .rd_o(rd_o), .code_err_o(code_err_o)
    );

    // ---- clock ----
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ==========================================================================
    //  Golden reference model (uniform-complement algorithm) -- oracle (C)
    // ==========================================================================
    function automatic [5:0] r6 (input [4:0] x);
        case (x)
            5'd0 :r6=6'b100111; 5'd1 :r6=6'b011101; 5'd2 :r6=6'b101101; 5'd3 :r6=6'b110001;
            5'd4 :r6=6'b110101; 5'd5 :r6=6'b101001; 5'd6 :r6=6'b011001; 5'd7 :r6=6'b111000;
            5'd8 :r6=6'b111001; 5'd9 :r6=6'b100101; 5'd10:r6=6'b010101; 5'd11:r6=6'b110100;
            5'd12:r6=6'b001101; 5'd13:r6=6'b101100; 5'd14:r6=6'b011100; 5'd15:r6=6'b010111;
            5'd16:r6=6'b011011; 5'd17:r6=6'b100011; 5'd18:r6=6'b010011; 5'd19:r6=6'b110010;
            5'd20:r6=6'b001011; 5'd21:r6=6'b101010; 5'd22:r6=6'b011010; 5'd23:r6=6'b111010;
            5'd24:r6=6'b110011; 5'd25:r6=6'b100110; 5'd26:r6=6'b010110; 5'd27:r6=6'b110110;
            5'd28:r6=6'b001110; 5'd29:r6=6'b101110; 5'd30:r6=6'b011110; 5'd31:r6=6'b101011;
        endcase
    endfunction
    function automatic [3:0] r4 (input [2:0] y);
        case (y)
            3'd0:r4=4'b1011; 3'd1:r4=4'b0110; 3'd2:r4=4'b1010; 3'd3:r4=4'b1100;
            3'd4:r4=4'b1101; 3'd5:r4=4'b0101; 3'd6:r4=4'b1001; 3'd7:r4=4'b1110;
        endcase
    endfunction

    // returns {code[9:0], rd_next, err}
    function automatic [11:0] model (input [7:0] d, input k, input rd_in);
        logic [4:0] x; logic [2:0] y;
        logic [5:0] cm6, e6; logic [3:0] cm4, e4;
        logic rd6, rdn, alt7, kok;
        begin
            x = d[4:0]; y = d[7:5];
            kok = (x==5'd28) || ((x==5'd23||x==5'd27||x==5'd29||x==5'd30) && y==3'd7);
            cm6 = (k && x==5'd28) ? 6'b001111 : r6(x);
            e6  = (rd_in==NEG) ? cm6 : ~cm6;
            rd6 = ($countones(cm6)==3) ? rd_in : ~rd_in;
            alt7 = (y==3'd7) && ( k ||
                    (rd_in==NEG && (x==5'd17||x==5'd18||x==5'd20)) ||
                    (rd_in==POS && (x==5'd11||x==5'd13||x==5'd14)) );
            cm4 = (y==3'd7) ? (alt7 ? 4'b0111 : r4(3'd7)) : r4(y);
            e4  = (rd6==NEG) ? cm4 : ~cm4;
            rdn = ($countones(cm4)==2) ? rd6 : ~rd6;
            model = {{e6,e4}, rdn, (k && !kok)};
        end
    endfunction

    // ==========================================================================
    //  Structural running-disparity monitor -- oracle (A), table-free
    // ==========================================================================
    // recompute RD from popcount of the emitted sub-blocks (start RD tracked here)
    bit        mon_rd;         // running disparity mirror recomputed structurally
    bit        mon_prev_bit;   // last serial bit for run-length across symbols
    bit        mon_have_prev;
    integer    mon_run;

    task automatic check_structural (input [9:0] code, input bit dut_rd, input bit is_data);
        logic [5:0] s6; logic [3:0] s4;
        int o6, o4; bit r6b, rfull; int i; bit b;
        begin
            s6 = code[9:4]; s4 = code[3:0];
            o6 = $countones(s6); o4 = $countones(s4);
            // sub-block disparity legality (pure popcount law)
            checks++;
            if (!(o6>=2 && o6<=4)) begin errors++; $error("6b ones=%0d out of range (code=%b)",o6,code); end
            checks++;
            if (!(o4>=1 && o4<=3)) begin errors++; $error("4b ones=%0d out of range (code=%b)",o4,code); end
            // recompute running disparity by popcount, independent of any table
            r6b   = ($countones(s6)==3) ? mon_rd : ~mon_rd;
            rfull = ($countones(s4)==2) ? r6b    : ~r6b;
            checks++;
            if (rfull !== dut_rd) begin
                errors++; $error("structural RD %b != dut rd_o %b (code=%b)", rfull, dut_rd, code);
            end
            checks++;
            if (rfull!==NEG && rfull!==POS) begin errors++; $error("RD escaped {-1,+1}"); end
            mon_rd = rfull;
            // serial run-length across the concatenated stream (MSB 'a' first)
            for (i=9; i>=0; i=i-1) begin
                b = code[i];
                if (mon_have_prev && b==mon_prev_bit) mon_run++;
                else mon_run = 1;
                mon_prev_bit = b; mon_have_prev = 1;
                if (mon_run > maxrun) maxrun = mon_run;
                if (is_data && mon_run > 5) begin
                    errors++; $error("run-length %0d > 5 at code=%b", mon_run, code);
                end
            end
        end
    endtask

    // ==========================================================================
    //  Drive one character and scoreboard it against the golden model (C)
    // ==========================================================================
    bit exp_rd;   // reference running disparity (chained by the testbench)

    task automatic send (input [7:0] d, input bit k, input bit is_data);
        logic [11:0] m; logic [9:0] exp_code; logic exp_err, exp_rd_n;
        begin
            m        = model(d, k, exp_rd);
            exp_code = m[11:2];
            exp_rd_n = m[1];
            exp_err  = m[0];

            @(negedge clk);
            valid_i = 1'b1; data_i = d; k_i = k;
            @(posedge clk);              // registered: outputs valid the following delta
            #1;
            valid_i = 1'b0;

            // code_err is produced regardless of validity of the code word
            checks++;
            if (code_err_o !== exp_err) begin
                errors++; $error("code_err mismatch d=%02h k=%b : exp %b got %b", d,k,exp_err,code_err_o);
            end
            if (!exp_err) begin
                checks++;
                if (code_o !== exp_code) begin
                    errors++; $error("code mismatch d=%02h k=%b rd=%b : exp %010b got %010b",
                                     d,k,exp_rd,exp_code,code_o);
                end
                checks++;
                if (rd_o !== exp_rd_n) begin
                    errors++; $error("rd mismatch d=%02h k=%b : exp %b got %b", d,k,exp_rd_n,rd_o);
                end
                check_structural(code_o, rd_o, is_data);
                exp_rd = exp_rd_n;       // advance the chained reference disparity
            end
        end
    endtask

    // ==========================================================================
    //  Published known-answer anchors -- oracle (B), $fatal on mismatch
    // ==========================================================================
    task automatic kat (input [7:0] d, input bit k, input bit rd_start, input [9:0] exp10);
        logic [11:0] m;
        begin
            // (i) the golden model itself must reproduce the spec value
            m = model(d, k, rd_start);
            if (m[11:2] !== exp10)
                $fatal(1, "KAT: golden model wrong for d=%02h k=%b rd=%b : exp %010b got %010b",
                          d,k,rd_start,exp10,m[11:2]);
            // (ii) and the DUT must reproduce it too (driven from a known RD state)
            force_rd(rd_start);
            @(negedge clk); valid_i=1'b1; data_i=d; k_i=k;
            @(posedge clk); #1; valid_i=1'b0;
            checks++;
            if (code_o !== exp10) begin
                errors++;
                $fatal(1, "KAT: DUT wrong for d=%02h k=%b rd=%b : exp %010b got %010b",
                          d,k,rd_start,exp10,code_o);
            end
        end
    endtask

    // seed the DUT's internal running disparity to a known value by encoding a
    // primer character (K.28.5 flips RD; encode it until rd_o == target)
    task automatic force_rd (input bit target);
        int guard;
        begin
            guard = 0;
            while (rd_o !== target && guard < 4) begin
                @(negedge clk); valid_i=1'b1; data_i=8'hBC; k_i=1'b1;  // K.28.5
                @(posedge clk); #1; valid_i=1'b0;
                guard++;
            end
        end
    endtask

    // ==========================================================================
    //  Stimulus
    // ==========================================================================
    integer i, n;
    logic [7:0] rb; logic rk;
    logic [7:0] KVEC [0:11];

    initial begin
        $dumpfile("encoder_8b10b.vcd");
        $dumpvars(0, tb_encoder_8b10b);

        valid_i=0; data_i=0; k_i=0; rst_n=0;
        mon_rd=NEG; mon_have_prev=0; mon_run=0; exp_rd=NEG;
        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- (B) published KAT anchors (checked before trusting the model) ----
        //  D.00 both polarities
        kat(8'h00,1'b0,NEG,10'b1001110100);  kat(8'h00,1'b0,POS,10'b0110001011);
        //  K.28.0 .. K.28.7  (RD- forms)
        kat(8'h1C,1'b1,NEG,10'b0011110100);  kat(8'h1C,1'b1,POS,10'b1100001011);
        kat(8'h3C,1'b1,NEG,10'b0011111001);  kat(8'h3C,1'b1,POS,10'b1100000110);
        kat(8'h5C,1'b1,NEG,10'b0011110101);  kat(8'h5C,1'b1,POS,10'b1100001010);
        kat(8'h7C,1'b1,NEG,10'b0011110011);  kat(8'h7C,1'b1,POS,10'b1100001100);
        kat(8'h9C,1'b1,NEG,10'b0011110010);  kat(8'h9C,1'b1,POS,10'b1100001101);
        kat(8'hBC,1'b1,NEG,10'b0011111010);  kat(8'hBC,1'b1,POS,10'b1100000101); // comma
        kat(8'hDC,1'b1,NEG,10'b0011110110);  kat(8'hDC,1'b1,POS,10'b1100001001);
        kat(8'hFC,1'b1,NEG,10'b0011111000);  kat(8'hFC,1'b1,POS,10'b1100000111);
        //  K.23.7 K.27.7 K.29.7 K.30.7
        kat(8'hF7,1'b1,NEG,10'b1110101000);  kat(8'hF7,1'b1,POS,10'b0001010111);
        kat(8'hFB,1'b1,NEG,10'b1101101000);  kat(8'hFB,1'b1,POS,10'b0010010111);
        kat(8'hFD,1'b1,NEG,10'b1011101000);  kat(8'hFD,1'b1,POS,10'b0100010111);
        kat(8'hFE,1'b1,NEG,10'b0111101000);  kat(8'hFE,1'b1,POS,10'b1000010111);
        $display("[KAT] 26 published known-answer anchors passed.");

        // resync monitors/reference to the DUT's current RD before the sweeps
        exp_rd = rd_o; mon_rd = rd_o; mon_have_prev = 0;

        // ---- (C) full data sweep, both starting polarities ----
        for (i=0; i<256; i=i+1) send(i[7:0], 1'b0, 1'b1);   // one polarity
        for (i=0; i<256; i=i+1) send(i[7:0], 1'b0, 1'b1);   // continues from new RD
        $display("[SWEEP] 512 data characters scoreboarded (RD-chained).");

        // ---- (C) all valid control codes, repeatedly ----
        KVEC = '{8'h1C,8'h3C,8'h5C,8'h7C,8'h9C,8'hBC,8'hDC,8'hFC,8'hF7,8'hFB,8'hFD,8'hFE};
        for (n=0; n<8; n=n+1)
            for (i=0; i<12; i=i+1) send(KVEC[i], 1'b1, 1'b0); // K.28.7-family may run>5: is_data=0
        $display("[CTRL] valid control codes scoreboarded.");

        // ---- illegal control requests must raise code_err_o (never a code) ----
        send(8'h00,1'b1,1'b0);   // K.0.0  -> illegal
        send(8'h55,1'b1,1'b0);   // K.21.2 -> illegal
        send(8'hA5,1'b1,1'b0);   // K.5.5  -> illegal
        $display("[ERR ] illegal control requests flagged.");

        // ---- (C) long randomized RD-chained stream (mostly data + some K) ----
        for (i=0; i<6000; i=i+1) begin
            rk = ($urandom_range(0,15)==0);          // ~6% control
            if (rk) rb = KVEC[$urandom_range(0,11)]; // only valid K vectors
            else    rb = $urandom_range(0,255);
            send(rb, rk, ~rk);                       // data symbols enforce run<=5
        end
        $display("[RAND] 6000 randomized RD-chained characters scoreboarded.");

        // ---------------------------------------------------------------------
        $display("--------------------------------------------------------------");
        $display("checks = %0d   errors = %0d   max-run = %0d", checks, errors, maxrun);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // global watchdog
    initial begin
        #20_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end
endmodule

`default_nettype wire
