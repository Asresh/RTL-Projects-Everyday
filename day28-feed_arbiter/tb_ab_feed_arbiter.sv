// ---------------------------------------------------------------------------
// Day 28 : Self-checking testbench for the A/B feed arbiter
// ---------------------------------------------------------------------------
// An INDEPENDENT golden reference re-implements the arbiter policy from the
// spec (dedup + reorder window + bounded-timeout gap skip) using plain arrays
// and a straight-line procedural update -- a structure deliberately unlike the
// DUT's registered combinational cone. Because the DUT registers its outputs,
// the reference outputs are compared one clock after the driving inputs (a
// 1-deep pipeline). Every cycle checks: out_valid/out_seq/out_data, gap_o/
// gap_seq_o, far_o and expected_o; the perf counters are checked at the end.
//
// Coverage: directed corners (in-order forward, A/B duplicate suppression,
// out-of-order reorder, redundancy cover of a single-line drop, genuine gap +
// timeout skip, beyond-window far drop, stale duplicate) then a 4000-cycle
// randomized soak biased around the live `expected` so forwards, dups, gaps
// and far drops all occur. A timeout watchdog fails loudly.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_ab_feed_arbiter;

    localparam int SEQ_W       = 16;
    localparam int DATA_W      = 32;
    localparam int WIN_LOG2    = 3;
    localparam int WIN         = (1 << WIN_LOG2);
    localparam int GAP_TIMEOUT = 4;
    localparam int STAT_W      = 32;

    // ---- DUT I/O ---------------------------------------------------------
    reg                  clk, rst;
    reg                  a_valid;  reg [SEQ_W-1:0]  a_seq;  reg [DATA_W-1:0] a_data;
    reg                  b_valid;  reg [SEQ_W-1:0]  b_seq;  reg [DATA_W-1:0] b_data;

    wire                 out_valid; wire [SEQ_W-1:0] out_seq; wire [DATA_W-1:0] out_data;
    wire                 gap_o;     wire [SEQ_W-1:0] gap_seq_o;
    wire                 far_o;
    wire [SEQ_W-1:0]     expected_o;
    wire [STAT_W-1:0]    stat_fwd_o, stat_dup_o, stat_gap_o;

    ab_feed_arbiter #(
        .SEQ_W(SEQ_W), .DATA_W(DATA_W), .WIN_LOG2(WIN_LOG2),
        .GAP_TIMEOUT(GAP_TIMEOUT), .STAT_W(STAT_W)
    ) dut (
        .clk(clk), .rst(rst),
        .a_valid(a_valid), .a_seq(a_seq), .a_data(a_data),
        .b_valid(b_valid), .b_seq(b_seq), .b_data(b_data),
        .out_valid(out_valid), .out_seq(out_seq), .out_data(out_data),
        .gap_o(gap_o), .gap_seq_o(gap_seq_o), .far_o(far_o),
        .expected_o(expected_o),
        .stat_fwd_o(stat_fwd_o), .stat_dup_o(stat_dup_o), .stat_gap_o(stat_gap_o)
    );

    // ---- clock -----------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- Golden reference model state ------------------------------------
    reg              m_v [0:WIN-1];
    reg [SEQ_W-1:0]  m_s [0:WIN-1];
    reg [DATA_W-1:0] m_d [0:WIN-1];
    reg [SEQ_W-1:0]  m_expected;
    reg [31:0]       m_timer;

    // next-state scratch produced by ref_compute
    reg              rn_v [0:WIN-1];
    reg [SEQ_W-1:0]  rn_s [0:WIN-1];
    reg [DATA_W-1:0] rn_d [0:WIN-1];
    reg [SEQ_W-1:0]  rn_expected;
    reg [31:0]       rn_timer;

    // reference outputs for the driving inputs
    reg              r_valid;  reg [SEQ_W-1:0] r_seq;  reg [DATA_W-1:0] r_data;
    reg              r_gap;    reg [SEQ_W-1:0] r_gapseq;
    reg              r_far;
    integer          r_fwd, r_dup, r_gapc;

    // expected running totals
    integer          exp_fwd, exp_dup, exp_gap;

    integer          checks, errors;

    integer          gi;

    // ---- reference transition (pure function of pre-edge state + inputs) --
    task ref_compute(input av, input [SEQ_W-1:0] aseq, input [DATA_W-1:0] adata,
                     input bv, input [SEQ_W-1:0] bseq, input [DATA_W-1:0] bdata);
        reg [1:0]          fvld;
        reg [SEQ_W-1:0]    fsq [0:1];
        reg [DATA_W-1:0]   fdt [0:1];
        reg [SEQ_W-1:0]    off;
        reg [WIN_LOG2-1:0] idx, eidx;
        reg                any_ahead;
        integer            k, ff;
        begin
            for (k = 0; k < WIN; k = k + 1) begin
                rn_v[k] = m_v[k]; rn_s[k] = m_s[k]; rn_d[k] = m_d[k];
            end
            rn_expected = m_expected;
            rn_timer    = m_timer;
            r_valid = 1'b0; r_seq = '0; r_data = '0;
            r_gap = 1'b0; r_gapseq = '0; r_far = 1'b0;
            r_fwd = 0; r_dup = 0; r_gapc = 0;

            fvld[0] = av; fsq[0] = aseq; fdt[0] = adata;
            fvld[1] = bv; fsq[1] = bseq; fdt[1] = bdata;

            // ingest line A (0) then line B (1)
            for (ff = 0; ff < 2; ff = ff + 1) begin
                if (fvld[ff]) begin
                    off = fsq[ff] - m_expected;
                    idx = fsq[ff][WIN_LOG2-1:0];
                    if (off < WIN) begin
                        if (rn_v[idx]) r_dup = r_dup + 1;
                        else begin
                            rn_v[idx] = 1'b1; rn_s[idx] = fsq[ff]; rn_d[idx] = fdt[ff];
                        end
                    end else if (off[SEQ_W-1]) begin
                        r_dup = r_dup + 1;              // behind expected -> stale dup
                    end else begin
                        r_far = 1'b1;                  // beyond window -> dropped
                    end
                end
            end

            // drain / gap
            eidx = rn_expected[WIN_LOG2-1:0];
            if (rn_v[eidx]) begin
                r_valid = 1'b1; r_seq = rn_s[eidx]; r_data = rn_d[eidx];
                rn_v[eidx] = 1'b0;
                rn_expected = rn_expected + 1'b1;
                rn_timer = 0;
                r_fwd = 1;
            end else begin
                any_ahead = 1'b0;
                for (k = 0; k < WIN; k = k + 1)
                    if (rn_v[k]) any_ahead = 1'b1;
                if (any_ahead) begin
                    if (rn_timer >= (GAP_TIMEOUT - 1)) begin
                        r_gap = 1'b1; r_gapseq = rn_expected;
                        rn_expected = rn_expected + 1'b1;
                        rn_timer = 0;
                        r_gapc = 1;
                    end else begin
                        rn_timer = rn_timer + 1;
                    end
                end else begin
                    rn_timer = 0;
                end
            end
        end
    endtask

    task commit_model;
        integer k;
        begin
            for (k = 0; k < WIN; k = k + 1) begin
                m_v[k] = rn_v[k]; m_s[k] = rn_s[k]; m_d[k] = rn_d[k];
            end
            m_expected = rn_expected;
            m_timer    = rn_timer;
            exp_fwd = exp_fwd + r_fwd;
            exp_dup = exp_dup + r_dup;
            exp_gap = exp_gap + r_gapc;
        end
    endtask

    task check_outputs(input [255:0] tag);
        begin
            checks = checks + 1;
            if (out_valid !== r_valid) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] out_valid dut=%0b ref=%0b (t=%0t)", tag, out_valid, r_valid, $time);
            end
            if (r_valid && (out_seq !== r_seq)) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] out_seq dut=%0d ref=%0d", tag, out_seq, r_seq);
            end
            if (r_valid && (out_data !== r_data)) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] out_data dut=%h ref=%h", tag, out_data, r_data);
            end
            if (gap_o !== r_gap) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] gap_o dut=%0b ref=%0b (t=%0t)", tag, gap_o, r_gap, $time);
            end
            if (r_gap && (gap_seq_o !== r_gapseq)) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] gap_seq dut=%0d ref=%0d", tag, gap_seq_o, r_gapseq);
            end
            if (far_o !== r_far) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] far_o dut=%0b ref=%0b (t=%0t)", tag, far_o, r_far, $time);
            end
            if (expected_o !== rn_expected) begin
                errors = errors + 1;
                $display("  MISMATCH [%0s] expected dut=%0d ref=%0d", tag, expected_o, rn_expected);
            end
        end
    endtask

    // Drive one cycle: compute ref from pre-edge state, apply inputs, clock,
    // check DUT registered outputs, then commit the model.
    task cycle(input av, input [SEQ_W-1:0] aseq, input [DATA_W-1:0] adata,
               input bv, input [SEQ_W-1:0] bseq, input [DATA_W-1:0] bdata,
               input [255:0] tag);
        begin
            ref_compute(av, aseq, adata, bv, bseq, bdata);
            a_valid = av; a_seq = aseq; a_data = adata;
            b_valid = bv; b_seq = bseq; b_data = bdata;
            @(posedge clk);
            #1;
            check_outputs(tag);
            commit_model;
        end
    endtask

    task idle_cycle(input [255:0] tag);
        begin
            cycle(1'b0, '0, '0, 1'b0, '0, '0, tag);
        end
    endtask

    // data helper: make the payload a recognizable function of the seq
    function [DATA_W-1:0] mkdata(input [SEQ_W-1:0] s);
        mkdata = 32'h1000_0000 | s;
    endfunction

    integer c;
    reg [SEQ_W-1:0] base;

    initial begin
        $dumpfile("ab_feed_arbiter.vcd");
        $dumpvars(0, tb_ab_feed_arbiter);

        // init model
        for (gi = 0; gi < WIN; gi = gi + 1) begin m_v[gi]=1'b0; m_s[gi]='0; m_d[gi]='0; end
        m_expected = '0; m_timer = 0;
        exp_fwd = 0; exp_dup = 0; exp_gap = 0;
        checks = 0; errors = 0;

        a_valid=1'b0; a_seq='0; a_data='0;
        b_valid=1'b0; b_seq='0; b_data='0;

        // ---- reset ------------------------------------------------------
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        if (out_valid!==1'b0 || gap_o!==1'b0 || far_o!==1'b0 || expected_o!==0) begin
            errors = errors + 1; $display("  MISMATCH reset outputs not clear");
        end
        checks = checks + 1;
        @(negedge clk);
        rst = 1'b0;

        // =================================================================
        // DIRECTED SEQUENCE (also the story rendered in the waveform)
        // expected starts at 0
        // =================================================================
        // 1) in-order single-line forward: A delivers seq0
        cycle(1'b1, 16'd0, mkdata(0),  1'b0,'0,'0, "d.inorder0");
        // 2) A and B both deliver seq1 -> forward once, B duplicate suppressed
        cycle(1'b1, 16'd1, mkdata(1),  1'b1, 16'd1, mkdata(1), "d.dupAB1");
        // 3) A delivers seq3 out of order (hole at 2) -> buffered, no output
        cycle(1'b1, 16'd3, mkdata(3),  1'b0,'0,'0, "d.ooo3");
        // 4) redundancy cover: B supplies the missing seq2 -> forward seq2
        cycle(1'b0,'0,'0,  1'b1, 16'd2, mkdata(2), "d.cover2");
        // 5) drain buffered seq3
        idle_cycle("d.drain3");
        // 6) A=seq5, B=seq6 both ahead (hole at 4) -> buffered
        cycle(1'b1, 16'd5, mkdata(5),  1'b1, 16'd6, mkdata(6), "d.ahead56");
        // 7..) stall on the hole at 4 until the gap timeout fires
        idle_cycle("d.stall1");
        idle_cycle("d.stall2");
        idle_cycle("d.stall3");
        idle_cycle("d.gapfire");   // GAP_TIMEOUT reached -> gap_o pulse, skip seq4
        // drain the buffered 5 then 6
        idle_cycle("d.drain5");
        idle_cycle("d.drain6");    // expected now 7
        // beyond-window far drop: expected=7, present seq 7+WIN=15
        cycle(1'b1, 16'd15, mkdata(15), 1'b0,'0,'0, "d.far15");
        // deliver the real seq7 -> forward
        cycle(1'b1, 16'd7, mkdata(7),  1'b0,'0,'0, "d.inorder7");
        // stale duplicate: seq3 < expected(8) -> suppressed, no output
        cycle(1'b1, 16'd3, mkdata(3),  1'b0,'0,'0, "d.stale3");
        idle_cycle("d.settle");

        $display("Directed done: %0d checks, %0d errors, expected=%0d fwd=%0d dup=%0d gap=%0d",
                 checks, errors, expected_o, stat_fwd_o, stat_dup_o, stat_gap_o);

        // =================================================================
        // RANDOMIZED SOAK -- biased around the live `expected`
        // =================================================================
        for (c = 0; c < 4000; c = c + 1) begin
            base = m_expected;
            // pick each line's validity + a seq biased around the live expected
            begin : drive_rand
                reg av2, bv2;
                reg [SEQ_W-1:0] as2, bs2;
                reg [DATA_W-1:0] ad2, bd2;
                integer p2;
                av2 = (($random % 100) < 70);
                if (av2) begin
                    p2 = $random % 100;
                    if (p2 < 55)      as2 = base + ($random % (WIN+1));
                    else if (p2 < 75) as2 = base + WIN + ($random % 4);
                    else if (p2 < 90) as2 = base - ($random % 3);
                    else              as2 = base + ($random % (2*WIN));
                end else as2 = '0;
                ad2 = mkdata(as2);
                bv2 = (($random % 100) < 70);
                if (bv2) begin
                    p2 = $random % 100;
                    if (p2 < 55)      bs2 = base + ($random % (WIN+1));
                    else if (p2 < 75) bs2 = base + WIN + ($random % 4);
                    else if (p2 < 90) bs2 = base - ($random % 3);
                    else              bs2 = base + ($random % (2*WIN));
                end else bs2 = '0;
                bd2 = mkdata(bs2);
                cycle(av2, as2, ad2, bv2, bs2, bd2, "rand");
            end
        end

        // final counter cross-check
        checks = checks + 1;
        if (stat_fwd_o !== exp_fwd) begin
            errors = errors + 1; $display("  MISMATCH stat_fwd dut=%0d ref=%0d", stat_fwd_o, exp_fwd);
        end
        checks = checks + 1;
        if (stat_dup_o !== exp_dup) begin
            errors = errors + 1; $display("  MISMATCH stat_dup dut=%0d ref=%0d", stat_dup_o, exp_dup);
        end
        checks = checks + 1;
        if (stat_gap_o !== exp_gap) begin
            errors = errors + 1; $display("  MISMATCH stat_gap dut=%0d ref=%0d", stat_gap_o, exp_gap);
        end

        $display("Day28 A/B feed arbiter: %0d checks, %0d errors  (fwd=%0d dup=%0d gap=%0d)",
                 checks, errors, stat_fwd_o, stat_dup_o, stat_gap_o);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***  (%0d errors)", errors);
        $finish;
    end

    // ---- watchdog --------------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL ***  (timeout watchdog)");
        $finish;
    end

endmodule

`default_nettype wire
