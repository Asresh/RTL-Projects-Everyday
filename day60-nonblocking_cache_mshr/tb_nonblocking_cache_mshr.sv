// Author: Asresh Kuricheti
`timescale 1ns/1ps
module tb_nonblocking_cache_mshr;
    localparam int ADDR_W=24, DATA_W=64, ID_W=8, LINE_BYTES=64;
    localparam int ENTRIES=4, WAITERS=4, TAG_W=$clog2(ENTRIES);
    localparam int MAX_LINES=1024, MAX_IDS=256;

    logic clk=0, rst_n=0, flush=0;
    logic req_valid=0, req_ready; logic [ADDR_W-1:0] req_addr='0; logic [ID_W-1:0] req_id='0;
    logic mem_req_valid, mem_req_ready=1; logic [ADDR_W-1:0] mem_req_addr; logic [TAG_W-1:0] mem_req_tag;
    logic fill_valid=0, fill_ready; logic [TAG_W-1:0] fill_tag='0; logic [DATA_W-1:0] fill_data='0; logic fill_error=0;
    logic resp_valid, resp_ready=1; logic [ID_W-1:0] resp_id; logic [DATA_W-1:0] resp_data; logic resp_error;
    logic [$clog2(ENTRIES+1)-1:0] occupancy;
    logic [31:0] allocation_count, merge_count; logic full_stall_sticky, orphan_fill_sticky;

    int checks=0, errors=0, accepted=0, responses=0, memory_reads=0;
    int seed=32'h60cace55, next_id=1, expected_pending=0;
    logic expected_valid [MAX_IDS];
    logic [DATA_W-1:0] expected_data [MAX_IDS];
    logic expected_error [MAX_IDS];
    logic captured_valid [MAX_LINES];
    logic [TAG_W-1:0] captured_tag [MAX_LINES];
    bit random_backpressure=0;

    nonblocking_cache_mshr #(.ADDR_W(ADDR_W),.DATA_W(DATA_W),.ID_W(ID_W),
        .LINE_BYTES(LINE_BYTES),.ENTRIES(ENTRIES),.WAITERS(WAITERS)) dut (.*);

    always #5 clk=~clk;

    function automatic int line_index(input logic [ADDR_W-1:0] address);
        line_index = address / LINE_BYTES;
    endfunction

    function automatic logic [DATA_W-1:0] line_data(input logic [ADDR_W-1:0] address);
        logic [ADDR_W-1:0] aligned;
        begin
            aligned = (address / LINE_BYTES) * LINE_BYTES;
            line_data = {16'hca5e, 24'(aligned), 16'h600d, 8'(aligned >> 6)};
        end
    endfunction

    task automatic check(input bit condition, input string message);
        checks++;
        if (!condition) begin errors++; $error("CHECK FAILED: %s",message); end
    endtask

    task automatic issue_request(input logic [ADDR_W-1:0] address,
                                 input logic [ID_W-1:0] id);
        int guard;
        begin
            guard=0;
            @(negedge clk); req_valid=1; req_addr=address; req_id=id;
            #1;
            while (!req_ready && guard<200) begin @(negedge clk); #1; guard++; end
            check(req_ready,"request eventually accepted");
            if (req_ready) begin
                @(posedge clk); #1;
                expected_valid[id]=1;
                expected_data[id]=line_data(address);
                expected_error[id]=1'b0;
                expected_pending++;
                accepted++;
            end
            @(negedge clk); req_valid=0;
        end
    endtask

    task automatic fill_line(input logic [ADDR_W-1:0] address, input bit error_value);
        int idx, guard; logic [TAG_W-1:0] tag_value;
        begin
            idx=line_index(address); guard=0;
            while (!captured_valid[idx] && guard<200) begin @(posedge clk); guard++; end
            check(captured_valid[idx],"memory request captured before fill");
            tag_value=captured_tag[idx];
            @(negedge clk); fill_valid=1; fill_tag=tag_value;
            fill_data=line_data(address); fill_error=error_value;
            #1; guard=0;
            while (!fill_ready && guard<200) begin @(negedge clk); #1; guard++; end
            check(fill_ready,"fill accepted for live issued tag");
            if (fill_ready) begin
                @(posedge clk); #1; captured_valid[idx]=0;
            end
            @(negedge clk); fill_valid=0; fill_error=0;
        end
    endtask

    task automatic wait_for_responses(input int target_pending);
        int guard;
        begin
            guard=0;
            while (expected_pending>target_pending && guard<1000) begin
                @(posedge clk); #2; guard++;
            end
            check(expected_pending==target_pending,"all expected responses retired");
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && mem_req_valid && mem_req_ready) begin
            int idx;
            idx=line_index(mem_req_addr);
            check(!captured_valid[idx],"one outstanding memory read per cache line");
            captured_valid[idx]=1;
            captured_tag[idx]=mem_req_tag;
            memory_reads++;
        end
    end

    always @(posedge clk) begin
        if (rst_n && resp_valid && resp_ready) begin
            check(expected_valid[resp_id],"response ID exists in golden scoreboard");
            if (expected_valid[resp_id]) begin
                check(resp_data===expected_data[resp_id],"response data matches memory model");
                check(resp_error===expected_error[resp_id],"response error matches memory model");
                expected_valid[resp_id]=0;
                expected_pending--;
                responses++;
            end
        end
    end

    always @(negedge clk)
        if (random_backpressure)
            resp_ready <= (($urandom(seed)%4)!=0);

    initial begin : stimulus
        logic [ADDR_W-1:0] a,b,c,d,e,f,g,h;
        int before_reads, before_alloc, before_merge, held_id;
        logic [DATA_W-1:0] held_data;
        bit chosen [4]; int remaining, pick, count;
        a=24'h001000; b=24'h002000; c=24'h003000; d=24'h004000;
        e=24'h005000; f=24'h006000; g=24'h007000; h=24'h008000;
        for(int n=0;n<MAX_IDS;n++) expected_valid[n]=0;
        for(int n=0;n<MAX_LINES;n++) captured_valid[n]=0;
        $dumpfile("nonblocking_cache_mshr.vcd");
        $dumpvars(0,tb_nonblocking_cache_mshr);

        repeat(4) @(posedge clk); rst_n=1;

        // Directed merge test: A has three waiters, B completes first.
        before_reads=memory_reads; before_merge=merge_count;
        issue_request(a,8'd1); issue_request(a+24'd12,8'd2);
        issue_request(a+24'd60,8'd3); issue_request(b,8'd4);
        repeat(4) @(posedge clk);
        check(memory_reads-before_reads==2,"merged requests produce one read per line");
        check(merge_count-before_merge==2,"two secondary misses counted");
        fill_line(b,0); wait_for_responses(3);

        // Response must remain stable while the consumer is backpressured.
        resp_ready=0; fill_line(a,0);
        while(!resp_valid) @(posedge clk); #1;
        held_id=resp_id; held_data=resp_data;
        repeat(3) begin @(posedge clk); #1;
            check(resp_valid && resp_id==held_id && resp_data==held_data,
                  "response held stable under backpressure");
        end
        resp_ready=1; wait_for_responses(0);

        // Fill error is broadcast to every waiter on that miss.
        issue_request(c,8'd5); issue_request(c+24'd4,8'd6);
        expected_error[5]=1; expected_error[6]=1;
        fill_line(c,1); wait_for_responses(0);

        // All MSHRs occupied: a fifth distinct line stalls until one drains.
        resp_ready=0; before_alloc=allocation_count;
        issue_request(d,8'd7); issue_request(e,8'd8);
        issue_request(f,8'd9); issue_request(g,8'd10);
        check(occupancy==ENTRIES,"all entries occupied");
        @(negedge clk); req_valid=1; req_addr=h; req_id=8'd11;
        repeat(3) begin @(posedge clk); #1; check(!req_ready,"fifth miss stalls when bank full"); end
        fill_line(f,0);
        repeat(2) @(posedge clk); #1; check(!req_ready,"filled entry stays allocated while response blocked");
        resp_ready=1;
        @(negedge clk); #1;
        while(!req_ready) begin @(negedge clk); #1; end
        @(posedge clk); #1;
        expected_valid[11]=1; expected_data[11]=line_data(h); expected_error[11]=0;
        expected_pending++; accepted++;
        @(negedge clk); req_valid=0;
        fill_line(d,0); fill_line(e,0); fill_line(g,0); fill_line(h,0);
        wait_for_responses(0);
        check(allocation_count-before_alloc==5,"freed entry reused for fifth miss");
        check(full_stall_sticky,"capacity stall recorded");

        // Eight randomized batches: 1..4 waiters per line and shuffled fills.
        random_backpressure=1;
        for(int batch=0;batch<8;batch++) begin
            before_reads=memory_reads; before_alloc=allocation_count;
            before_merge=merge_count; count=0;
            for(int lane=0;lane<4;lane++) begin
                int waiters_for_line; logic [ADDR_W-1:0] base;
                base=(24'(32+batch*4+lane))*LINE_BYTES;
                waiters_for_line=1+($urandom(seed)%WAITERS);
                count+=waiters_for_line;
                for(int w=0;w<waiters_for_line;w++) begin
                    issue_request(base+24'(w*4),ID_W'(next_id));
                    next_id++;
                end
            end
            repeat(5) @(posedge clk);
            check(memory_reads-before_reads==4,"random batch allocates four memory reads");
            check(allocation_count-before_alloc==4,"random batch allocates four MSHRs");
            check(merge_count-before_merge==count-4,"random batch merges secondary misses");
            for(int n=0;n<4;n++) chosen[n]=0;
            remaining=4;
            while(remaining>0) begin
                pick=$urandom(seed)%4;
                if(!chosen[pick]) begin
                    chosen[pick]=1; remaining--;
                    fill_line((24'(32+batch*4+pick))*LINE_BYTES,0);
                end
            end
            wait_for_responses(0);
        end
        random_backpressure=0; resp_ready=1;

        // A flush cancels an allocated request; a late fill is rejected and logged.
        issue_request(a,8'd240); repeat(3) @(posedge clk);
        check(occupancy==1,"flush setup has one live entry");
        @(negedge clk); flush=1; @(negedge clk); flush=0; #1;
        check(occupancy==0,"flush cancels all active MSHRs");
        expected_valid[240]=0; expected_pending--;
        @(negedge clk); fill_valid=1; fill_tag=captured_tag[line_index(a)];
        fill_data=line_data(a); @(posedge clk); #1;
        check(!fill_ready,"late fill rejected after flush");
        @(negedge clk); fill_valid=0; captured_valid[line_index(a)]=0;
        @(posedge clk); #1; check(orphan_fill_sticky,"orphan fill diagnostic latched");

        check(accepted==responses+1,"every non-flushed request received one response");
        check(errors==0,"all checks passed");
        if(errors==0)
            $display("RESULT: *** PASS *** (%0d requests, %0d responses, %0d checks)",accepted,responses,checks);
        else begin
            $display("RESULT: *** FAIL *** (%0d errors)",errors);
            $fatal(1,"self-checking testbench failed");
        end
        $finish;
    end

    initial begin #1000000; $fatal(1,"TIMEOUT"); end
endmodule
