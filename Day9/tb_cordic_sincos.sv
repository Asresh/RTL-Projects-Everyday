// -----------------------------------------------------------------------------
// Day 9 : tb_cordic_sincos  --  self-checking testbench for the CORDIC engine
// -----------------------------------------------------------------------------
// Verification strategy
//   * GOLDEN MODEL : the exact IEEE-754 double results from the SystemVerilog
//     $cos / $sin system functions, converted to the DUT's Q2.FRAC format.
//   * STIMULUS : directed corner angles (0, +/-pi/6, +/-pi/4, +/-pi/3, +/-pi/2,
//     the quadrant-fold boundaries, and near +/-pi) followed by a long stream of
//     randomized angles in [-pi, pi].  All stimulus is applied back-to-back with
//     in_valid held high, so the pipeline is exercised at full throughput.
//   * CHECKING : the engine has a fixed latency and preserves input order, so
//     golden results are pushed into arrays as angles are driven (index nin) and
//     popped as results appear (index nout).  Each result is compared to golden
//     with an absolute tolerance of TOL_FX LSBs; the worst-case error seen is
//     tracked and reported.
//   * A cycle-count TIMEOUT guards against a stalled pipeline.
//   * A VCD ("cordic_sincos.vcd") is dumped for waveform inspection.
//   * On success the bench prints the exact string  RESULT: *** PASS ***
// -----------------------------------------------------------------------------

`default_nettype none
`timescale 1ns/1ps

module tb_cordic_sincos;

    // -------------------------------------------------------------- parameters
    localparam int WIDTH = 16;
    localparam int ITER  = 12;
    localparam int FRAC  = WIDTH - 3;
    localparam int LAT   = ITER + 1;          // pipeline latency in cycles

    // absolute error budget (in LSBs of the Q2.FRAC format)
    localparam int TOL_FX = 12;               // ~1.5e-3 at FRAC=13

    // -------------------------------------------------------------------- clock
    reg clk = 1'b0;
    always #5 clk = ~clk;                     // 100 MHz

    // ------------------------------------------------------------------- signals
    reg                     rst_n;
    reg                     in_valid;
    reg  signed [WIDTH-1:0] theta;
    wire                    out_valid;
    wire signed [WIDTH-1:0] cos_o, sin_o;

    // --------------------------------------------------------------------- DUT
    cordic_sincos #(.WIDTH(WIDTH), .ITER(ITER)) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (in_valid),
        .theta     (theta),
        .out_valid (out_valid),
        .cos_o     (cos_o),
        .sin_o     (sin_o)
    );

    // ------------------------------------------------------------ golden storage
    localparam int NMAX = 4096;
    reg signed [WIDTH-1:0] g_cos [0:NMAX-1];
    reg signed [WIDTH-1:0] g_sin [0:NMAX-1];
    real                   g_ang [0:NMAX-1];   // driven angle (radians) for logs

    integer nin  = 0;                          // angles driven
    integer nout = 0;                          // results checked
    integer errors = 0;
    integer max_err = 0;                        // worst |error| in LSBs, cos or sin
    integer total   = 0;                        // total angles to drive (set later)
    reg     driving_done = 1'b0;

    // ------------------------------------------------------------- fx helpers
    function automatic signed [WIDTH-1:0] to_fx(input real r);
        to_fx = $rtoi(r * (2.0 ** FRAC) + (r >= 0.0 ? 0.5 : -0.5));
    endfunction
    function automatic real to_real(input signed [WIDTH-1:0] v);
        to_real = $itor(v) / (2.0 ** FRAC);
    endfunction
    function automatic integer iabs(input integer v);
        iabs = (v < 0) ? -v : v;
    endfunction

    // -------------------------------------------------- drive one angle (1 clk)
    task automatic drive(input real ang);
        begin
            @(negedge clk);
            in_valid <= 1'b1;
            theta    <= to_fx(ang);
            g_cos[nin] = to_fx($cos(ang));
            g_sin[nin] = to_fx($sin(ang));
            g_ang[nin] = ang;
            nin        = nin + 1;
        end
    endtask

    // ---------------------------------------------------- output checker (clk)
    integer d_c, d_s;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            d_c = iabs($signed(cos_o) - $signed(g_cos[nout]));
            d_s = iabs($signed(sin_o) - $signed(g_sin[nout]));
            if (d_c > max_err) max_err = d_c;
            if (d_s > max_err) max_err = d_s;
            if (d_c > TOL_FX || d_s > TOL_FX) begin
                errors = errors + 1;
                $display("  [MISMATCH] ang=%+8.5f  cos: dut=%+8.5f ref=%+8.5f (err=%0d LSB)  sin: dut=%+8.5f ref=%+8.5f (err=%0d LSB)",
                         g_ang[nout],
                         to_real(cos_o), to_real(g_cos[nout]), d_c,
                         to_real(sin_o), to_real(g_sin[nout]), d_s);
            end
            nout = nout + 1;
        end
    end

    // -------------------------------------------------------------- timeout
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout: nin=%0d nout=%0d)", nin, nout);
        $finish;
    end

    // --------------------------------------------------------- stimulus program
    real pi;
    integer i;
    integer rnd;
    real    ang;
    initial begin
        $dumpfile("cordic_sincos.vcd");
        $dumpvars(0, tb_cordic_sincos);

        pi       = 3.14159265358979323846;
        in_valid = 1'b0;
        theta    = '0;
        rst_n    = 1'b0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // ---- directed corner angles ----------------------------------------
        drive( 0.0        );
        drive(  pi/6.0    );   drive( -pi/6.0    );
        drive(  pi/4.0    );   drive( -pi/4.0    );
        drive(  pi/3.0    );   drive( -pi/3.0    );
        drive(  pi/2.0    );   drive( -pi/2.0    );   // convergence boundary
        drive(  pi/2.0+0.2);   drive( -pi/2.0-0.2);   // just inside 2nd/3rd quad
        drive(  2.0*pi/3.0);   drive( -2.0*pi/3.0);   // folded angles
        drive(  3.10       );  drive( -3.10       );  // near +/-pi

        // ---- randomized angles in [-pi, pi] --------------------------------
        for (i = 0; i < 500; i = i + 1) begin
            rnd = $random % 3142;           // milli-radians in (-3142, 3142)
            ang = rnd / 1000.0;             // ~ [-3.141, 3.141]
            drive(ang);
        end

        // stop driving, let the pipeline flush
        @(negedge clk);
        in_valid <= 1'b0;
        total = nin;

        // wait until every driven angle has been checked
        wait (nout == total);
        repeat (4) @(negedge clk);

        $display("--------------------------------------------------------------");
        $display("CORDIC sin/cos  WIDTH=%0d  ITER=%0d  FRAC=%0d  latency=%0d cyc",
                 WIDTH, ITER, FRAC, LAT);
        $display("angles checked : %0d", nout);
        $display("tolerance      : %0d LSB (%.6f)", TOL_FX, TOL_FX / (2.0 ** FRAC));
        $display("worst error    : %0d LSB (%.6f)", max_err, max_err / (2.0 ** FRAC));
        $display("mismatches     : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire
