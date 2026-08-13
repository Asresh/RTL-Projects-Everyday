// ===========================================================================
// Day 41 : self-checking testbench for the out-of-order Tomasulo engine
// ---------------------------------------------------------------------------
// The DUT is allowed to execute in any order it likes; what it is NOT allowed
// to do is *retire* in any order but program order, with any values but the
// ones a simple in-order machine would have produced.  So the golden model
// here is exactly that: a plain in-order interpreter over an architectural
// register file.  Every instruction handed to the dispatch port is executed
// immediately by the model and its {rd, rd_wen, value} pushed onto an
// expectation queue; every commit the DUT reports is popped off the front of
// that queue and compared.  If the renaming, the wakeup, the CDB bypass or the
// ROB gets anything wrong, the commit stream diverges and the test fails.
//
// On top of the stream compare the testbench also checks:
//   * commit_tag increments by one, mod ROB_DEPTH, on every retire
//   * the architectural register file matches the model at the end of the run
//   * results really do complete OUT of program order (an inversion counter
//     built independently of the DUT's own perf counter) - a machine that
//     silently degraded to in-order would still pass the value checks, so this
//     is what proves it is actually out-of-order
//   * the exact number of commits equals the number of dispatches
//   * flush leaves the architectural state untouched and the engine usable
//
// Stimulus: a register-init prologue, then eight directed scenarios aimed at
// the hazards that renaming exists to solve (RAW chains, WAW/WAR storms,
// long-latency shadows, divide-by-zero, back-to-back multiplies, discarded
// results, full-rate dispatch into a full ROB), then a long randomized soak
// with random dispatch gaps, then a flush test.
//
//   iverilog -g2012 -o sim ooo_tomasulo.sv tb_ooo_tomasulo.sv && vvp sim +seed=1
// ===========================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_ooo_tomasulo;

    // ---- elaboration-time knobs (overridable with iverilog -P) -------------
    parameter int XLEN       = 32;
    parameter int AREGS      = 8;
    parameter int ROB_DEPTH  = 8;
    parameter int RS_DEPTH   = 6;
    parameter int MUL_STAGES = 3;
    parameter int NRAND      = 400;

    localparam int AW = $clog2(AREGS);
    localparam int TW = $clog2(ROB_DEPTH);

    localparam logic [3:0] OP_ADD  = 4'd0;
    localparam logic [3:0] OP_SUB  = 4'd1;
    localparam logic [3:0] OP_AND  = 4'd2;
    localparam logic [3:0] OP_OR   = 4'd3;
    localparam logic [3:0] OP_XOR  = 4'd4;
    localparam logic [3:0] OP_SLL  = 4'd5;
    localparam logic [3:0] OP_SRL  = 4'd6;
    localparam logic [3:0] OP_SLT  = 4'd7;
    localparam logic [3:0] OP_MUL  = 4'd8;
    localparam logic [3:0] OP_MULH = 4'd9;
    localparam logic [3:0] OP_DIV  = 4'd10;
    localparam logic [3:0] OP_REM  = 4'd11;

    // ======================================================================
    // DUT
    // ======================================================================
    logic                 clk = 1'b0;
    logic                 rst_n;
    logic                 flush;

    logic                 disp_valid;
    wire                  disp_ready;
    logic [3:0]           disp_op;
    logic [AW-1:0]        disp_rs1, disp_rs2, disp_rd;
    logic                 disp_rd_wen;
    logic [XLEN-1:0]      disp_imm;
    logic                 disp_use_imm;

    wire                  commit_valid;
    wire  [AW-1:0]        commit_rd;
    wire                  commit_rd_wen;
    wire  [XLEN-1:0]      commit_val;
    wire  [TW-1:0]        commit_tag;

    wire  [31:0]          perf_dispatched, perf_committed, perf_cdb_conflict;
    wire  [31:0]          perf_ooo_complete, perf_stall_rob, perf_stall_rs, perf_flush;
    wire  [ROB_DEPTH-1:0] dbg_rob_busy, dbg_rob_done;
    wire  [RS_DEPTH-1:0]  dbg_rs_busy;

    ooo_tomasulo #(
        .XLEN      (XLEN),
        .AREGS     (AREGS),
        .ROB_DEPTH (ROB_DEPTH),
        .RS_DEPTH  (RS_DEPTH),
        .MUL_STAGES(MUL_STAGES)
    ) dut (
        .clk(clk), .rst_n(rst_n), .flush(flush),
        .disp_valid(disp_valid), .disp_ready(disp_ready), .disp_op(disp_op),
        .disp_rs1(disp_rs1), .disp_rs2(disp_rs2), .disp_rd(disp_rd),
        .disp_rd_wen(disp_rd_wen), .disp_imm(disp_imm), .disp_use_imm(disp_use_imm),
        .commit_valid(commit_valid), .commit_rd(commit_rd),
        .commit_rd_wen(commit_rd_wen), .commit_val(commit_val),
        .commit_tag(commit_tag),
        .perf_dispatched(perf_dispatched), .perf_committed(perf_committed),
        .perf_cdb_conflict(perf_cdb_conflict), .perf_ooo_complete(perf_ooo_complete),
        .perf_stall_rob(perf_stall_rob), .perf_stall_rs(perf_stall_rs),
        .perf_flush(perf_flush),
        .dbg_rob_busy(dbg_rob_busy), .dbg_rob_done(dbg_rob_done),
        .dbg_rs_busy(dbg_rs_busy)
    );

    always #5 clk = ~clk;

    // ======================================================================
    // Golden model : a plain in-order interpreter
    // ======================================================================
    logic [XLEN-1:0] gold_rf [AREGS];

    function automatic logic [XLEN-1:0] ref_exec(input logic [3:0]    op,
                                                 input logic [XLEN-1:0] a,
                                                 input logic [XLEN-1:0] b);
        logic [2*XLEN-1:0] p;
        begin
            p = {{XLEN{1'b0}}, a} * {{XLEN{1'b0}}, b};
            case (op)
                OP_ADD : ref_exec = a + b;
                OP_SUB : ref_exec = a - b;
                OP_AND : ref_exec = a & b;
                OP_OR  : ref_exec = a | b;
                OP_XOR : ref_exec = a ^ b;
                OP_SLL : ref_exec = a << b[$clog2(XLEN)-1:0];
                OP_SRL : ref_exec = a >> b[$clog2(XLEN)-1:0];
                OP_SLT : ref_exec = {{(XLEN-1){1'b0}}, ($signed(a) < $signed(b))};
                OP_MUL : ref_exec = p[XLEN-1:0];
                OP_MULH: ref_exec = p[2*XLEN-1:XLEN];
                OP_DIV : ref_exec = (b == {XLEN{1'b0}}) ? {XLEN{1'b1}} : (a / b);
                OP_REM : ref_exec = (b == {XLEN{1'b0}}) ? a            : (a % b);
                default: ref_exec = {XLEN{1'b0}};
            endcase
        end
    endfunction

    // expectation queue, in program order
    int            exp_idx_q [$];
    int            exp_rd_q  [$];
    int            exp_wen_q [$];
    bit [XLEN-1:0] exp_val_q [$];
    bit [3:0]      exp_op_q  [$];

    int errors   = 0;
    int n_gen    = 0;   // instructions handed to the DUT (and to the model)
    int n_commit = 0;   // commits observed
    int checks   = 0;

    logic [TW-1:0] exp_tag = {TW{1'b0}};

    string ONAME [12];
    initial begin
        ONAME[0]="ADD"; ONAME[1]="SUB"; ONAME[2]="AND";  ONAME[3]="OR";
        ONAME[4]="XOR"; ONAME[5]="SLL"; ONAME[6]="SRL";  ONAME[7]="SLT";
        ONAME[8]="MUL"; ONAME[9]="MULH";ONAME[10]="DIV"; ONAME[11]="REM";
    end

    task automatic err(input string msg);
        begin
            errors = errors + 1;
            $display("  [ERROR] t=%0t %s", $time, msg);
            if (errors > 20) begin
                $display("RESULT: *** FAIL *** (too many errors)");
                $finish;
            end
        end
    endtask

    // ======================================================================
    // Commit monitor.  All DUT commit outputs are registered, so sampling
    // them on the negedge is race-free.
    // ======================================================================
    task automatic check_commit;
        int            e_idx, e_rd, e_wen;
        bit [XLEN-1:0] e_val;
        bit [3:0]      e_op;
        begin
            if (exp_rd_q.size() == 0) begin
                err($sformatf("commit with an empty expectation queue (rd=%0d val=%08h)",
                              commit_rd, commit_val));
                return;
            end
            e_idx = exp_idx_q.pop_front();
            e_rd  = exp_rd_q.pop_front();
            e_wen = exp_wen_q.pop_front();
            e_val = exp_val_q.pop_front();
            e_op  = exp_op_q.pop_front();

            if (commit_tag !== exp_tag)
                err($sformatf("instr %0d (%s): commit_tag=%0d expected %0d (retire order broken)",
                              e_idx, ONAME[e_op], commit_tag, exp_tag));
            if (commit_rd !== e_rd[AW-1:0])
                err($sformatf("instr %0d (%s): commit_rd=%0d expected %0d",
                              e_idx, ONAME[e_op], commit_rd, e_rd));
            if (commit_rd_wen !== e_wen[0])
                err($sformatf("instr %0d (%s): commit_rd_wen=%0b expected %0b",
                              e_idx, ONAME[e_op], commit_rd_wen, e_wen[0]));
            if (e_wen[0] && (commit_val !== e_val))
                err($sformatf("instr %0d (%s -> r%0d): commit_val=%08h expected %08h",
                              e_idx, ONAME[e_op], e_rd, commit_val, e_val));

            exp_tag  = exp_tag + 1'b1;
            n_commit = n_commit + 1;
            checks   = checks + 1;
        end
    endtask

    always @(negedge clk)
        if (rst_n && commit_valid) check_commit();

    // ======================================================================
    // Independent out-of-order evidence.
    //
    // ROB tags are handed out strictly in order, so the program index of a
    // completing tag is the unique outstanding index d in [committed,
    // dispatched) with d % ROB_DEPTH == tag.  If the sequence of those indices
    // is ever non-increasing, a younger instruction finished before an older
    // one - which is the whole point of the machine.
    // ======================================================================
    int  ooo_inversions = 0;
    int  completions    = 0;
    int  last_comp_idx  = -1;
    bit  track_ooo      = 1'b1;

    always @(negedge clk) begin
        int d, idx, lo, hi;
        if (rst_n && track_ooo && dut.cdb_valid) begin
            lo  = perf_committed;
            hi  = perf_dispatched;
            idx = -1;
            for (d = lo; d < hi; d = d + 1)
                if ((d % ROB_DEPTH) == int'(dut.cdb_tag)) idx = d;
            if (idx < 0)
                err($sformatf("CDB completed tag %0d maps to no in-flight instruction",
                              dut.cdb_tag));
            else begin
                if (idx < last_comp_idx) ooo_inversions = ooo_inversions + 1;
                last_comp_idx = idx;
                completions   = completions + 1;
            end
        end
    end

    // ======================================================================
    // Dispatch driver.  Everything is driven from the negedge, and disp_ready
    // is a function of registered state only, so its negedge value is exactly
    // its value at the upcoming posedge.
    // ======================================================================
    task automatic push(input logic [3:0] op, input int rs1, input int rs2,
                        input int rd, input bit wen,
                        input logic [XLEN-1:0] imm, input bit use_imm);
        logic [XLEN-1:0] a, b, r;
        begin
            // --- golden model, executed in program order --------------------
            a = gold_rf[rs1];
            b = use_imm ? imm : gold_rf[rs2];
            r = ref_exec(op, a, b);
            exp_idx_q.push_back(n_gen);
            exp_rd_q.push_back(rd);
            exp_wen_q.push_back(wen ? 1 : 0);
            exp_val_q.push_back(r);
            exp_op_q.push_back(op);
            if (wen) gold_rf[rd] = r;
            n_gen = n_gen + 1;

            // --- drive ------------------------------------------------------
            disp_op      = op;
            disp_rs1     = rs1[AW-1:0];
            disp_rs2     = rs2[AW-1:0];
            disp_rd      = rd[AW-1:0];
            disp_rd_wen  = wen;
            disp_imm     = imm;
            disp_use_imm = use_imm;
            disp_valid   = 1'b1;
            while (!disp_ready) @(negedge clk);
            @(negedge clk);          // the posedge in between took the transfer
        end
    endtask

    // dispatch without telling the golden model (used only by the flush test)
    task automatic push_ghost(input logic [3:0] op, input int rs1, input int rs2,
                              input int rd, input logic [XLEN-1:0] imm,
                              input bit use_imm);
        begin
            disp_op      = op;
            disp_rs1     = rs1[AW-1:0];
            disp_rs2     = rs2[AW-1:0];
            disp_rd      = rd[AW-1:0];
            disp_rd_wen  = 1'b1;
            disp_imm     = imm;
            disp_use_imm = use_imm;
            disp_valid   = 1'b1;
            while (!disp_ready) @(negedge clk);
            @(negedge clk);
        end
    endtask

    task automatic idle(input int n);
        begin
            disp_valid = 1'b0;
            repeat (n) @(negedge clk);
        end
    endtask

    // wait until every dispatched instruction has retired
    task automatic drain;
        int guard;
        begin
            disp_valid = 1'b0;
            guard      = 0;
            while ((n_commit < n_gen) && (guard < 20000)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (n_commit < n_gen)
                err($sformatf("drain timed out: %0d of %0d instructions retired",
                              n_commit, n_gen));
        end
    endtask

    // ======================================================================
    // Directed scenarios
    // ======================================================================
    int r_i, r_j, r_k;

    // arf resets to zero, so `ADD rd, rd, imm` seeds each register with imm
    task automatic prologue;
        begin
            $display("  [T1] register-init prologue");
            for (r_i = 0; r_i < AREGS; r_i++)
                push(OP_ADD, r_i, 0, r_i, 1'b1, 32'h1000_0001 * (r_i + 1), 1'b1);
        end
    endtask

    // Every instruction reads the register the previous one wrote: the machine
    // has no choice but to serialize, and every operand must arrive by CDB
    // wakeup or by the same-cycle CDB bypass at dispatch.
    task automatic t_raw_chain;
        begin
            $display("  [T2] RAW dependency chain (fully serialized)");
            for (r_i = 0; r_i < 20; r_i++)
                push((r_i % 5 == 4) ? OP_MUL : OP_ADD, 1, (r_i % AREGS), 1,
                     1'b1, 32'd0, 1'b0);
            drain();
        end
    endtask

    // Repeatedly redefine the same architectural register while other
    // instructions read the *old* definitions.  Only correct renaming keeps
    // the readers from seeing the wrong version.
    task automatic t_waw_war;
        begin
            $display("  [T3] WAW / WAR storm on a single architectural register");
            for (r_i = 0; r_i < 24; r_i++) begin
                push(OP_ADD, 3, 4, 3, 1'b1, 32'd0, 1'b0);          // WAW on r3
                push(OP_XOR, 3, 5, 6, 1'b1, 32'd0, 1'b0);          // reads new r3
                push(OP_SUB, 2, 3, 7, 1'b1, 32'd0, 1'b0);          // WAR against r3
            end
            drain();
        end
    endtask

    // A 33-cycle divide at the head of the ROB with a stream of 1-cycle work
    // behind it: the ALU results all finish long before the divide, sit in the
    // ROB as completed-but-not-retired, and must still retire behind it.
    task automatic t_long_shadow;
        begin
            $display("  [T4] long-latency shadow (DIV blocks the ROB head)");
            for (r_i = 0; r_i < 6; r_i++) begin
                push(OP_DIV, 1, 2, 1, 1'b1, 32'd0, 1'b0);
                for (r_j = 0; r_j < 12; r_j++)
                    push(OP_ADD, 4, 5, 4, 1'b1, 32'd0, 1'b0);
            end
            drain();
        end
    endtask

    task automatic t_div_zero;
        begin
            $display("  [T5] divide / remainder by zero");
            push(OP_SUB, 2, 2, 2, 1'b1, 32'd0, 1'b0);              // r2 = 0
            push(OP_DIV, 1, 2, 3, 1'b1, 32'd0, 1'b0);              // x / 0
            push(OP_REM, 1, 2, 4, 1'b1, 32'd0, 1'b0);              // x % 0
            push(OP_DIV, 2, 2, 5, 1'b1, 32'd0, 1'b0);              // 0 / 0
            push(OP_ADD, 2, 0, 2, 1'b1, 32'h89AB_CDEF, 1'b1);      // restore r2
            push(OP_DIV, 1, 2, 6, 1'b1, 32'd0, 1'b0);
            push(OP_REM, 1, 2, 7, 1'b1, 32'd0, 1'b0);
            drain();
        end
    endtask

    // The multiplier pipeline is the only unit that can produce a result every
    // cycle, so this is what makes it fight the other units for the CDB.
    task automatic t_mul_burst;
        begin
            $display("  [T6] back-to-back independent multiplies + CDB contention");
            push(OP_DIV, 1, 3, 0, 1'b1, 32'd0, 1'b0);   // a divide running underneath
            for (r_i = 0; r_i < 30; r_i++)
                push((r_i % 3 == 0) ? OP_MULH : OP_MUL,
                     (r_i % 4) + 1, (r_i % 3) + 4, (r_i % 3) + 5, 1'b1, 32'd0, 1'b0);
            drain();
        end
    endtask

    task automatic t_no_wb;
        begin
            $display("  [T7] instructions whose result is discarded (rd_wen=0)");
            for (r_i = 0; r_i < 16; r_i++) begin
                push(OP_MUL, 1, 2, 3, 1'b0, 32'd0, 1'b0);   // occupies ROB, no write
                push(OP_ADD, 3, 4, 3, 1'b1, 32'd0, 1'b0);   // must see the OLD r3
            end
            drain();
        end
    endtask

    // No dispatch gaps at all: the ROB fills, disp_ready drops, and the
    // dispatch/commit-in-the-same-cycle path gets exercised hard.
    task automatic t_full_rate;
        begin
            $display("  [T8] full-rate dispatch into a full ROB (backpressure)");
            for (r_i = 0; r_i < 120; r_i++)
                push(4'((r_i * 7) % 12), (r_i % AREGS), ((r_i + 3) % AREGS),
                     ((r_i + 5) % AREGS), 1'b1, 32'd0, 1'b0);
            drain();
        end
    endtask

    task automatic t_random(input int n);
        logic [3:0] op;
        int         rs1, rs2, rd, gap;
        bit         wen, uimm;
        begin
            $display("  [T9] randomized soak : %0d instructions", n);
            for (r_i = 0; r_i < n; r_i++) begin
                // weight the ALU heavily so the slow units are the minority,
                // which is what makes out-of-order completion happen
                case ($urandom_range(0, 9))
                    0, 1, 2, 3, 4, 5: op = 4'($urandom_range(0, 7));
                    6, 7, 8         : op = 4'($urandom_range(8, 9));
                    default         : op = 4'($urandom_range(10, 11));
                endcase
                rs1  = $urandom_range(0, AREGS - 1);
                rs2  = $urandom_range(0, AREGS - 1);
                rd   = $urandom_range(0, AREGS - 1);
                wen  = ($urandom_range(0, 9) != 0);
                uimm = ($urandom_range(0, 3) == 0);
                push(op, rs1, rs2, rd, wen,
                     uimm ? $urandom : 32'd0, uimm);
                gap = ($urandom_range(0, 4) == 0) ? $urandom_range(1, 6) : 0;
                if (gap != 0) idle(gap);
            end
            drain();
        end
    endtask

    // ======================================================================
    // Flush : squash the in-flight window, keep the architectural state.
    // Runs last, with the out-of-order tracker disabled, because it
    // deliberately breaks the tag<->program-index mapping.
    // ======================================================================
    task automatic t_flush;
        logic [XLEN-1:0] snap [AREGS];
        int              c_before, i;
        begin
            $display("  [T10] flush : squash the speculative window");
            drain();
            for (i = 0; i < AREGS; i++) snap[i] = dut.arf[i];
            c_before   = n_commit;
            track_ooo  = 1'b0;

            // Two long-latency ops so nothing can possibly retire before the
            // flush lands (minimum dispatch-to-commit latency is 3 cycles).
            push_ghost(OP_DIV, 1, 2, 3, 32'd0, 1'b0);
            push_ghost(OP_MUL, 4, 5, 6, 32'd0, 1'b0);

            disp_valid = 1'b0;
            flush      = 1'b1;
            @(negedge clk);
            flush      = 1'b0;
            exp_tag    = {TW{1'b0}};

            repeat (60) @(negedge clk);

            if (n_commit != c_before)
                err("flush did not squash the in-flight instructions");
            for (i = 0; i < AREGS; i++)
                if (dut.arf[i] !== snap[i])
                    err($sformatf("flush corrupted architectural r%0d: %08h != %08h",
                                  i, dut.arf[i], snap[i]));
            for (i = 0; i < AREGS; i++)
                if (dut.rat_busy[i] !== 1'b0)
                    err($sformatf("flush left r%0d renamed", i));
            for (i = 0; i < ROB_DEPTH; i++)
                if (dut.rob_busy[i] !== 1'b0) err("flush left a ROB entry busy");
            for (i = 0; i < RS_DEPTH; i++)
                if (dut.rs_busy[i] !== 1'b0) err("flush left a station busy");
            if (dut.rob_count !== 0) err("flush left a non-zero ROB occupancy");
            if (!disp_ready)          err("flush left the dispatch port blocked");

            // and the engine still works afterwards
            $display("  [T10] post-flush restart");
            for (r_i = 0; r_i < 24; r_i++)
                push(4'((r_i * 5) % 12), (r_i % AREGS), ((r_i + 2) % AREGS),
                     ((r_i + 1) % AREGS), 1'b1, 32'd0, 1'b0);
            drain();
        end
    endtask

    // ======================================================================
    // Main
    // ======================================================================
    integer seed, seed_arg, dummy;
    int     mism;

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        seed_arg = seed;
        dummy    = $urandom(seed_arg);

        $dumpfile("ooo_tomasulo.vcd");
        $dumpvars(0, tb_ooo_tomasulo);

        $display("=========================================================");
        $display(" Day 41 : out-of-order Tomasulo engine");
        $display("   XLEN=%0d AREGS=%0d ROB_DEPTH=%0d RS_DEPTH=%0d MUL_STAGES=%0d seed=%0d",
                 XLEN, AREGS, ROB_DEPTH, RS_DEPTH, MUL_STAGES, seed);
        $display("=========================================================");

        disp_valid   = 1'b0;
        disp_op      = 4'd0;
        disp_rs1     = '0;
        disp_rs2     = '0;
        disp_rd      = '0;
        disp_rd_wen  = 1'b0;
        disp_imm     = '0;
        disp_use_imm = 1'b0;
        flush        = 1'b0;
        rst_n        = 1'b0;
        for (r_i = 0; r_i < AREGS; r_i++) gold_rf[r_i] = '0;

        repeat (4) @(negedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        prologue();
        drain();
        t_raw_chain();
        t_waw_war();
        t_long_shadow();
        t_div_zero();
        t_mul_burst();
        t_no_wb();
        t_full_rate();
        t_random(NRAND);
        t_flush();

        // ---------------------------------------------------- final audit
        $display("---------------------------------------------------------");
        $display(" dispatched      : %0d (DUT counter %0d)", n_gen, perf_dispatched);
        $display(" committed       : %0d (DUT counter %0d)", n_commit, perf_committed);
        $display(" commits checked : %0d", checks);
        $display(" completions     : %0d, out-of-order inversions : %0d (TB), %0d (DUT)",
                 completions, ooo_inversions, perf_ooo_complete);
        $display(" CDB conflicts   : %0d", perf_cdb_conflict);
        $display(" dispatch stalls : %0d ROB-full, %0d RS-full",
                 perf_stall_rob, perf_stall_rs);
        $display(" flushes         : %0d", perf_flush);

        if (n_commit != n_gen)
            err($sformatf("%0d instructions dispatched but %0d retired",
                          n_gen, n_commit));
        if (exp_rd_q.size() != 0)
            err($sformatf("%0d expected commits never happened", exp_rd_q.size()));

        mism = 0;
        for (r_i = 0; r_i < AREGS; r_i++)
            if (dut.arf[r_i] !== gold_rf[r_i]) begin
                mism = mism + 1;
                err($sformatf("final r%0d = %08h, model says %08h",
                              r_i, dut.arf[r_i], gold_rf[r_i]));
            end
        if (mism == 0)
            $display(" final architectural register file matches the model");

        // A machine that quietly executed everything in order would pass every
        // value check above, so require real evidence of reordering.
        if (ooo_inversions == 0)
            err("no out-of-order completions observed - nothing was reordered");
        if (int'(perf_ooo_complete) == 0)
            err("DUT perf_ooo_complete stayed at zero");

        $display("---------------------------------------------------------");
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ---------------------------------------------------- global timeout
    initial begin
        #4_000_000;
        $display("RESULT: *** FAIL *** (timeout at %0t, %0d/%0d retired)",
                 $time, n_commit, n_gen);
        $finish;
    end

endmodule

`default_nettype wire
