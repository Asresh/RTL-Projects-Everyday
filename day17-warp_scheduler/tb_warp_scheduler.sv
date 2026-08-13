`default_nettype none
`timescale 1ns/1ps
//============================================================================
// tb_warp_scheduler.sv  --  Day 17
//
// Self-checking testbench for the GTO warp scheduler + register scoreboard.
//
// A fully INDEPENDENT golden model (its own scoreboard, writeback pipeline and
// GTO state) recomputes, every cycle, which warp *should* issue -- and the DUT
// must match bit-for-bit.  On top of that we assert two structural properties
// that do not rely on the golden mirror:
//
//   P1 (safety)  : a warp is never issued while any register it reads, or the
//                  register it writes, is still pending  (no RAW/WAW escape).
//   P2 (greedy)  : if we issued from warp X last cycle and X is still ready,
//                  we MUST issue X again this cycle  (the "greedy" in GTO).
//   P3 (progress): if any warp is ready, exactly one warp must issue.
//
// Stimulus = a directed prefix that produces a clean, readable dependency-stall
// waveform, followed by pseudo-random per-warp programs (dependency chains that
// force RAW/WAW stalls and exercise the greedy/oldest fallback).  Each warp's
// head instruction is presented from its program; its PC advances only when the
// DUT actually issues it.  At the end every warp must have issued exactly its
// program length.
//============================================================================
module tb_warp_scheduler;

    localparam int NW         = 8;
    localparam int NREG       = 8;
    localparam int WB_LATENCY = 4;
    localparam int WIDW = (NW   <= 1) ? 1 : $clog2(NW);
    localparam int RIDW = (NREG <= 1) ? 1 : $clog2(NREG);

    // ---- DUT I/O ----------------------------------------------------------
    logic clk = 0, rst_n = 0;
    logic [NW-1:0]        ib_valid, ib_wdst, ib_use0, ib_use1;
    logic [NW*RIDW-1:0]   ib_dst, ib_src0, ib_src1;
    logic                 issue_valid;
    logic [WIDW-1:0]      issue_warp;
    logic [NW-1:0]        issue_onehot, ready_mask;

    warp_scheduler #(.NW(NW), .NREG(NREG), .WB_LATENCY(WB_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n),
        .ib_valid(ib_valid), .ib_wdst(ib_wdst), .ib_use0(ib_use0), .ib_use1(ib_use1),
        .ib_dst(ib_dst), .ib_src0(ib_src0), .ib_src1(ib_src1),
        .issue_valid(issue_valid), .issue_warp(issue_warp),
        .issue_onehot(issue_onehot), .ready_mask(ready_mask)
    );

    always #5 clk = ~clk;

    // ---- program storage (per warp) --------------------------------------
    localparam int MAXI = 64;
    int   p_len [NW];
    logic p_wdst[NW][MAXI];
    logic p_use0[NW][MAXI];
    logic p_use1[NW][MAXI];
    int   p_dst [NW][MAXI];
    int   p_src0[NW][MAXI];
    int   p_src1[NW][MAXI];
    int   pc    [NW];

    // ---- drive the head instruction of each warp -------------------------
    int   hk;
    logic hv;
    always_comb begin
        ib_valid = '0; ib_wdst = '0; ib_use0 = '0; ib_use1 = '0;
        ib_dst   = '0; ib_src0 = '0; ib_src1 = '0;
        for (int w = 0; w < NW; w++) begin
            hk = pc[w];
            hv = (hk < p_len[w]);
            ib_valid[w] = hv;
            if (hv) begin
                ib_wdst[w] = p_wdst[w][hk];
                ib_use0[w] = p_use0[w][hk];
                ib_use1[w] = p_use1[w][hk];
                ib_dst [w*RIDW +: RIDW] = p_dst [w][hk][RIDW-1:0];
                ib_src0[w*RIDW +: RIDW] = p_src0[w][hk][RIDW-1:0];
                ib_src1[w*RIDW +: RIDW] = p_src1[w][hk][RIDW-1:0];
            end
        end
    end

    // ---- independent golden model state ----------------------------------
    logic [NREG-1:0] g_pending [NW];
    logic            g_wbv [WB_LATENCY];
    int              g_wbw [WB_LATENCY];
    int              g_wbr [WB_LATENCY];
    int              g_last_warp;
    logic            g_last_valid;
    int              issue_count [NW];

    integer errors = 0;
    integer cyc    = 0;

    // golden: compute which warp *should* issue this cycle
    task automatic golden_pick(output logic ev, output int ew);
        logic [NW-1:0] rmask;
        logic h0, h1, hd, gok;
        int   d, a, b, old;
        begin
            rmask = '0;
            for (int w = 0; w < NW; w++) begin
                d = ib_dst [w*RIDW +: RIDW];
                a = ib_src0[w*RIDW +: RIDW];
                b = ib_src1[w*RIDW +: RIDW];
                h0 = ib_use0[w] & g_pending[w][a];
                h1 = ib_use1[w] & g_pending[w][b];
                hd = ib_wdst[w] & g_pending[w][d];
                rmask[w] = ib_valid[w] & ~(h0 | h1 | hd);
            end
            old = 0;
            for (int w = NW-1; w >= 0; w--) if (rmask[w]) old = w;
            gok = g_last_valid & rmask[g_last_warp];
            ev  = |rmask;
            ew  = gok ? g_last_warp : old;
        end
    endtask

    // golden: advance scoreboard / writeback pipe / GTO state by one cycle
    task automatic golden_update(input logic ev, input int ew);
        int d; logic wr;
        begin
            d  = ib_dst[ew*RIDW +: RIDW];
            wr = ev & ib_wdst[ew];
            if (g_wbv[WB_LATENCY-1]) g_pending[g_wbw[WB_LATENCY-1]][g_wbr[WB_LATENCY-1]] = 1'b0;
            for (int i = WB_LATENCY-1; i > 0; i--) begin
                g_wbv[i] = g_wbv[i-1]; g_wbw[i] = g_wbw[i-1]; g_wbr[i] = g_wbr[i-1];
            end
            g_wbv[0] = wr; g_wbw[0] = ew; g_wbr[0] = d;
            if (wr) g_pending[ew][d] = 1'b1;
            if (ev) begin g_last_warp = ew; g_last_valid = 1'b1; end
        end
    endtask

    // ---- per-cycle checker ------------------------------------------------
    logic exp_v; int exp_w;
    int   sd, sa, sb;
    always @(posedge clk) if (rst_n) begin
        golden_pick(exp_v, exp_w);

        // ---- compare DUT to golden ----
        if (issue_valid !== exp_v) begin
            errors++;
            $display("[%0t] MISMATCH issue_valid dut=%0b exp=%0b (cyc %0d)",
                     $time, issue_valid, exp_v, cyc);
        end else if (exp_v && (issue_warp !== exp_w[WIDW-1:0])) begin
            errors++;
            $display("[%0t] MISMATCH issue_warp dut=%0d exp=%0d (cyc %0d)",
                     $time, issue_warp, exp_w, cyc);
        end

        // ---- P1 safety: no hazardous issue (independent of golden pick) ----
        if (issue_valid) begin
            sd = ib_dst [issue_warp*RIDW +: RIDW];
            sa = ib_src0[issue_warp*RIDW +: RIDW];
            sb = ib_src1[issue_warp*RIDW +: RIDW];
            if (ib_use0[issue_warp] && g_pending[issue_warp][sa]) begin
                errors++; $display("[%0t] P1 RAW-src0 escape warp=%0d r%0d", $time, issue_warp, sa);
            end
            if (ib_use1[issue_warp] && g_pending[issue_warp][sb]) begin
                errors++; $display("[%0t] P1 RAW-src1 escape warp=%0d r%0d", $time, issue_warp, sb);
            end
            if (ib_wdst[issue_warp] && g_pending[issue_warp][sd]) begin
                errors++; $display("[%0t] P1 WAW escape warp=%0d r%0d", $time, issue_warp, sd);
            end
            // onehot consistency
            if (issue_onehot !== (({{(NW-1){1'b0}}, 1'b1}) << issue_warp)) begin
                errors++; $display("[%0t] issue_onehot inconsistent", $time);
            end
        end else if (issue_onehot !== '0) begin
            errors++; $display("[%0t] issue_onehot nonzero while !issue_valid", $time);
        end

        // ---- P2 greedy: keep last warp if still ready ----
        if (g_last_valid && ready_mask[g_last_warp]) begin
            if (!issue_valid || issue_warp !== g_last_warp[WIDW-1:0]) begin
                errors++; $display("[%0t] P2 greedy violated: last=%0d ready but issued v=%0b w=%0d",
                                   $time, g_last_warp, issue_valid, issue_warp);
            end
        end

        // ---- P3 progress: ready => issue ----
        if ((|ready_mask) && !issue_valid) begin
            errors++; $display("[%0t] P3 progress violated: ready_mask=%b but no issue", $time, ready_mask);
        end

        // ---- consume the issued warp's instruction (advance its PC) ----
        if (issue_valid) begin
            issue_count[issue_warp] <= issue_count[issue_warp] + 1;
            pc[issue_warp] <= pc[issue_warp] + 1;
        end

        // trace the opening cycles so the waveform caption can be verified
        if (cyc < 24)
            $display("TRACE cyc=%2d ready=%b issue_v=%0b warp=%0d",
                     cyc, ready_mask, issue_valid, (issue_valid ? issue_warp : 0));

        golden_update(exp_v, exp_w);
        cyc <= cyc + 1;
    end

    // ---- stimulus construction -------------------------------------------
    int wi, ii, tot;

    task automatic add_instr(input int w, input logic wr, input int dst,
                             input logic u0, input int s0,
                             input logic u1, input int s1);
        begin
            p_wdst[w][p_len[w]] = wr;  p_dst [w][p_len[w]] = dst;
            p_use0[w][p_len[w]] = u0;  p_src0[w][p_len[w]] = s0;
            p_use1[w][p_len[w]] = u1;  p_src1[w][p_len[w]] = s1;
            p_len[w] = p_len[w] + 1;
        end
    endtask

    task automatic build_programs();
        int r0, r1a, du, u0i, u1i, s0i, s1i;
        begin
            for (int w = 0; w < NW; w++) p_len[w] = 0;

            // ---- directed prefix (clean, readable dependency-stall demo) ----
            // Warp 0: a 3-long RAW chain r1<-, r2<-r1, r3<-r2  -> stalls a lot.
            add_instr(0, 1'b1, 1, 1'b0, 0, 1'b0, 0);  // r1 = f()
            add_instr(0, 1'b1, 2, 1'b1, 1, 1'b0, 0);  // r2 = g(r1)   RAW on r1
            add_instr(0, 1'b1, 3, 1'b1, 2, 1'b0, 0);  // r3 = h(r2)   RAW on r2
            // Warp 1..3: independent back-to-back writes -> greedy fills bubbles.
            for (int w = 1; w <= 3; w++) begin
                add_instr(w, 1'b1, 1, 1'b0, 0, 1'b0, 0);
                add_instr(w, 1'b1, 2, 1'b0, 0, 1'b0, 0);
                add_instr(w, 1'b1, 3, 1'b0, 0, 1'b0, 0);
            end
            // Warp 4: WAW pair to the SAME register -> second waits on first.
            add_instr(4, 1'b1, 5, 1'b0, 0, 1'b0, 0);  // r5 = ...
            add_instr(4, 1'b1, 5, 1'b0, 0, 1'b0, 0);  // r5 = ...   WAW on r5

            // ---- randomized tail: dependency chains per warp ----------------
            for (int w = 0; w < NW; w++) begin
                int extra;
                extra = 6 + ($urandom % 7);              // 6..12 more instructions
                r0 = 0; r1a = 1;
                for (int k = 0; k < extra; k++) begin
                    du  = $urandom % NREG;               // destination
                    u0i = $urandom % 2;
                    u1i = $urandom % 2;
                    // bias sources toward recently written regs to force stalls
                    s0i = (($urandom % 2) ? r0 : ($urandom % NREG));
                    s1i = (($urandom % 2) ? r1a : ($urandom % NREG));
                    add_instr(w, 1'b1, du, u0i[0], s0i, u1i[0], s1i);
                    r1a = r0; r0 = du;                   // remember producers
                end
            end
        end
    endtask

    // ---- main -------------------------------------------------------------
    integer watchdog = 0;
    logic   drained;
    initial begin
        $dumpfile("warp_scheduler.vcd");
        $dumpvars(0, tb_warp_scheduler);

        build_programs();

        // init golden + environment
        for (int w = 0; w < NW; w++) begin
            g_pending[w]   = '0;
            pc[w]          = 0;
            issue_count[w] = 0;
        end
        for (int i = 0; i < WB_LATENCY; i++) begin
            g_wbv[i] = 1'b0; g_wbw[i] = 0; g_wbr[i] = 0;
        end
        g_last_warp = 0; g_last_valid = 1'b0;

        // reset
        rst_n = 0;
        repeat (3) @(posedge clk);
        @(negedge clk) rst_n = 1;

        // run until every warp's program is drained (or watchdog trips)
        forever begin
            @(posedge clk); #1;
            drained = 1'b1;
            for (int w = 0; w < NW; w++) if (pc[w] < p_len[w]) drained = 1'b0;
            if (drained) break;
            watchdog++;
            if (watchdog > 20000) begin
                $display("RESULT: *** FAIL *** watchdog timeout (possible deadlock)");
                $finish;
            end
        end

        // flush the writeback pipeline
        repeat (WB_LATENCY + 3) @(posedge clk);

        // ---- final tally ----
        tot = 0;
        for (int w = 0; w < NW; w++) begin
            tot += issue_count[w];
            if (issue_count[w] !== p_len[w]) begin
                errors++;
                $display("warp %0d issued %0d of %0d instructions",
                         w, issue_count[w], p_len[w]);
            end
        end

        $display("--------------------------------------------------------");
        $display("cycles run          : %0d", cyc);
        $display("total issues        : %0d", tot);
        $display("checker errors      : %0d", errors);
        $display("--------------------------------------------------------");
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // global safety timeout
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** global timeout");
        $finish;
    end

endmodule
`default_nettype wire
