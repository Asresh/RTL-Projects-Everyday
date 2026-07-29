// ============================================================================
//  Day 10 — Self-checking testbench for hamming_secded (SECDED Hamming ECC)
//
//  Strategy
//  --------
//  The DUT encodes data_i, XORs in an `err_inject` bit-flip mask (the "channel"),
//  then decodes.  The TB is the golden model: it classifies each transaction by
//  how many codeword bits were flipped and predicts the exact result.
//
//    0 flips -> no error   : data_o == data_i, single=0, double=0
//    1 flip  -> single err : data_o == data_i (CORRECTED), single=1, double=0
//    2 flips -> double err : uncorrectable, double=1, single=0 (data don't-care)
//
//  Because the DUT is a 2-cycle pipeline, a scoreboard queue tracks in-flight
//  transactions and checks each result as it emerges (out_valid).
//
//  Stimulus: a short directed front sequence (nice for the captured waveform),
//  an exhaustive single-error sweep over every codeword bit, an exhaustive
//  double-error sweep over many bit pairs, plus randomized data + error counts.
//  Dumps hamming_secded.vcd and prints "RESULT: *** PASS ***" only if clean.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_hamming_secded;
  localparam int DW    = 64;
  localparam int PBITS = 7;                 // for DW=64 -> (72,64) SECDED
  localparam int CW    = DW + PBITS + 1;    // 72

  // -------------------------------------------------------------------------
  //  DUT
  // -------------------------------------------------------------------------
  reg               clk, rst_n;
  reg               in_valid;
  reg  [DW-1:0]     data_i;
  reg  [CW-1:0]     err_inject;

  wire              out_valid;
  wire [DW-1:0]     data_o;
  wire              single_error_o, double_error_o, error_o;

  hamming_secded #(.DATA_WIDTH(DW)) dut (
    .clk            (clk),
    .rst_n          (rst_n),
    .in_valid       (in_valid),
    .data_i         (data_i),
    .err_inject     (err_inject),
    .out_valid      (out_valid),
    .data_o         (data_o),
    .single_error_o (single_error_o),
    .double_error_o (double_error_o),
    .error_o        (error_o)
  );

  // -------------------------------------------------------------------------
  //  Clock : 100 MHz (10 ns period).  Rising edges at 5,15,25,... ns.
  // -------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // -------------------------------------------------------------------------
  //  Scoreboard
  // -------------------------------------------------------------------------
  int          errors  = 0;
  int          checks  = 0;
  bit [DW-1:0] exp_data  [$];
  int          exp_nflip [$];

  function automatic int count_ones(input [CW-1:0] v);
    int c; int i;
    begin
      c = 0;
      for (i = 0; i < CW; i = i + 1) c = c + v[i];
      count_ones = c;
    end
  endfunction

  bit [DW-1:0] ed;
  int          nf;

  // Monitor: push on drive, pop+check on result.  FIFO order absorbs the
  // 2-cycle pipeline latency automatically.
  always @(posedge clk) begin
    if (rst_n) begin
      if (in_valid) begin
        exp_data.push_back(data_i);
        exp_nflip.push_back(count_ones(err_inject));
      end
      if (out_valid) begin
        ed = exp_data.pop_front();
        nf = exp_nflip.pop_front();
        checks = checks + 1;
        case (nf)
          0: begin
            if (single_error_o || double_error_o || error_o || data_o !== ed) begin
              errors = errors + 1;
              $display("[%0t] FAIL no-err: data_o=%h exp=%h s=%b d=%b",
                       $time, data_o, ed, single_error_o, double_error_o);
            end
          end
          1: begin
            if (!single_error_o || double_error_o || data_o !== ed) begin
              errors = errors + 1;
              $display("[%0t] FAIL single: data_o=%h exp=%h s=%b d=%b",
                       $time, data_o, ed, single_error_o, double_error_o);
            end
          end
          2: begin
            if (!double_error_o || single_error_o) begin
              errors = errors + 1;
              $display("[%0t] FAIL double: s=%b d=%b (expected d=1,s=0)",
                       $time, single_error_o, double_error_o);
            end
          end
          default: ; // >2 flips: beyond SECDED guarantee, not scored
        endcase
      end
    end
  end

  // -------------------------------------------------------------------------
  //  Stimulus helpers
  // -------------------------------------------------------------------------
  task automatic drive(input [DW-1:0] d, input [CW-1:0] mask);
    begin
      @(negedge clk);
      in_valid   = 1'b1;
      data_i     = d;
      err_inject = mask;
      @(negedge clk);
      in_valid   = 1'b0;
      data_i     = '0;
      err_inject = '0;
    end
  endtask

  function automatic [CW-1:0] onehot(input int p);
    onehot = ({{(CW-1){1'b0}}, 1'b1} << p);
  endfunction

  // -------------------------------------------------------------------------
  //  Test program
  // -------------------------------------------------------------------------
  integer i, a, b;
  reg [DW-1:0] rd;
  reg [CW-1:0] mask;
  int          n, p0, p1;

  initial begin
    $dumpfile("hamming_secded.vcd");
    $dumpvars(0, tb_hamming_secded);

    in_valid   = 1'b0;
    data_i     = '0;
    err_inject = '0;
    rst_n      = 1'b0;
    repeat (3) @(negedge clk);
    rst_n      = 1'b1;
    @(negedge clk);

    // ---- Directed front sequence (drives a clean captured waveform) ----
    drive(64'h0000_0000_0000_00AA, '0);              // no error
    drive(64'h0000_0000_0000_0155, onehot(9));       // single error @bit 9 -> corrected
    drive(64'h0000_0000_0000_00F0, onehot(3)|onehot(20)); // double error -> detected
    drive(64'h0000_0000_0000_FFFF, '0);              // no error
    drive(64'hDEAD_BEEF_CAFE_F00D, onehot(0));       // single err on overall parity bit
    repeat (4) @(negedge clk);                       // let pipeline drain on the wave

    // ---- Exhaustive single-error sweep over every codeword bit ----
    for (i = 0; i < CW; i = i + 1) begin
      rd = {$random, $random};
      drive(rd, onehot(i));
    end

    // ---- Exhaustive-ish double-error sweep (many distinct bit pairs) ----
    for (a = 0; a < CW; a = a + 1) begin
      b = (a + 1 + (a % 5)) % CW;   // a partner bit, always distinct from a
      if (b == a) b = (a + 1) % CW;
      rd = {$random, $random};
      drive(rd, onehot(a) | onehot(b));
    end

    // ---- Randomized: random data, random 0/1/2-bit error injection ----
    for (i = 0; i < 4000; i = i + 1) begin
      rd   = {$random, $random};
      n    = $urandom_range(0, 2);
      mask = '0;
      if (n >= 1) begin
        p0   = $urandom_range(0, CW-1);
        mask = onehot(p0);
      end
      if (n == 2) begin
        p1 = $urandom_range(0, CW-1);
        while (p1 == p0) p1 = $urandom_range(0, CW-1);
        mask = mask | onehot(p1);
      end
      drive(rd, mask);
    end

    repeat (6) @(negedge clk);   // drain pipeline

    // -------------------------------------------------------------------------
    //  Verdict
    // -------------------------------------------------------------------------
    $display("-----------------------------------------------------------");
    $display("checks executed : %0d", checks);
    $display("mismatches      : %0d", errors);
    if (errors == 0 && checks > 0)
      $display("RESULT: *** PASS ***");
    else
      $display("RESULT: *** FAIL ***");
    $display("-----------------------------------------------------------");
    $finish;
  end

  // -------------------------------------------------------------------------
  //  Global timeout watchdog
  // -------------------------------------------------------------------------
  initial begin
    #2_000_000;   // 2 ms of sim time
    $display("RESULT: *** FAIL *** (timeout)");
    $finish;
  end
endmodule

`default_nettype wire
