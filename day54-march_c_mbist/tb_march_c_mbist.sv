// Author: Asresh Kuricheti
// Self-checking testbench with an independent March C- transaction model.

`timescale 1ns/1ps
module tb_march_c_mbist;
  localparam int AW = 4;
  localparam int DW = 8;
  localparam int DEPTH = 1 << AW;

  logic clk = 0, rst_n = 0, start;
  logic busy, done, fail;
  logic [AW-1:0] fail_addr, mem_addr;
  logic [DW-1:0] fail_expected, fail_actual, mem_wdata, mem_rdata;
  logic [2:0] phase;
  logic mem_en, mem_we;
  logic [DW-1:0] memory [0:DEPTH-1];
  logic inject_fault;
  logic [AW-1:0] inject_addr;
  logic [DW-1:0] inject_mask;
  integer errors = 0;
  integer checks = 0;
  integer op_index = 0;
  integer completed_runs = 0;

  always #5 clk = ~clk;

  march_c_mbist #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW), .DEPTH(DEPTH)) dut (.*,
    .start_i(start), .busy_o(busy), .done_o(done), .fail_o(fail),
    .fail_addr_o(fail_addr), .fail_expected_o(fail_expected),
    .fail_actual_o(fail_actual), .phase_o(phase), .mem_en_o(mem_en),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_rdata_i(mem_rdata));

  always_ff @(posedge clk) begin
    if (mem_en) begin
      if (mem_we) memory[mem_addr] <= mem_wdata;
      else mem_rdata <= memory[mem_addr] ^
           ((inject_fault && (mem_addr == inject_addr)) ? inject_mask : '0);
    end
  end

  task automatic check(input bit condition, input string message);
    checks = checks + 1;
    if (!condition) begin
      errors = errors + 1;
      $display("ERROR @ %0t: %s", $time, message);
    end
  endtask

  task automatic expected_op(input integer index, output bit exp_we,
                              output integer exp_addr, output logic [DW-1:0] exp_data);
    integer k;
    begin
      exp_we = 0; exp_addr = 0; exp_data = '0;
      if (index < DEPTH) begin
        exp_we = 1; exp_addr = DEPTH-1-index; exp_data = '0;
      end else if (index < 3*DEPTH) begin
        k = index-DEPTH; exp_addr = k/2; exp_we = k[0]; exp_data = '1;
      end else if (index < 5*DEPTH) begin
        k = index-3*DEPTH; exp_addr = k/2; exp_we = k[0]; exp_data = '0;
      end else if (index < 7*DEPTH) begin
        k = index-5*DEPTH; exp_addr = DEPTH-1-k/2; exp_we = k[0]; exp_data = '1;
      end else if (index < 9*DEPTH) begin
        k = index-7*DEPTH; exp_addr = DEPTH-1-k/2; exp_we = k[0]; exp_data = '0;
      end else begin
        k = index-9*DEPTH; exp_addr = DEPTH-1-k; exp_we = 0; exp_data = '0;
      end
    end
  endtask

  always @(posedge clk) begin : protocol_scoreboard
    bit ew;
    integer ea;
    logic [DW-1:0] ed;
    if (rst_n && mem_en) begin
      expected_op(op_index, ew, ea, ed);
      check(mem_we === ew, $sformatf("op %0d write mismatch", op_index));
      check(mem_addr === AW'(ea), $sformatf("op %0d address got %0d expected %0d", op_index, mem_addr, ea));
      if (ew) check(mem_wdata === ed, $sformatf("op %0d write data mismatch", op_index));
      op_index = op_index + 1;
    end
    if (done) begin
      check(op_index == 10*DEPTH, $sformatf("operation count %0d expected %0d", op_index, 10*DEPTH));
      completed_runs = completed_runs + 1;
    end
  end

  task automatic run_test(input bit with_fault, input integer fault_address,
                          input logic [DW-1:0] fault_mask);
    integer i, timeout;
    begin
      while (busy) @(posedge clk);
      for (i = 0; i < DEPTH; i = i+1) memory[i] = $urandom;
      inject_fault = with_fault;
      inject_addr = AW'(fault_address);
      inject_mask = fault_mask;
      op_index = 0;
      @(negedge clk); start = 1;
      @(negedge clk); start = 0;
      timeout = 0;
      while (!done && timeout < 20*DEPTH) begin
        @(posedge clk); timeout = timeout + 1;
      end
      check(done, "timeout waiting for completion");
      @(negedge clk);
      if (with_fault) begin
        check(fail, "injected read fault was not detected");
        check(fail_addr == AW'(fault_address), "first-failure address mismatch");
        check((fail_actual ^ fail_expected) == fault_mask, "failure syndrome mismatch");
      end else check(!fail, "clean memory unexpectedly failed");
      for (i = 0; i < DEPTH; i = i+1)
        check(memory[i] == '0, $sformatf("final memory[%0d] is not zero", i));
    end
  endtask

  initial begin : stimulus
    integer n;
    $dumpfile("march_c_mbist.vcd");
    $dumpvars(0, tb_march_c_mbist);
    start = 0; inject_fault = 0; inject_addr = 0; inject_mask = 0; mem_rdata = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    run_test(0, 0, 0);
    run_test(1, 5, 8'h04);
    for (n = 0; n < 8; n = n+1)
      run_test(1, $urandom_range(0, DEPTH-1), 8'(1 << $urandom_range(0, DW-1)));
    check(completed_runs == 10, "not all directed/randomized runs completed");
    if (errors == 0) begin
      $display("Checks: %0d across %0d complete MBIST runs", checks, completed_runs);
      $display("RESULT: *** PASS ***");
    end else begin
      $display("RESULT: *** FAIL *** (%0d errors)", errors);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #200000;
    $display("RESULT: *** FAIL *** (global timeout)");
    $fatal(1);
  end
endmodule
