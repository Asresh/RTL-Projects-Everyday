// ---------------------------------------------------------------------------
// Day 14 : Self-checking testbench for the systolic-array GEMM accelerator.
// ---------------------------------------------------------------------------
// Strategy
//   * A software golden model computes  C = A x B  with full-precision signed
//     integer arithmetic (SystemVerilog `longint`), independent of the DUT.
//   * A reusable task loads flattened A/B, pulses `start`, waits for `done`
//     with a hard timeout, then scoreboards every C[i][j] against the model.
//   * Directed cases pin down corner behaviour: identity, all-zero, all-ones,
//     negative/mixed sign (exercises signed MAC), and a hand-worked matrix.
//   * A randomized campaign then hammers the mesh with fresh signed operands.
//   * Back-to-back invocations verify the per-launch accumulator clear.
//
// Prints "RESULT: *** PASS ***" iff every element of every case matches.
// Dumps systolic_matmul.vcd for waveform rendering.
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module tb_systolic_matmul;
    // Match the DUT geometry.
    localparam int N     = 4;
    localparam int K     = 4;
    localparam int DW    = 8;
    localparam int ACC_W = 2*DW + $clog2(K + 1);

    localparam time CLK = 10ns;

    logic                    clk = 1'b0;
    logic                    rst_n;
    logic                    start;
    logic                    busy;
    logic                    done;
    logic [N*K*DW-1:0]       a_flat;
    logic [K*N*DW-1:0]       b_flat;
    logic [N*N*ACC_W-1:0]    c_flat;

    integer errors = 0;
    integer checks = 0;

    // ---------------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------------
    systolic_matmul #(.N(N), .K(K), .DW(DW)) dut (
        .clk    (clk),
        .rst_n  (rst_n),
        .start  (start),
        .busy   (busy),
        .done   (done),
        .a_flat (a_flat),
        .b_flat (b_flat),
        .c_flat (c_flat)
    );

    always #(CLK/2) clk = ~clk;

    // ---------------------------------------------------------------------
    // Scalar probes (hierarchical refs) so Icarus dumps the internal systolic
    // activity -- unpacked arrays are not written to the VCD directly.  These
    // expose the diagonal skew of the west activation-valid strobes and two
    // corner accumulators, which is exactly what the waveform diagram shows.
    // ---------------------------------------------------------------------
    wire        west_v0 = dut.west_v[0];
    wire        west_v1 = dut.west_v[1];
    wire        west_v2 = dut.west_v[2];
    wire        west_v3 = dut.west_v[3];
    wire [3:0]  t_cnt   = dut.t;
    wire signed [ACC_W-1:0] c00 = dut.acc[0][0];
    wire signed [ACC_W-1:0] c33 = dut.acc[N-1][N-1];

    // ---------------------------------------------------------------------
    // Local operand / result storage for a single test case.
    // ---------------------------------------------------------------------
    logic signed [DW-1:0]    A [N][K];
    logic signed [DW-1:0]    B [K][N];
    longint                  Cgold [N][N];   // full-precision golden result

    // Golden model: plain triple-loop signed matmul.
    task automatic golden_model();
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                longint acc = 0;
                for (int k = 0; k < K; k++)
                    acc += longint'(A[i][k]) * longint'(B[k][j]);
                Cgold[i][j] = acc;
            end
    endtask

    // Pack the A/B arrays into the flattened DUT input buses (row-major).
    task automatic pack_inputs();
        for (int i = 0; i < N; i++)
            for (int k = 0; k < K; k++)
                a_flat[(i*K + k)*DW +: DW] = A[i][k];
        for (int k = 0; k < K; k++)
            for (int j = 0; j < N; j++)
                b_flat[(k*N + j)*DW +: DW] = B[k][j];
    endtask

    // Drive one GEMM through the accelerator and scoreboard the result.
    task automatic run_case(input string name);
        automatic longint dut_val;
        golden_model();
        pack_inputs();

        // Launch.
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Wait for completion with a generous timeout.
        fork : wait_done
            begin
                @(posedge done);
                disable wait_done;
            end
            begin
                repeat (4*(2*(N-1)+(K-1)) + 100) @(posedge clk);
                $fatal(1, "[%0t] TIMEOUT waiting for done in case '%s'", $time, name);
            end
        join

        // `done` pulses in S_DONE; c_flat already holds the stable accumulators.
        @(negedge clk);
        for (int i = 0; i < N; i++)
            for (int j = 0; j < N; j++) begin
                dut_val = $signed(c_flat[(i*N + j)*ACC_W +: ACC_W]);
                checks++;
                if (dut_val !== Cgold[i][j]) begin
                    errors++;
                    $display("  MISMATCH [%s] C[%0d][%0d] : dut=%0d gold=%0d",
                             name, i, j, dut_val, Cgold[i][j]);
                end
            end
        $display("  case %-20s : %0d elements checked%s",
                 name, N*N, (errors == 0) ? "  OK" : "  <== FAIL");
    endtask

    // Fill helpers ---------------------------------------------------------
    task automatic set_identity_B();
        for (int k = 0; k < K; k++)
            for (int j = 0; j < N; j++)
                B[k][j] = (k == j) ? 1 : 0;
    endtask

    // Simple xorshift PRNG so results are reproducible without $random seeds.
    logic [31:0] rng = 32'h1234_5678;
    function automatic logic signed [DW-1:0] rnd();
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        return rng[DW-1:0];   // full signed range
    endfunction

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    initial begin
        $dumpfile("systolic_matmul.vcd");
        $dumpvars(0, tb_systolic_matmul);

        start  = 1'b0;
        a_flat = '0;
        b_flat = '0;
        rst_n  = 1'b0;
        repeat (3) @(negedge clk);
        rst_n  = 1'b1;
        @(negedge clk);

        $display("Day14 systolic_matmul : N=%0d K=%0d DW=%0d ACC_W=%0d", N, K, DW, ACC_W);

        // --- Directed: A x I = A ------------------------------------------
        for (int i = 0; i < N; i++)
            for (int k = 0; k < K; k++)
                A[i][k] = i*K + k - 5;        // spread of +/- values
        set_identity_B();
        run_case("identity");

        // --- Directed: all zeros ------------------------------------------
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = 0;
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = 0;
        run_case("all_zero");

        // --- Directed: all ones (result = K everywhere) -------------------
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = 1;
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = 1;
        run_case("all_ones");

        // --- Directed: negative / mixed sign (signed MAC) -----------------
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = -(i + 1);
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = (j - 2);
        run_case("mixed_sign");

        // --- Directed: extreme magnitudes (accumulator headroom) ----------
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++)
            A[i][k] = (k[0]) ? -128 : 127;
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++)
            B[k][j] = (j[0]) ? 127 : -128;
        run_case("extremes");

        // --- Back-to-back launches (accumulator-clear regression) ---------
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = 2;
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = 3;
        run_case("b2b_first");
        for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = 5;
        for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = 7;
        run_case("b2b_second");   // must NOT accumulate on top of previous run

        // --- Randomized campaign ------------------------------------------
        for (int t = 0; t < 40; t++) begin
            for (int i = 0; i < N; i++) for (int k = 0; k < K; k++) A[i][k] = rnd();
            for (int k = 0; k < K; k++) for (int j = 0; j < N; j++) B[k][j] = rnd();
            run_case($sformatf("rand_%0d", t));
        end

        // --- Report -------------------------------------------------------
        $display("--------------------------------------------------");
        $display("Total element checks : %0d", checks);
        $display("Mismatches           : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

endmodule

`default_nettype wire
