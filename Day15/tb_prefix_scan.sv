// ===========================================================================
// tb_prefix_scan.sv  --  self-checking testbench for the Kogge-Stone
//                         segmented prefix-sum (scan) engine.
//
//   * Golden reference: a behavioural segmented inclusive scan computed in
//     SystemVerilog, run for every input vector.
//   * Stimulus: directed corner cases (all-zero, plain ramp, multi-segment,
//     signed negatives, overflow-edge maxima, per-lane segments) followed by
//     randomized vectors.
//   * The DUT is pipelined (latency = log2(N) cycles), so expected results are
//     queued and popped as out_valid pulses; a global cycle timeout guards
//     against a hang, and a VCD is dumped for waveform rendering.
//   * Prints "RESULT: *** PASS ***" only if every checked output matches.
//
// (Arrays are kept at module scope and stimulus is built there so the code
//  stays within the subset of SystemVerilog supported by every simulator,
//  including Icarus Verilog, which does not accept unpacked-array subroutine
//  ports.)
// ===========================================================================
`timescale 1ns/1ps

module tb_prefix_scan;

    // ---- DUT configuration -------------------------------------------------
    localparam int N      = 8;
    localparam int W      = 12;
    localparam bit SIGNED = 1;
    localparam int WACC   = W + $clog2(N);
    localparam int S      = $clog2(N);

    // ---- clock / reset -----------------------------------------------------
    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;          // 100 MHz

    // ---- DUT interface -----------------------------------------------------
    logic               in_valid;
    logic [N*W-1:0]     in_data;
    logic [N-1:0]       in_seg;
    logic               out_valid;
    logic [N*WACC-1:0]  out_data;
    logic [N-1:0]       out_seg;

    prefix_scan #(.N(N), .W(W), .SIGNED(SIGNED)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(in_data), .in_seg(in_seg),
        .out_valid(out_valid), .out_data(out_data), .out_seg(out_seg)
    );

    // ---- scoreboard --------------------------------------------------------
    logic [N*WACC-1:0] exp_q [$];
    logic [N-1:0]      seg_q [$];
    int   drives = 0;
    int   checks = 0;
    int   errors = 0;

    // ---- module-scope stimulus buffers -------------------------------------
    logic signed [W-1:0] d [N];   // current input elements
    logic                s [N];   // current segment-head flags
    logic [N*WACC-1:0]   exp;      // scratch expected packed result
    logic [N-1:0]        esg;      // scratch expected packed seg flags

    // ---- clear the stimulus buffers ----------------------------------------
    task automatic clear_stim;
        for (int i = 0; i < N; i++) begin d[i] = '0; s[i] = 1'b0; end
    endtask

    // ---- drive current d[]/s[], enqueue the golden result ------------------
    task automatic drive_vec;
        logic signed [WACC-1:0] acc, elem;
        // pack the stimulus onto the bus
        for (int i = 0; i < N; i++) begin
            in_data[i*W +: W] = d[i];
            in_seg[i]         = s[i];
        end
        // golden segmented inclusive scan
        acc = '0;
        for (int i = 0; i < N; i++) begin
            elem = SIGNED ? WACC'(d[i]) : WACC'($unsigned(d[i]));
            if (s[i]) acc = elem;              // segment boundary -> restart
            else      acc = acc + elem;
            exp[i*WACC +: WACC] = acc;
            esg[i] = s[i] | (i > 0 ? esg[i-1] : 1'b0);   // OR-scan of flags
        end
        exp_q.push_back(exp);
        seg_q.push_back(esg);
        in_valid = 1'b1;
        drives++;
        @(posedge clk);
    endtask

    // ---- output checker (runs concurrently) --------------------------------
    logic [N*WACC-1:0] cexp;
    logic [N-1:0]      csg;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (exp_q.size() == 0) begin
                $display("[%0t] ERROR: out_valid with empty scoreboard", $time);
                errors++;
            end else begin
                cexp = exp_q.pop_front();
                csg  = seg_q.pop_front();
                checks++;
                if (out_data !== cexp) begin
                    errors++;
                    $display("[%0t] MISMATCH #%0d", $time, checks);
                    for (int i = 0; i < N; i++)
                        $display("    lane %0d : got %0d  exp %0d", i,
                                 $signed(out_data[i*WACC +: WACC]),
                                 $signed(cexp[i*WACC +: WACC]));
                end
                if (out_seg !== csg) begin
                    errors++;
                    $display("[%0t] SEG-FLAG MISMATCH #%0d : got %b exp %b",
                             $time, checks, out_seg, csg);
                end
            end
        end
    end

    // ---- main stimulus -----------------------------------------------------
    integer t, i;
    initial begin
        $dumpfile("prefix_scan.vcd");
        $dumpvars(0, tb_prefix_scan);

        in_valid = 0; in_data = '0; in_seg = '0;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // --- directed: all zeros -------------------------------------------
        clear_stim();
        drive_vec();

        // --- directed: plain inclusive ramp 1..N (no segment boundaries) ----
        clear_stim();
        for (i = 0; i < N; i++) d[i] = i + 1;
        drive_vec();

        // --- directed: two segments ----------------------------------------
        clear_stim();
        for (i = 0; i < N; i++) d[i] = 1;      // all ones
        s[0]   = 1'b1;                         // segment head at lane 0
        s[N/2] = 1'b1;                         // and at the midpoint
        drive_vec();

        // --- directed: signed negatives ------------------------------------
        clear_stim();
        for (i = 0; i < N; i++) d[i] = (i % 2) ? -(i+1) : (i+1);
        s[0] = 1'b1;
        drive_vec();

        // --- directed: overflow-edge maxima --------------------------------
        clear_stim();
        for (i = 0; i < N; i++) d[i] = SIGNED ? -(1<<(W-1)) : ((1<<W)-1);
        drive_vec();

        // --- directed: every lane its own segment (identity scan) ----------
        clear_stim();
        for (i = 0; i < N; i++) begin d[i] = (i*7 - 3); s[i] = 1'b1; end
        drive_vec();

        // --- randomized -----------------------------------------------------
        for (t = 0; t < 200; t++) begin
            for (i = 0; i < N; i++) begin
                d[i] = $random;                       // full-width random
                s[i] = (($random % 4) == 0);          // ~25% segment heads
            end
            drive_vec();
        end

        // stop driving and let the pipeline flush
        in_valid = 0;
        repeat (S + 4) @(posedge clk);

        // --- final scoreboard -----------------------------------------------
        if (exp_q.size() != 0) begin
            $display("ERROR: %0d expected results never emitted", exp_q.size());
            errors++;
        end
        if (checks != drives) begin
            $display("ERROR: drove %0d vectors but checked %0d", drives, checks);
            errors++;
        end

        $display("-------------------------------------------------------------");
        $display("  prefix_scan  N=%0d  W=%0d  SIGNED=%0d  stages=%0d", N, W, SIGNED, S);
        $display("  drove=%0d  checked=%0d  errors=%0d", drives, checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $display("-------------------------------------------------------------");
        $finish;
    end

    // ---- global timeout ----------------------------------------------------
    initial begin
        #100000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule
