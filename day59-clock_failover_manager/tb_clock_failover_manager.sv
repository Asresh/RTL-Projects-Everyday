// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_clock_failover_manager;
 localparam int S=4,W=12,M=2,CW=$clog2(W+1),SW=$clog2(S);
 logic clk=0,rst_n=0,enable=0,clear_faults=0,switch_ack=0;logic[S-1:0]heartbeat_async='0;
 logic[SW-1:0]active_source,requested_source;logic switch_req,no_source_fault;logic[S-1:0]source_qualified,fault_sticky;logic[15:0]failover_count;logic[S*CW-1:0]edge_count_flat;
 int checks=0,errors=0,seed=32'h59c10c;bit run_src[S];int div_src[S],phase_src[S];
 clock_failover_manager #(.SOURCES(S),.WINDOW_CYCLES(W),.MIN_EDGES(M)) dut(.*);always #5 clk=~clk;
 always @(negedge clk) for(int i=0;i<S;i++)if(run_src[i])begin phase_src[i]++;if(phase_src[i]>=div_src[i])begin heartbeat_async[i]<=~heartbeat_async[i];phase_src[i]=0;end end
 task automatic check(input bit c,input string m);checks++;if(!c)begin errors++;$error("CHECK FAILED: %s",m);end endtask
 task automatic wait_windows(input int n);repeat(n*W+5)@(posedge clk);endtask
 task automatic acknowledge;int g=0;while(!switch_req&&g<3*W)begin@(posedge clk);g++;end check(switch_req,"failover request timeout");if(switch_req)begin@(negedge clk);switch_ack=1;@(negedge clk);switch_ack=0;@(posedge clk);#1;end endtask
 initial begin
  $dumpfile("clock_failover_manager.vcd");$dumpvars(0,tb_clock_failover_manager);for(int i=0;i<S;i++)begin run_src[i]=0;div_src[i]=i+1;phase_src[i]=0;end
  repeat(4)@(posedge clk);rst_n=1;enable=1;run_src[0]=1;run_src[1]=1;run_src[2]=1;wait_windows(2);
  check(source_qualified[2:0]==3'b111,"three sources qualify");check(!source_qualified[3],"stopped source rejected");
  run_src[0]=0;wait_windows(2);acknowledge();check(active_source==1,"priority failover to source 1");check(failover_count==1,"first failover counted");check(fault_sticky[0]&&fault_sticky[3],"faults latch");
  run_src[1]=0;wait_windows(2);acknowledge();check(active_source==2,"second failover to source 2");check(failover_count==2,"second failover counted");
  run_src[2]=0;wait_windows(2);check(no_source_fault,"total loss reported");@(negedge clk);clear_faults=1;@(negedge clk);clear_faults=0;@(posedge clk);#1;check(!no_source_fault&&fault_sticky=='0,"diagnostics clear");
  for(int r=0;r<12;r++)begin int chosen;chosen=$urandom(seed)%S;for(int i=0;i<S;i++)begin run_src[i]=(i==chosen);div_src[i]=1+($urandom(seed)%3);end wait_windows(2);if(active_source!=chosen)acknowledge();check(active_source==chosen,"random recovery selects live source");end
  check(errors==0,"all checks passed");if(errors==0)$display("RESULT: *** PASS *** (%0d checks)",checks);else $display("RESULT: *** FAIL *** (%0d errors)",errors);$finish;
 end
 initial begin #200000;$fatal(1,"TIMEOUT");end
endmodule
