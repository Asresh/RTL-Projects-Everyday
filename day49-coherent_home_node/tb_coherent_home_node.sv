// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_coherent_home_node;
    localparam integer NUM_CLIENTS = 4;
    localparam integer ADDR_W = 16;
    localparam integer DATA_W = 32;
    localparam integer CLIENT_W = 2;
    localparam [1:0] OP_READ_SHARED=0, OP_READ_UNIQUE=1,
                     OP_WRITEBACK=2, OP_EVICT=3;

    logic clk = 0;
    logic rst_n = 0;
    logic req_valid_i;
    wire req_ready_o;
    logic [1:0] req_opcode_i;
    logic [CLIENT_W-1:0] req_src_i;
    logic [ADDR_W-1:0] req_addr_i;
    logic [DATA_W-1:0] req_data_i;
    logic [NUM_CLIENTS-1:0] req_sharers_i;
    logic req_owner_valid_i;
    logic [CLIENT_W-1:0] req_owner_i;
    logic req_dirty_i;
    wire [NUM_CLIENTS-1:0] snoop_valid_o;
    logic [NUM_CLIENTS-1:0] snoop_ready_i;
    wire snoop_invalidate_o;
    wire [ADDR_W-1:0] snoop_addr_o;
    logic [NUM_CLIENTS-1:0] snoop_rsp_valid_i;
    logic [NUM_CLIENTS-1:0] snoop_rsp_dirty_i;
    logic [NUM_CLIENTS*DATA_W-1:0] snoop_rsp_data_i;
    wire mem_req_valid_o;
    logic mem_req_ready_i;
    wire mem_req_write_o;
    wire [ADDR_W-1:0] mem_req_addr_o;
    wire [DATA_W-1:0] mem_req_data_o;
    logic mem_rsp_valid_i;
    logic [DATA_W-1:0] mem_rsp_data_i;
    wire rsp_valid_o;
    logic rsp_ready_i;
    wire [CLIENT_W-1:0] rsp_dst_o;
    wire [DATA_W-1:0] rsp_data_o;
    wire rsp_dirty_forwarded_o;
    wire dir_update_valid_o;
    wire [NUM_CLIENTS-1:0] dir_sharers_o;
    wire dir_owner_valid_o;
    wire [CLIENT_W-1:0] dir_owner_o;
    wire dir_dirty_o, busy_o;
    wire [2:0] state_o;

    integer errors = 0;
    integer checks = 0;
    integer seed = 32'h49c0ffee;
    integer n, k;

    coherent_home_node #(
        .NUM_CLIENTS(NUM_CLIENTS), .ADDR_W(ADDR_W), .DATA_W(DATA_W)
    ) dut (.*);

    always #5 clk = ~clk;

    task automatic fail(input [8*120-1:0] message);
        begin
            errors = errors + 1;
            $display("ERROR: %0s at t=%0t", message, $time);
        end
    endtask

    task automatic run_transaction(
        input [1:0] op,
        input [CLIENT_W-1:0] src,
        input [ADDR_W-1:0] addr,
        input [DATA_W-1:0] write_data,
        input [NUM_CLIENTS-1:0] sharers,
        input owner_valid,
        input [CLIENT_W-1:0] owner,
        input dirty,
        input [DATA_W-1:0] memory_data
    );
        reg [NUM_CLIENTS-1:0] exp_targets;
        reg [NUM_CLIENTS-1:0] exp_sharers;
        reg exp_owner_valid, exp_dirty, exp_mem_write, exp_forwarded;
        reg [CLIENT_W-1:0] exp_owner;
        reg [DATA_W-1:0] exp_data, owner_data;
        integer guard;
        reg snoops_answered, memory_answered;
        begin
            owner_data = 32'hD170_0000 | owner;
            exp_targets = 0;
            if (op == OP_READ_SHARED && owner_valid && dirty && owner != src)
                exp_targets[owner] = 1;
            else if (op == OP_READ_UNIQUE) begin
                exp_targets = sharers;
                exp_targets[src] = 0;
                if (owner_valid && owner != src) exp_targets[owner] = 1;
            end
            exp_forwarded = (exp_targets != 0) && owner_valid && dirty && exp_targets[owner];
            exp_mem_write = (op == OP_WRITEBACK) || (op == OP_EVICT && dirty);
            exp_data = exp_forwarded ? owner_data :
                       ((op == OP_READ_SHARED || op == OP_READ_UNIQUE) ? memory_data : 0);
            exp_sharers = sharers;
            exp_owner_valid = owner_valid;
            exp_owner = owner;
            exp_dirty = dirty;
            case (op)
                OP_READ_SHARED: begin
                    exp_sharers[src] = 1;
                    exp_owner_valid = 0;
                    exp_dirty = 0;
                end
                OP_READ_UNIQUE: begin
                    exp_sharers = 0;
                    exp_sharers[src] = 1;
                    exp_owner_valid = 1;
                    exp_owner = src;
                    exp_dirty = 1;
                end
                OP_WRITEBACK, OP_EVICT: begin
                    exp_sharers[src] = 0;
                    if (owner_valid && owner == src) begin
                        exp_owner_valid = 0;
                        exp_dirty = 0;
                    end
                end
            endcase

            @(negedge clk);
            req_valid_i = 1;
            req_opcode_i = op; req_src_i = src; req_addr_i = addr;
            req_data_i = write_data; req_sharers_i = sharers;
            req_owner_valid_i = owner_valid; req_owner_i = owner; req_dirty_i = dirty;
            while (!req_ready_o) @(negedge clk);
            @(negedge clk);
            req_valid_i = 0;

            guard = 0;
            snoops_answered = 0;
            memory_answered = 0;
            while (!rsp_valid_o && guard < 40) begin
                snoop_rsp_valid_i = 0;
                snoop_rsp_dirty_i = 0;
                mem_rsp_valid_i = 0;
                if (snoop_valid_o != 0) begin
                    checks = checks + 1;
                    if (snoop_valid_o !== exp_targets) fail("snoop target mismatch");
                    if (snoop_invalidate_o !== (op == OP_READ_UNIQUE)) fail("snoop invalidate mismatch");
                    if (snoop_addr_o !== addr) fail("snoop address mismatch");
                end
                if (!snoops_answered && state_o == 3'd2 && exp_targets != 0) begin
                    snoop_rsp_valid_i = exp_targets;
                    if (owner_valid && dirty && exp_targets[owner]) begin
                        snoop_rsp_dirty_i[owner] = 1;
                        snoop_rsp_data_i[owner*DATA_W +: DATA_W] = owner_data;
                    end
                    snoops_answered = 1;
                end
                if (mem_req_valid_o) begin
                    checks = checks + 1;
                    if (mem_req_write_o !== exp_mem_write) fail("memory command type mismatch");
                    if (mem_req_addr_o !== addr) fail("memory address mismatch");
                    if (exp_mem_write && mem_req_data_o !== write_data) fail("writeback data mismatch");
                    memory_answered = 1;
                end
                if (memory_answered && state_o == 3'd4) begin
                    mem_rsp_valid_i = 1;
                    mem_rsp_data_i = memory_data;
                    memory_answered = 0;
                end
                @(negedge clk);
                guard = guard + 1;
            end
            snoop_rsp_valid_i = 0;
            snoop_rsp_dirty_i = 0;
            mem_rsp_valid_i = 0;
            checks = checks + 1;
            if (guard >= 40) fail("transaction timeout");
            if (rsp_dst_o !== src) fail("response destination mismatch");
            if (rsp_data_o !== exp_data) fail("response data mismatch");
            if (rsp_dirty_forwarded_o !== exp_forwarded) fail("dirty-forward flag mismatch");
            if (!dir_update_valid_o) fail("missing directory update");
            if (dir_sharers_o !== exp_sharers) fail("updated sharer vector mismatch");
            if (dir_owner_valid_o !== exp_owner_valid) fail("updated owner-valid mismatch");
            if (exp_owner_valid && dir_owner_o !== exp_owner) fail("updated owner mismatch");
            if (dir_dirty_o !== exp_dirty) fail("updated dirty bit mismatch");
            @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("coherent_home_node.vcd");
        $dumpvars(0, tb_coherent_home_node);
        if ($value$plusargs("seed=%d", seed)) $display("Using seed %0d", seed);
        req_valid_i = 0; req_opcode_i = 0; req_src_i = 0; req_addr_i = 0;
        req_data_i = 0; req_sharers_i = 0; req_owner_valid_i = 0;
        req_owner_i = 0; req_dirty_i = 0;
        snoop_ready_i = {NUM_CLIENTS{1'b1}};
        snoop_rsp_valid_i = 0; snoop_rsp_dirty_i = 0; snoop_rsp_data_i = 0;
        mem_req_ready_i = 1; mem_rsp_valid_i = 0; mem_rsp_data_i = 0;
        rsp_ready_i = 1;
        repeat (3) @(negedge clk);
        rst_n = 1;

        run_transaction(OP_READ_SHARED, 1, 16'h1000, 0, 4'b0000, 0, 0, 0, 32'hA000_1000);
        run_transaction(OP_READ_SHARED, 2, 16'h1000, 0, 4'b0011, 1, 0, 1, 32'hA000_1000);
        run_transaction(OP_READ_UNIQUE, 3, 16'h1000, 0, 4'b0111, 1, 1, 1, 32'hA000_1000);
        run_transaction(OP_WRITEBACK, 3, 16'h1000, 32'hCAFE_BABE, 4'b1000, 1, 3, 1, 0);
        run_transaction(OP_EVICT, 2, 16'h2000, 0, 4'b0100, 0, 0, 0, 0);

        for (n = 0; n < 40; n = n + 1) begin
            reg [1:0] rop;
            reg [CLIENT_W-1:0] rsrc, rowner;
            reg [NUM_CLIENTS-1:0] rsharers;
            reg rowner_valid, rdirty;
            rop = $random(seed);
            rsrc = $random(seed);
            rowner = $random(seed);
            rsharers = $random(seed);
            rowner_valid = $random(seed);
            rdirty = rowner_valid && $random(seed);
            if (rowner_valid) rsharers[rowner] = 1;
            run_transaction(rop, rsrc, 16'h3000+n, 32'hB000_0000+n,
                            rsharers, rowner_valid, rowner, rdirty,
                            32'hA000_0000+n);
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d checks, directed + randomized)", checks);
        else begin
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #20000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $fatal(1);
    end
endmodule
