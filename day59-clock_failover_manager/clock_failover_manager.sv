// Author: Asresh Kuricheti
module clock_failover_manager #(
 parameter int SOURCES=4, WINDOW_CYCLES=16, MIN_EDGES=3,
 parameter int COUNT_W=$clog2(WINDOW_CYCLES+1), SRC_W=(SOURCES<=1)?1:$clog2(SOURCES)
)(input logic clk,rst_n,enable,clear_faults,input logic [SOURCES-1:0] heartbeat_async,
 input logic switch_ack,output logic [SRC_W-1:0] active_source,requested_source,
 output logic switch_req,output logic [SOURCES-1:0] source_qualified,fault_sticky,
 output logic no_source_fault,output logic [15:0] failover_count,
 output logic [SOURCES*COUNT_W-1:0] edge_count_flat);
 localparam int WIN_W=(WINDOW_CYCLES<=1)?1:$clog2(WINDOW_CYCLES);
 logic [SOURCES-1:0] hb_meta,hb_sync,hb_prev,next_qualified;
 logic [COUNT_W-1:0] edge_count[SOURCES]; logic [WIN_W-1:0] window_count;
 logic candidate_valid; logic [SRC_W-1:0] candidate; integer i;
 always_comb begin
  candidate_valid=0; candidate='0;
  for(int k=0;k<SOURCES;k++) if(!candidate_valid&&next_qualified[k]) begin candidate_valid=1; candidate=SRC_W'(k); end
  for(int k=0;k<SOURCES;k++) edge_count_flat[k*COUNT_W+:COUNT_W]=edge_count[k];
 end
 always_ff @(posedge clk or negedge rst_n) if(!rst_n) begin hb_meta<='0;hb_sync<='0;hb_prev<='0; end
 else begin hb_meta<=heartbeat_async;hb_sync<=hb_meta;hb_prev<=hb_sync; end
 always_comb for(int k=0;k<SOURCES;k++) next_qualified[k]=(edge_count[k]+COUNT_W'(hb_sync[k]^hb_prev[k]))>=MIN_EDGES;
 always_ff @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin active_source<='0;requested_source<='0;switch_req<=0;source_qualified<='0;fault_sticky<='0;no_source_fault<=0;failover_count<='0;window_count<='0;for(i=0;i<SOURCES;i++)edge_count[i]<='0; end
  else begin
   if(clear_faults) begin fault_sticky<='0;no_source_fault<=0; end
   if(!enable) begin window_count<='0;source_qualified<='0;switch_req<=0;for(i=0;i<SOURCES;i++)edge_count[i]<='0; end
   else begin
    for(i=0;i<SOURCES;i++) if((hb_sync[i]^hb_prev[i])&&edge_count[i]!={COUNT_W{1'b1}}) edge_count[i]<=edge_count[i]+1'b1;
    if(window_count==WINDOW_CYCLES-1) begin
     window_count<='0;source_qualified<=next_qualified;fault_sticky<=fault_sticky|~next_qualified;for(i=0;i<SOURCES;i++)edge_count[i]<='0;
     if(!switch_req&&!next_qualified[active_source]) if(candidate_valid) begin requested_source<=candidate;if(candidate!=active_source)switch_req<=1;end else no_source_fault<=1;
    end else window_count<=window_count+1'b1;
    if(switch_req&&switch_ack) begin active_source<=requested_source;switch_req<=0;failover_count<=failover_count+1'b1; end
   end
  end
 end
endmodule
