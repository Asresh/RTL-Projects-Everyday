// ============================================================================
//  tb_simt_stack.sv  --  self-checking testbench for the SIMT reconvergence
//                        (IPDOM) stack.
// ----------------------------------------------------------------------------
//  An INDEPENDENT golden reference stack (kept in plain TB arrays, coded in a
//  different style from the RTL) is stepped in lock-step with the DUT.  After
//  every command the DUT's top-of-stack view (pc / rpc / mask / active_lanes /
//  reconverge / sp / ovf / unf) is compared bit-for-bit against the reference.
//
//  Coverage:
//    * uniform-taken and uniform-not-taken branches (no push)
//    * genuine divergence (push not-taken + taken, taken on top)
//    * full reconvergence back to the original whole-warp mask
//    * nested divergence (divergence inside a divergent path)
//    * lane conservation (t | n == parent, t & n == 0) via the reference
//    * stack OVERFLOW guard  (deep split chain beyond DEPTH)
//    * stack UNDERFLOW guard (pop past empty)
//    * 4000 cycles of constrained-random legal commands
//
//  Prints "RESULT: *** PASS ***" iff every check matched.  Dumps a VCD.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_simt_stack;

    localparam int NLANES = 8;
    localparam int PCW    = 16;
    localparam int DEPTH  = 6;                 // small -> overflow guard reachable
    localparam int SPW    = $clog2(DEPTH+1);
    localparam int AW     = $clog2(NLANES+1);
    localparam logic [PCW-1:0] RPC_TOP = {PCW{1'b1}};

    localparam logic [1:0] CMD_NOP=2'd0, CMD_DIVERGE=2'd1, CMD_SETPC=2'd2, CMD_POP=2'd3;

    // ---- DUT ports ---------------------------------------------------------
    logic                 clk, rst_n;
    logic                 init_valid;
    logic [NLANES-1:0]    init_mask;
    logic [PCW-1:0]       init_pc;
    logic                 cmd_valid;
    logic [1:0]           cmd;
    logic [NLANES-1:0]    taken_mask;
    logic [PCW-1:0]       pc_taken, pc_notaken, rpc, next_pc;

    wire                  tos_valid;
    wire [PCW-1:0]        tos_pc, tos_rpc;
    wire [NLANES-1:0]     tos_mask;
    wire [AW-1:0]         active_lanes;
    wire                  reconverge;
    wire [SPW-1:0]        sp;
    wire                  ovf, unf;

    simt_stack #(.NLANES(NLANES), .PCW(PCW), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst_n(rst_n),
        .init_valid(init_valid), .init_mask(init_mask), .init_pc(init_pc),
        .cmd_valid(cmd_valid), .cmd(cmd),
        .taken_mask(taken_mask), .pc_taken(pc_taken), .pc_notaken(pc_notaken),
        .rpc(rpc), .next_pc(next_pc),
        .tos_valid(tos_valid), .tos_pc(tos_pc), .tos_rpc(tos_rpc),
        .tos_mask(tos_mask), .active_lanes(active_lanes),
        .reconverge(reconverge), .sp(sp), .ovf(ovf), .unf(unf)
    );

    // ---- clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- golden reference stack -------------------------------------------
    logic [PCW-1:0]    r_pc   [DEPTH];
    logic [PCW-1:0]    r_rpc  [DEPTH];
    logic [NLANES-1:0] r_mask [DEPTH];
    integer            r_sp;
    logic              r_ovf, r_unf;

    integer errors = 0;
    integer checks = 0;

    function automatic [AW-1:0] popcount(input logic [NLANES-1:0] m);
        integer k; logic [AW-1:0] c;
        begin
            c = '0;
            for (k = 0; k < NLANES; k = k + 1) c = c + m[k];
            popcount = c;
        end
    endfunction

    // step the reference exactly like the RTL, using the current input regs
    task automatic ref_step();
        logic [NLANES-1:0] tmc, t, n;
        begin
            tmc = (r_sp != 0) ? r_mask[r_sp-1] : '0;
            t   = taken_mask  & tmc;
            n   = ~taken_mask & tmc;
            if (init_valid) begin
                if (r_sp < DEPTH) begin
                    r_pc[r_sp]   = init_pc;
                    r_rpc[r_sp]  = RPC_TOP;
                    r_mask[r_sp] = init_mask;
                    r_sp         = r_sp + 1;
                end else r_ovf = 1'b1;
            end else if (cmd_valid) begin
                case (cmd)
                    CMD_DIVERGE: begin
                        if (r_sp == 0)            r_unf = 1'b1;
                        else if (t == tmc)        r_pc[r_sp-1] = pc_taken;
                        else if (t == '0)         r_pc[r_sp-1] = pc_notaken;
                        else if (r_sp + 2 > DEPTH) r_ovf = 1'b1;
                        else begin
                            r_pc[r_sp-1]   = rpc;
                            r_pc[r_sp]     = pc_notaken; r_rpc[r_sp]   = rpc; r_mask[r_sp]   = n;
                            r_pc[r_sp+1]   = pc_taken;   r_rpc[r_sp+1] = rpc; r_mask[r_sp+1] = t;
                            r_sp           = r_sp + 2;
                        end
                    end
                    CMD_SETPC: if (r_sp == 0) r_unf = 1'b1; else r_pc[r_sp-1] = next_pc;
                    CMD_POP:   if (r_sp == 0) r_unf = 1'b1; else r_sp = r_sp - 1;
                    default: ;
                endcase
            end
        end
    endtask

    task automatic cmp_i(input string nm, input integer got, input integer exp);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  [MISMATCH] %-12s got=%0d exp=%0d  (t=%0t)", nm, got, exp, $time);
            end
        end
    endtask

    // compare every DUT output against the reference-derived expectation
    task automatic check();
        logic              e_valid, e_recon;
        logic [PCW-1:0]    e_pc, e_rpc;
        logic [NLANES-1:0] e_mask;
        begin
            e_valid = (r_sp != 0);
            e_pc    = (r_sp != 0) ? r_pc[r_sp-1]   : '0;
            e_rpc   = (r_sp != 0) ? r_rpc[r_sp-1]  : '0;
            e_mask  = (r_sp != 0) ? r_mask[r_sp-1] : '0;
            e_recon = e_valid && (e_pc == e_rpc);
            cmp_i("sp",          sp,           r_sp);
            cmp_i("tos_valid",   tos_valid,    e_valid);
            cmp_i("tos_pc",      tos_pc,       e_pc);
            cmp_i("tos_rpc",     tos_rpc,      e_rpc);
            cmp_i("tos_mask",    tos_mask,     e_mask);
            cmp_i("active",      active_lanes, popcount(e_mask));
            cmp_i("reconverge",  reconverge,   e_recon);
            cmp_i("ovf",         ovf,          r_ovf);
            cmp_i("unf",         unf,          r_unf);
        end
    endtask

    // drive one command then step reference + check (inputs already set)
    task automatic step();
        begin
            @(posedge clk);
            #1;
            ref_step();
            check();
            cmd_valid  = 1'b0;
            init_valid = 1'b0;
        end
    endtask

    task automatic do_init(input logic [NLANES-1:0] m, input logic [PCW-1:0] p);
        begin init_valid=1; init_mask=m; init_pc=p; step(); end
    endtask
    task automatic do_diverge(input logic [NLANES-1:0] tk,
                              input logic [PCW-1:0] pt, input logic [PCW-1:0] pnt,
                              input logic [PCW-1:0] rp);
        begin cmd_valid=1; cmd=CMD_DIVERGE; taken_mask=tk; pc_taken=pt; pc_notaken=pnt; rpc=rp; step(); end
    endtask
    task automatic do_setpc(input logic [PCW-1:0] p);
        begin cmd_valid=1; cmd=CMD_SETPC; next_pc=p; step(); end
    endtask
    task automatic do_pop();
        begin cmd_valid=1; cmd=CMD_POP; step(); end
    endtask
    task automatic do_nop();
        begin cmd_valid=0; step(); end
    endtask

    // ---- watchdog ----------------------------------------------------------
    initial begin
        #200000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1);
    end

    // ---- randomization helpers --------------------------------------------
    integer seed = 32'hC0FFEE18;

    // ---- main stimulus -----------------------------------------------------
    integer it;
    logic [NLANES-1:0] rtk;
    logic [1:0]        rc;
    logic [NLANES-1:0] tos_mask_now;

    initial begin
        $dumpfile("simt_stack.vcd");
        $dumpvars(0, tb_simt_stack);

        // defaults
        init_valid=0; init_mask='0; init_pc='0;
        cmd_valid=0; cmd=CMD_NOP; taken_mask='0;
        pc_taken='0; pc_notaken='0; rpc='0; next_pc='0;
        r_sp=0; r_ovf=0; r_unf=0;

        // reset
        rst_n=0;
        repeat (3) @(posedge clk);
        #1 rst_n=1;
        @(posedge clk);
        #1;                       // settle past the edge before driving inputs

        // ---- push the whole-warp base entry -------------------------------
        do_init(8'hFF, 16'h0000);

        // ================= DIRECTED TESTS ==================================
        $display("[directed] uniform branches");
        // A: uniform taken  -> TOS.pc = pc_taken, no push
        do_diverge(8'hFF, 16'h0010, 16'h0020, 16'h0030);
        // B: uniform not-taken -> TOS.pc = pc_notaken, no push
        do_diverge(8'h00, 16'h0040, 16'h0050, 16'h0060);
        do_setpc(16'h0000);                       // park base pc

        $display("[directed] single genuine divergence + reconvergence");
        // C: lanes[3:0] take, lanes[7:4] fall through; IPDOM = 0x0300
        do_diverge(8'h0F, 16'h0100, 16'h0200, 16'h0300);   // sp: 1 -> 3
        // run the taken group to its reconvergence PC
        do_setpc(16'h0300);                        // tos_pc == rpc -> reconverge
        do_pop();                                  // retire taken group
        // now the not-taken group runs
        do_setpc(16'h0300);
        do_pop();                                  // retire not-taken group
        // base reconv entry resumes: full 0xFF mask restored
        do_nop();

        $display("[directed] nested divergence");
        // outer split of the whole warp
        do_diverge(8'h33, 16'h0400, 16'h0500, 16'h0600);   // sp -> 3, TOS mask=0x33
        // inner split *inside* the taken group (mask 0x33 -> {0x01},{0x32})
        do_diverge(8'h01, 16'h0410, 16'h0420, 16'h0430);   // sp -> 5
        do_setpc(16'h0430); do_pop();              // retire inner taken (lane0)
        do_setpc(16'h0430); do_pop();              // retire inner not-taken
        do_setpc(16'h0600); do_pop();              // retire outer taken group
        do_setpc(16'h0600); do_pop();              // retire outer not-taken group
        do_nop();                                  // whole warp reconverged

        // ================= CONSTRAINED-RANDOM ==============================
        $display("[random] 4000 constrained-legal commands");
        for (it = 0; it < 4000; it = it + 1) begin
            tos_mask_now = tos_mask;               // current DUT view (== ref)
            rc = $random(seed);
            case (rc)
                CMD_DIVERGE: begin
                    // only when there's room and a multi-lane group to split
                    if ((sp + 2 <= DEPTH) && (popcount(tos_mask_now) >= 2)) begin
                        rtk = $random(seed);
                        rtk = rtk & tos_mask_now;  // legal subset (keeps it live)
                        if (rtk == '0) rtk = {{(NLANES-1){1'b0}}, 1'b1} & tos_mask_now;
                        do_diverge(rtk, $random(seed), $random(seed), $random(seed));
                    end else do_setpc($random(seed));
                end
                CMD_SETPC: begin
                    // sometimes drive pc straight to rpc to exercise reconverge
                    if ((it & 3) == 0 && tos_valid) do_setpc(tos_rpc);
                    else                            do_setpc($random(seed));
                end
                CMD_POP: begin
                    if (sp > 1) do_pop();          // never pop the base away here
                    else        do_nop();
                end
                default: do_nop();
            endcase
        end

        // ================= OVERFLOW GUARD ==================================
        $display("[directed] overflow guard (deep split beyond DEPTH=%0d)", DEPTH);
        // unwind back toward the base first
        while (sp > 1) do_pop();
        // base whole warp, sp=1. Split 8->{4,4}->{2,2}->(blocked)
        do_diverge(8'h0F, 16'h1000, 16'h2000, 16'h3000);   // sp 1 -> 3
        do_diverge(8'h03, 16'h1100, 16'h2100, 16'h3100);   // sp 3 -> 5
        do_diverge(8'h01, 16'h1200, 16'h2200, 16'h3200);   // sp+2=7 > 6 -> OVERFLOW
        if (ovf !== 1'b1) begin
            errors = errors + 1;
            $display("  [MISMATCH] expected ovf=1 after deep split, got %0b", ovf);
        end else $display("  overflow correctly asserted, stack frozen at sp=%0d", sp);

        // ================= UNDERFLOW GUARD =================================
        $display("[directed] underflow guard (pop past empty)");
        while (sp > 0) do_pop();                    // drain to empty
        do_pop();                                   // one pop too many -> UNDERFLOW
        if (unf !== 1'b1) begin
            errors = errors + 1;
            $display("  [MISMATCH] expected unf=1 after pop-past-empty, got %0b", unf);
        end else $display("  underflow correctly asserted");

        // ---- verdict ------------------------------------------------------
        repeat (2) @(posedge clk);
        $display("--------------------------------------------------------------");
        $display("checks run : %0d", checks);
        $display("errors     : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $finish;
    end

endmodule

`default_nettype wire
