// ---------------------------------------------------------------------------
// Day 37 : Self-checking testbench for the pipelined Radix-2 DIT FFT.
// ---------------------------------------------------------------------------
// The golden reference is a DIRECT DFT (naive double-precision O(N^2) double
// sum) -- structurally independent of the DUT's butterfly network -- scaled by
// 1/N (to match the datapath's per-stage /2 scaling) and re-quantised to Q1.15.
// A fixed-point FFT is always graded against a floating reference within an
// error bound (never bit-exact), so PASS = every bin of every vector lands
// within TOL LSB of the rounded ideal. Directed corners + randomised vectors.
// A VCD is dumped for the waveform figure.  Prints RESULT: *** PASS ***.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_fft_pipeline;

    localparam int N     = 16;
    localparam int DW    = 16;
    localparam int LOG2N = 4;
    localparam int LAT   = LOG2N + 1;      // pipeline latency (cycles)
    localparam real PI    = 3.141592653589793;
    localparam real DSCALE = 32768.0;      // Q1.15 data scale (2^15)
    localparam int  TOL   = 4;             // max |err| in LSB per bin (see README)

    // ---- DUT I/O ----------------------------------------------------------
    logic                     clk, rst_n, in_valid;
    logic signed [N*DW-1:0]   in_re, in_im;
    logic                     out_valid;
    logic signed [N*DW-1:0]   out_re, out_im;

    fft_pipeline #(.N(N), .DW(DW), .LOG2N(LOG2N)) dut (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .in_re(in_re), .in_im(in_im),
        .out_valid(out_valid), .out_re(out_re), .out_im(out_im)
    );

    // ---- clock ------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- scoreboard FIFO of presented input vectors -----------------------
    localparam int DEPTH = 16;
    logic signed [DW-1:0] hist_re [0:DEPTH-1][0:N-1];
    logic signed [DW-1:0] hist_im [0:DEPTH-1][0:N-1];
    integer wptr, rptr;

    // vector currently being built (real domain)
    real vr [0:N-1];
    real vi [0:N-1];

    integer checks, errs, max_abs_err;

    // ---- helpers ----------------------------------------------------------
    function automatic integer q15(input real x);   // real -> Q1.15 raw, saturating
        real s; integer v;
        begin
            s = x * DSCALE;
            v = (s >= 0.0) ? $rtoi(s + 0.5) : -$rtoi(-s + 0.5);
            if (v >  32767) v =  32767;
            if (v < -32768) v = -32768;
            q15 = v;
        end
    endfunction

    // pack the current vr/vi into the DUT buses; if valid, push into the FIFO
    task automatic present(input integer valid);
        integer n, raw_r, raw_i;
        begin
            for (n = 0; n < N; n++) begin
                raw_r = q15(vr[n]);
                raw_i = q15(vi[n]);
                in_re[n*DW +: DW] = raw_r[DW-1:0];
                in_im[n*DW +: DW] = raw_i[DW-1:0];
                if (valid) begin
                    hist_re[wptr][n] = raw_r[DW-1:0];
                    hist_im[wptr][n] = raw_i[DW-1:0];
                end
            end
            in_valid = valid[0];
            if (valid) wptr = (wptr + 1) % DEPTH;
            @(posedge clk);
            #1;                                  // settle past the edge
        end
    endtask

    // ---- checker: on out_valid, DFT the oldest queued input & compare -----
    always @(posedge clk) begin
        if (rst_n && out_valid) begin : chk
            integer k, n, rr, gi, dut_r, dut_i;
            real    ar, ai, ang, c, s, accr, acci;
            integer exp_r, exp_i, e;
            rr = rptr;
            for (k = 0; k < N; k++) begin
                accr = 0.0; acci = 0.0;
                for (n = 0; n < N; n++) begin
                    ar  = $itor($signed(hist_re[rr][n])) / DSCALE;
                    ai  = $itor($signed(hist_im[rr][n])) / DSCALE;
                    ang = -2.0 * PI * k * n / N;
                    c   = $cos(ang);
                    s   = $sin(ang);
                    accr = accr + ar*c - ai*s;
                    acci = acci + ar*s + ai*c;
                end
                // scaled FFT: divide by N to match the datapath
                exp_r = q15(accr / N);
                exp_i = q15(acci / N);
                dut_r = $signed(out_re[k*DW +: DW]);
                dut_i = $signed(out_im[k*DW +: DW]);

                e = dut_r - exp_r; if (e < 0) e = -e;
                checks++; if (e > max_abs_err) max_abs_err = e;
                if (e > TOL) begin
                    errs++;
                    if (errs <= 20)
                        $display("  [MISMATCH] bin %0d re: dut=%0d exp=%0d (|e|=%0d > TOL=%0d)",
                                  k, dut_r, exp_r, e, TOL);
                end
                e = dut_i - exp_i; if (e < 0) e = -e;
                checks++; if (e > max_abs_err) max_abs_err = e;
                if (e > TOL) begin
                    errs++;
                    if (errs <= 20)
                        $display("  [MISMATCH] bin %0d im: dut=%0d exp=%0d (|e|=%0d > TOL=%0d)",
                                  k, dut_i, exp_i, e, TOL);
                end
            end
            rptr = (rr + 1) % DEPTH;
        end
    end

    // ---- stimulus helpers -------------------------------------------------
    task automatic clear_vec;
        integer n;
        begin for (n = 0; n < N; n++) begin vr[n] = 0.0; vi[n] = 0.0; end end
    endtask

    // ---- main -------------------------------------------------------------
    integer t, n, seed;
    real amp;
    initial begin
        $dumpfile("fft_pipeline.vcd");
        $dumpvars(0, tb_fft_pipeline);

        in_valid = 1'b0; in_re = '0; in_im = '0;
        wptr = 0; rptr = 0; checks = 0; errs = 0; max_abs_err = 0;
        seed = 32'hF17_5EED;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        #1 rst_n = 1'b1;

        // ---- directed vectors ---------------------------------------------
        // 1) all zero
        clear_vec; present(1);

        // 2) DC: all samples = +0.4 real
        clear_vec; for (n=0;n<N;n++) vr[n] = 0.4;          present(1);

        // 3) impulse at n=0 (flat, small spectrum)
        clear_vec; vr[0] = 0.4;                             present(1);

        // 4) real cosine tone at bin 2 (energy at bins 2 and N-2)
        clear_vec; for (n=0;n<N;n++) vr[n] = 0.4*$cos(2.0*PI*2*n/N);  present(1);

        // 5) complex exponential at bin 5 (single-bin spectrum)
        clear_vec;
        for (n=0;n<N;n++) begin
            vr[n] = 0.4*$cos(2.0*PI*5*n/N);
            vi[n] = 0.4*$sin(2.0*PI*5*n/N);
        end
        present(1);

        // 6) two tones (bins 1 and 6)
        clear_vec;
        for (n=0;n<N;n++)
            vr[n] = 0.25*$cos(2.0*PI*1*n/N) + 0.25*$cos(2.0*PI*6*n/N);
        present(1);

        // 7) full-scale-ish alternating +/-0.4 (energy at Nyquist bin)
        clear_vec; for (n=0;n<N;n++) vr[n] = (n[0]) ? -0.4 : 0.4;  present(1);

        // an idle bubble to prove valid gating
        clear_vec; present(0);

        // 8) ramp
        clear_vec; for (n=0;n<N;n++) vr[n] = -0.4 + 0.8*n/(N-1);   present(1);

        // ---- randomised vectors (back-to-back streaming) ------------------
        for (t = 0; t < 600; t++) begin
            clear_vec;
            for (n = 0; n < N; n++) begin
                vr[n] = ((($random(seed) % 2001) ) / 1000.0) * 0.4;   // [-0.8,0.8]->scaled
                vi[n] = ((($random(seed) % 2001) ) / 1000.0) * 0.4;
                // clamp to +/-0.4 so |x|<=0.5 (no internal overflow)
                if (vr[n] >  0.4) vr[n] =  0.4; if (vr[n] < -0.4) vr[n] = -0.4;
                if (vi[n] >  0.4) vi[n] =  0.4; if (vi[n] < -0.4) vi[n] = -0.4;
            end
            present(1);
            // sprinkle occasional idle bubbles
            if ((t % 37) == 0) begin clear_vec; present(0); end
        end

        // drain the pipeline
        in_valid = 1'b0;
        repeat (LAT + 4) @(posedge clk);

        // ---- verdict ------------------------------------------------------
        $display("--------------------------------------------------------------");
        $display("Day 37  Pipelined Radix-2 DIT FFT (N=%0d, Q1.15)", N);
        $display("checks = %0d   mismatches = %0d   max |err| = %0d LSB   (TOL=%0d)",
                  checks, errs, max_abs_err, TOL);
        if (errs == 0 && checks > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (%0d mismatches)", errs);
        $display("--------------------------------------------------------------");
        $finish;
    end

    // ---- global timeout ---------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL ***  (TIMEOUT)");
        $finish;
    end

endmodule

`default_nettype wire
