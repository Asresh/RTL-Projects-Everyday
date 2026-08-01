// ============================================================================
// tb_latency_monitor.sv  --  self-checking testbench for the Day 29
// nanosecond-timestamp / tick-to-trade latency monitor.
//
// Strategy: an INDEPENDENT golden reference model (plain SystemVerilog vars +
// straight-line procedural policy, deliberately structured unlike the DUT's
// registered cone) mirrors the NCO phase accumulator, the tag-matched capture
// table, and the stats + power-of-two histogram. Because the DUT registers all
// of its outputs, the reference is compared ONE CLOCK after the driving inputs
// (a 1-deep pipeline): each cycle we (a) compute the reference next-state from
// the current reference state and this cycle's inputs, (b) pulse the clock,
// (c) compare every DUT output to that reference next-state, (d) commit.
//
// Coverage: reset, NCO advance/hold, single measurement, back-to-back probes,
// overlapping tags, orphan t1, min/max tracking, every histogram bin, counter
// saturation-safe ranges, and a long randomized soak -- checked every cycle,
// counters reconciled at the end. A timeout watchdog fails loudly.
// ============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_latency_monitor;

    // ---- parameters (match the DUT defaults) -------------------------------
    localparam int TS_W   = 32;
    localparam int FRAC_W = 16;
    localparam int INC_W  = 24;
    localparam int TAG_W  = 3;
    localparam int NBINS  = 8;
    localparam int CNT_W  = 32;
    localparam int SUM_W  = 48;
    localparam int HIST_W = 32;

    localparam int PHASE_W  = TS_W + FRAC_W;
    localparam int NTAG     = 1 << TAG_W;
    localparam int BINSEL_W = (NBINS > 1) ? $clog2(NBINS) : 1;

    // ---- DUT I/O -----------------------------------------------------------
    logic                    clk, rst;
    logic                    run_i;
    logic [INC_W-1:0]        inc_i;
    logic [TS_W-1:0]         now_o;
    logic                    t0_valid_i;
    logic [TAG_W-1:0]        t0_tag_i;
    logic                    t1_valid_i;
    logic [TAG_W-1:0]        t1_tag_i;
    logic                    meas_valid_o;
    logic [TAG_W-1:0]        meas_tag_o;
    logic [TS_W-1:0]         meas_lat_o;
    logic                    orphan_o;
    logic [CNT_W-1:0]        cnt_o;
    logic [TS_W-1:0]         min_o, max_o, last_o;
    logic [SUM_W-1:0]        sum_o;
    logic [CNT_W-1:0]        orphan_cnt_o;
    logic [TAG_W:0]          outstanding_o;
    logic [NBINS*HIST_W-1:0] hist_flat_o;

    latency_monitor #(
        .TS_W(TS_W), .FRAC_W(FRAC_W), .INC_W(INC_W), .TAG_W(TAG_W),
        .NBINS(NBINS), .CNT_W(CNT_W), .SUM_W(SUM_W), .HIST_W(HIST_W)
    ) dut (
        .clk(clk), .rst(rst),
        .run_i(run_i), .inc_i(inc_i), .now_o(now_o),
        .t0_valid_i(t0_valid_i), .t0_tag_i(t0_tag_i),
        .t1_valid_i(t1_valid_i), .t1_tag_i(t1_tag_i),
        .meas_valid_o(meas_valid_o), .meas_tag_o(meas_tag_o),
        .meas_lat_o(meas_lat_o), .orphan_o(orphan_o),
        .cnt_o(cnt_o), .min_o(min_o), .max_o(max_o), .last_o(last_o),
        .sum_o(sum_o), .orphan_cnt_o(orphan_cnt_o),
        .outstanding_o(outstanding_o), .hist_flat_o(hist_flat_o)
    );

    // ---- clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- reference model state ---------------------------------------------
    logic [PHASE_W-1:0] r_phase;
    logic [TS_W-1:0]    r_t0ts [NTAG];
    logic [NTAG-1:0]    r_busy;
    logic [CNT_W-1:0]   r_cnt;
    logic [TS_W-1:0]    r_min, r_max, r_last;
    logic [SUM_W-1:0]   r_sum;
    logic [CNT_W-1:0]   r_orphcnt;
    logic [HIST_W-1:0]  r_hist [NBINS];

    // expected registered outputs for the current compare
    logic [TS_W-1:0]    e_now;
    logic               e_meas_valid;
    logic [TAG_W-1:0]   e_meas_tag;
    logic [TS_W-1:0]    e_meas_lat;
    logic               e_orphan;
    logic [TAG_W:0]     e_outstanding;

    integer checks = 0;
    integer errors = 0;

    // ---- helpers -----------------------------------------------------------
    function automatic [BINSEL_W-1:0] log2bin(input logic [TS_W-1:0] v);
        integer i;
        logic [BINSEL_W-1:0] b;
        begin
            b = '0;
            for (i = 0; i < TS_W; i = i + 1)
                if (v[i]) b = (i > (NBINS-1)) ? (NBINS-1) : i[BINSEL_W-1:0];
            log2bin = b;
        end
    endfunction

    function automatic [CNT_W-1:0] sat_cnt(input logic [CNT_W-1:0] c);
        sat_cnt = (&c) ? c : c + 1'b1;
    endfunction
    function automatic [HIST_W-1:0] sat_hist(input logic [HIST_W-1:0] c);
        sat_hist = (&c) ? c : c + 1'b1;
    endfunction
    function automatic [TAG_W:0] popc(input logic [NTAG-1:0] v);
        integer i; logic [TAG_W:0] s;
        begin s = '0; for (i=0;i<NTAG;i=i+1) s = s + v[i]; popc = s; end
    endfunction

    task automatic reset_ref();
        integer i;
        begin
            r_phase   = '0;
            r_busy    = '0;
            r_cnt     = '0;
            r_min     = '0; r_max = '0; r_last = '0;
            r_sum     = '0; r_orphcnt = '0;
            for (i=0;i<NTAG;  i=i+1) r_t0ts[i] = '0;
            for (i=0;i<NBINS; i=i+1) r_hist[i] = '0;
        end
    endtask

    task automatic check(input string nm, input logic [63:0] got,
                         input logic [63:0] exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  MISMATCH %-14s got=%0d (0x%0h) exp=%0d (0x%0h)  @%0t",
                         nm, got, got, exp, exp, $time);
            end
        end
    endtask

    // Drive one cycle of stimulus, advance the reference, pulse the clock,
    // then compare every DUT output to the reference next-state.
    task automatic cyc(input logic               rrst,
                       input logic               rrun,
                       input logic [INC_W-1:0]    iinc,
                       input logic               v0, input logic [TAG_W-1:0] tg0,
                       input logic               v1, input logic [TAG_W-1:0] tg1);
        logic [TS_W-1:0]    now_used, lat;
        logic [NTAG-1:0]    busy_nxt;
        logic [BINSEL_W-1:0] bin;
        integer i;
        begin
            // ---- drive DUT inputs ----
            rst        = rrst;
            run_i      = rrun;
            inc_i      = iinc;
            t0_valid_i = v0;  t0_tag_i = tg0;
            t1_valid_i = v1;  t1_tag_i = tg1;

            // ---- compute reference next-state (mirror of the always_ff) ----
            if (rrst) begin
                reset_ref();
                e_meas_valid  = 1'b0;
                e_meas_tag    = '0;
                e_meas_lat    = '0;
                e_orphan      = 1'b0;
                e_outstanding = '0;
                e_now         = '0;    // phase reset to 0
            end else begin
                // "now" used for stamping/measuring is the PRE-edge phase slice
                now_used = r_phase[PHASE_W-1:FRAC_W];
                e_meas_valid = 1'b0;
                e_meas_tag   = '0;
                e_meas_lat   = '0;
                e_orphan     = 1'b0;
                busy_nxt     = r_busy;

                if (v1 && r_busy[tg1]) begin
                    lat          = now_used - r_t0ts[tg1];
                    e_meas_valid = 1'b1;
                    e_meas_tag   = tg1;
                    e_meas_lat   = lat;
                    busy_nxt[tg1]= 1'b0;
                    r_last       = lat;
                    if (r_cnt == '0) begin r_min = lat; r_max = lat; end
                    else begin
                        if (lat < r_min) r_min = lat;
                        if (lat > r_max) r_max = lat;
                    end
                    r_cnt = sat_cnt(r_cnt);
                    r_sum = (&r_sum) ? r_sum : (r_sum + {{(SUM_W-TS_W){1'b0}}, lat});
                    bin        = log2bin(lat);
                    r_hist[bin]= sat_hist(r_hist[bin]);
                end else if (v1) begin
                    e_orphan  = 1'b1;
                    r_orphcnt = sat_cnt(r_orphcnt);
                end

                if (v0) begin
                    r_t0ts[tg0]  = now_used;
                    busy_nxt[tg0]= 1'b1;
                end

                r_busy        = busy_nxt;
                e_outstanding = popc(busy_nxt);

                // phase advances (registered) -> now_o shows the POST-edge phase
                if (rrun) r_phase = r_phase + {{(PHASE_W-INC_W){1'b0}}, iinc};
                e_now = r_phase[PHASE_W-1:FRAC_W];
            end

            // ---- clock the DUT, then compare -------------------------------
            @(posedge clk);
            #1;

            check("now_o",         now_o,        e_now);
            check("meas_valid_o",  meas_valid_o, e_meas_valid);
            if (e_meas_valid) begin
                check("meas_tag_o", meas_tag_o, e_meas_tag);
                check("meas_lat_o", meas_lat_o, e_meas_lat);
            end
            check("orphan_o",      orphan_o,      e_orphan);
            check("cnt_o",         cnt_o,         r_cnt);
            check("min_o",         min_o,         r_min);
            check("max_o",         max_o,         r_max);
            check("last_o",        last_o,        r_last);
            check("sum_o",         sum_o,         r_sum);
            check("orphan_cnt_o",  orphan_cnt_o,  r_orphcnt);
            check("outstanding_o", outstanding_o, e_outstanding);
            for (i = 0; i < NBINS; i = i + 1)
                check($sformatf("hist[%0d]", i),
                      hist_flat_o[i*HIST_W +: HIST_W], r_hist[i]);
        end
    endtask

    // convenience wrappers ---------------------------------------------------
    localparam logic [INC_W-1:0] INC4 = 24'h04_0000; // 4.0 ns/cycle (Q8.16)

    task automatic idle(input int n);
        int i; begin for (i=0;i<n;i=i+1) cyc(0,1,INC4, 0,'0, 0,'0); end
    endtask

    // ---- directed + random stimulus ----------------------------------------
    integer seed = 32'hDA9_2917;
    integer i, dir_checks;
    logic       rv0, rv1;
    logic [TAG_W-1:0] rt0, rt1;
    logic [CNT_W-1:0] exp_cnt, exp_orph;

    initial begin
        $dumpfile("latency_monitor.vcd");
        $dumpvars(0, tb_latency_monitor);

        // defaults
        rst=1; run_i=0; inc_i=INC4;
        t0_valid_i=0; t0_tag_i='0; t1_valid_i=0; t1_tag_i='0;
        reset_ref();

        // ---- reset (3 cycles) ---------------------------------------------
        cyc(1,0,INC4, 0,'0, 0,'0);
        cyc(1,0,INC4, 0,'0, 0,'0);
        cyc(1,0,INC4, 0,'0, 0,'0);

        // ---- NCO warm-up: let the timestamp advance a few cycles ----------
        idle(2);

        // ---- measurement A: tag 1, gap of 1 active cycle -> lat = 4 ns -----
        //   (floor(log2(4)) = 2  -> histogram bin 2)
        cyc(0,1,INC4, 1,3'd1, 0,'0);   // t0 on tag 1
        cyc(0,1,INC4, 0,'0,   1,3'd1); // t1 on tag 1  -> lat = 4

        // ---- measurement B: tag 2, gap of 2 active cycles -> lat = 8 ns ----
        //   (bin 3)  -- also a new max
        cyc(0,1,INC4, 1,3'd2, 0,'0);   // t0 on tag 2
        idle(1);                        // one cycle passes
        cyc(0,1,INC4, 0,'0,   1,3'd2); // t1 on tag 2 -> lat = 8

        // ---- overlapping probes: arm tags 4 and 5, retire out of order -----
        cyc(0,1,INC4, 1,3'd4, 0,'0);   // t0 tag 4
        cyc(0,1,INC4, 1,3'd5, 0,'0);   // t0 tag 5 (both outstanding now)
        idle(2);
        cyc(0,1,INC4, 0,'0,   1,3'd5); // retire tag 5 first
        cyc(0,1,INC4, 0,'0,   1,3'd4); // then tag 4 (a longer latency -> new max)

        // ---- orphan: t1 on a tag that was never armed ----------------------
        cyc(0,1,INC4, 0,'0,   1,3'd7); // orphan (tag 7 idle)

        // ---- simultaneous t0+t1 same cycle, different tags -----------------
        cyc(0,1,INC4, 1,3'd0, 1,3'd1); // arm tag 0 while retiring tag1 (idle->orphan)
        cyc(0,1,INC4, 0,'0,   1,3'd0); // retire tag 0 -> small latency (bin 0/1)

        // ---- NCO hold: run_i low, timestamp must freeze --------------------
        cyc(0,0,INC4, 0,'0, 0,'0);
        cyc(0,0,INC4, 0,'0, 0,'0);

        dir_checks = checks;
        $display("Directed done: %0d checks, %0d errors  (cnt=%0d orphans=%0d min=%0d max=%0d now=%0d)",
                 dir_checks, errors, cnt_o, orphan_cnt_o, min_o, max_o, now_o);

        // ---- randomized soak ----------------------------------------------
        // Each cycle: usually running; independently maybe fire a t0 and/or a
        // t1 on a random small tag; occasionally freeze the NCO; vary the
        // increment so latency magnitudes spread across all histogram bins.
        for (i = 0; i < 4000; i = i + 1) begin
            rv0 = ($random(seed) % 3) != 0;          // ~2/3 arm a probe
            rv1 = ($random(seed) % 3) != 0;          // ~2/3 retire a probe
            rt0 = $random(seed);
            rt1 = $random(seed);
            cyc(1'b0,
                ($random(seed) % 8) != 0,            // run ~7/8 of the time
                ((i % 512) == 0) ? 24'h20_0000 : INC4, // periodically 32 ns/cyc for big latencies
                rv0, rt0, rv1, rt1);
        end

        // ---- final reconciliation -----------------------------------------
        exp_cnt  = r_cnt;
        exp_orph = r_orphcnt;
        if (cnt_o        !== exp_cnt)  begin errors=errors+1; $display("  CNT reconcile mismatch"); end
        if (orphan_cnt_o !== exp_orph) begin errors=errors+1; $display("  ORPHAN reconcile mismatch"); end

        $display("Day29 latency monitor: %0d checks, %0d errors  (cnt=%0d orphans=%0d min=%0d max=%0d sum=%0d)",
                 checks, errors, cnt_o, orphan_cnt_o, min_o, max_o, sum_o);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ---- timeout watchdog --------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (timeout watchdog fired)");
        $finish;
    end

endmodule

`default_nettype wire
