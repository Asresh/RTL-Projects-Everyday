// =============================================================================
// Day 11 : tb_bitonic_sorter
// -----------------------------------------------------------------------------
// Self-checking testbench for the pipelined bitonic sorting network.
//
// Strategy
//   * The DUT is fully pipelined with a fixed latency, so every valid input
//     vector yields exactly one valid output vector, in order.
//   * On each cycle we drive a candidate vector (directed corner cases first,
//     then constrained-random) with a randomly gapped in_valid to exercise the
//     valid pipeline / throughput.
//   * When we assert in_valid we compute the GOLDEN answer in software
//     (a straight software sort of the same keys) and push it into a scoreboard
//     queue.
//   * When out_valid is seen we pop the expected vector and compare element by
//     element.  Any mismatch is fatal.  A watchdog aborts a hung run.
//
// The DUT is instantiated UNSIGNED / ASCENDING here (clean hex in the wave).
// The RTL is also parameterizable for SIGNED keys and descending order; the
// golden model below tracks whatever SIGNED/ASCENDING the DUT is built with.
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_bitonic_sorter;

    // ---- DUT configuration --------------------------------------------------
    localparam int  N         = 8;
    localparam int  DW        = 16;
    localparam bit  SIGNED    = 1'b0;
    localparam bit  ASCENDING = 1'b1;

    localparam int  L       = $clog2(N);
    localparam int  S       = (L * (L + 1)) / 2;
    localparam int  LATENCY = S + 1;

    // ---- clock / reset ------------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;                 // 100 MHz

    // ---- DUT I/O ------------------------------------------------------------
    logic                  in_valid;
    logic [N-1:0][DW-1:0]  in_data;
    logic                  out_valid;
    logic [N-1:0][DW-1:0]  out_data;

    bitonic_sorter #(
        .N(N), .DW(DW), .SIGNED(SIGNED), .ASCENDING(ASCENDING)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .in_data   (in_data),
        .out_valid (out_valid),
        .out_data  (out_data)
    );

    // ---- scoreboard ---------------------------------------------------------
    // Each expected result is stored as a packed vector, same layout as the DUT.
    typedef logic [N-1:0][DW-1:0] vec_t;
    vec_t exp_q [$];

    int   sent      = 0;
    int   checked   = 0;
    int   errors    = 0;

    // Reference (software) sort of a packed vector.
    function automatic vec_t golden_sort(input vec_t v);
        logic [DW-1:0] a [N];
        logic [DW-1:0] tmp;
        vec_t          r;
        bit            swap;
        // unpack
        for (int i = 0; i < N; i++) a[i] = v[i];
        // simple bubble sort (N is small; clarity over speed)
        for (int p = 0; p < N - 1; p++) begin
            for (int q = 0; q < N - 1 - p; q++) begin
                if (SIGNED)
                    swap = ASCENDING ? ($signed(a[q]) > $signed(a[q+1]))
                                     : ($signed(a[q]) < $signed(a[q+1]));
                else
                    swap = ASCENDING ? (a[q] > a[q+1])
                                     : (a[q] < a[q+1]);
                if (swap) begin
                    tmp = a[q]; a[q] = a[q+1]; a[q+1] = tmp;
                end
            end
        end
        // repack
        for (int i = 0; i < N; i++) r[i] = a[i];
        return r;
    endfunction

    // Drive one input vector for exactly one cycle.  Inputs are launched on the
    // NEGEDGE via non-blocking assignment so they are rock-stable at the posedge
    // the DUT samples -- no clock-edge race, so the captured waveform is clean.
    task automatic drive(input vec_t v, input bit vld);
        @(negedge clk);
        in_data  <= v;
        in_valid <= vld;
        if (vld) begin
            exp_q.push_back(golden_sort(v));
            sent++;
        end
    endtask

    // pretty-print a packed vector as {e0, e1, ...}
    function automatic string vshow(input vec_t v);
        string s;
        s = "{";
        for (int i = 0; i < N; i++)
            s = {s, $sformatf("%0d%s", v[i], (i == N-1) ? "}" : ", ")};
        return s;
    endfunction

    // ---- output checker: fires on every valid output ------------------------
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            vec_t exp;
            if (exp_q.size() == 0) begin
                errors++;
                $error("[%0t] out_valid with EMPTY scoreboard -> spurious output",
                       $time);
            end else begin
                exp = exp_q.pop_front();
                checked++;
                if (out_data !== exp) begin
                    errors++;
                    $error("[%0t] MISMATCH #%0d\n    got = %s\n    exp = %s",
                           $time, checked, vshow(out_data), vshow(exp));
                end
            end
        end
    end

    // ---- stimulus -----------------------------------------------------------
    vec_t v;
    int   coin;

    // build a packed vector from an unpacked array literal helper
    function automatic vec_t mk(input logic [DW-1:0] e0, e1, e2, e3,
                                                     e4, e5, e6, e7);
        vec_t r;
        r[0]=e0; r[1]=e1; r[2]=e2; r[3]=e3;
        r[4]=e4; r[5]=e5; r[6]=e6; r[7]=e7;
        return r;
    endfunction

    initial begin
        // ---- reset ----
        rst_n    = 1'b0;
        in_valid = 1'b0;
        in_data  = '0;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- DIRECTED corner cases (streamed back-to-back) ----
        drive(mk(16'd7,16'd3,16'd5,16'd1,16'd8,16'd2,16'd6,16'd4), 1'b1);
        drive(mk(16'd1,16'd2,16'd3,16'd4,16'd5,16'd6,16'd7,16'd8), 1'b1); // sorted
        drive(mk(16'd8,16'd7,16'd6,16'd5,16'd4,16'd3,16'd2,16'd1), 1'b1); // reverse
        drive(mk(16'd9,16'd9,16'd9,16'd9,16'd9,16'd9,16'd9,16'd9), 1'b1); // all equal
        drive(mk(16'hFFFF,16'd0,16'd0,16'd0,16'd0,16'd0,16'd0,16'hFFFF), 1'b1);
        drive(mk(16'd0,16'hFFFF,16'd0,16'hFFFF,16'd0,16'hFFFF,16'd0,16'hFFFF), 1'b1);

        // gap in the stream (in_valid low) -> exercises valid pipeline
        drive('0, 1'b0);
        drive('0, 1'b0);

        // ---- RANDOMIZED stimulus with random valid gaps ----
        for (int t = 0; t < 400; t++) begin
            for (int i = 0; i < N; i++) v[i] = $urandom_range(0, (1<<DW)-1);
            coin = $urandom_range(0, 3);   // ~75% duty -> some bubbles
            drive(v, (coin != 0));
        end

        // ---- drain the pipeline ----
        drive('0, 1'b0);
        repeat (LATENCY + 4) @(posedge clk);

        // ---- report ----
        $display("-----------------------------------------------------------");
        $display(" bitonic_sorter  N=%0d DW=%0d SIGNED=%0d ASCENDING=%0d",
                 N, DW, SIGNED, ASCENDING);
        $display(" latency = %0d cycles (%0d stages)", LATENCY, S);
        $display(" vectors sent    = %0d", sent);
        $display(" vectors checked = %0d", checked);
        $display(" mismatches      = %0d", errors);
        if (exp_q.size() != 0) begin
            errors++;
            $display(" ERROR: %0d expected vectors never came out", exp_q.size());
        end
        if (errors == 0 && checked == sent && sent > 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (errors=%0d)", errors);
        $display("-----------------------------------------------------------");
        $finish;
    end

    // ---- watchdog -----------------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL ***  (TIMEOUT)");
        $finish;
    end

    // ---- waveform dump ------------------------------------------------------
    initial begin
        $dumpfile("bitonic_sorter.vcd");
        $dumpvars(0, tb_bitonic_sorter);
    end

endmodule

`default_nettype wire
