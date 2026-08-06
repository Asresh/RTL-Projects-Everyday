// ===========================================================================
// Day 41 : Out-of-Order Execution Engine  (Tomasulo + Reorder Buffer)
// ---------------------------------------------------------------------------
// A synthesizable out-of-order execution core:
//
//   in-order dispatch  ->  register renaming (RAT)  ->  reservation stations
//   -> out-of-order wakeup/select -> three functional units of different
//   latency -> single arbitrated Common Data Bus -> in-order ROB commit
//
// The engine accepts one instruction per cycle in program order, renames its
// destination onto a ROB tag, parks it in a unified reservation-station pool
// until both operands are available, issues it to a functional unit the moment
// it is ready *and* the unit is free (so instructions execute in dataflow
// order, not program order), broadcasts the result on a single Common Data Bus
// that wakes every dependent waiting station, and finally retires the ROB in
// strict program order so the architectural register file only ever sees
// in-order state.
//
// Functional units (all three run concurrently):
//   ALU  - 1 cycle, combinational, 1-deep output register
//   MUL  - MUL_STAGES-deep pipeline, one result per cycle when unblocked
//   DIV  - unpipelined restoring divider, XLEN iterations, holds its result
//
// Because only ONE result bus exists, the units contend for it; a rotating
// (round-robin) arbiter grants it so no unit can be starved, and a unit that
// loses the grant holds its result and back-pressures its own input.
//
// `flush` squashes the entire in-flight window (renaming, ROB, stations, FU
// state) in a single cycle and leaves the architectural register file intact,
// which is exactly what a branch-mispredict recovery needs.
//
// Fully parameterized, reset-safe, no latches, no `x` propagation from reset.
// ===========================================================================

`default_nettype none

module ooo_tomasulo #(
    parameter int XLEN       = 32,  // data path width
    parameter int AREGS      = 8,   // architectural registers
    parameter int ROB_DEPTH  = 8,   // reorder-buffer entries (power of 2)
    parameter int RS_DEPTH   = 6,   // unified reservation-station entries
    parameter int MUL_STAGES = 3    // multiplier pipeline depth (>= 1)
) (
    input  wire                            clk,
    input  wire                            rst_n,
    input  wire                            flush,        // squash all in-flight state

    // ---- dispatch port : in-order, one instruction per cycle --------------
    input  wire                            disp_valid,
    output wire                            disp_ready,
    input  wire [3:0]                      disp_op,
    input  wire [$clog2(AREGS)-1:0]        disp_rs1,
    input  wire [$clog2(AREGS)-1:0]        disp_rs2,
    input  wire [$clog2(AREGS)-1:0]        disp_rd,
    input  wire                            disp_rd_wen,  // 0 = result discarded
    input  wire [XLEN-1:0]                 disp_imm,
    input  wire                            disp_use_imm, // operand B = imm

    // ---- commit port : in-order, registered --------------------------------
    output logic                           commit_valid,
    output logic [$clog2(AREGS)-1:0]       commit_rd,
    output logic                           commit_rd_wen,
    output logic [XLEN-1:0]                commit_val,
    output logic [$clog2(ROB_DEPTH)-1:0]   commit_tag,

    // ---- observability ------------------------------------------------------
    output logic [31:0]                    perf_dispatched,
    output logic [31:0]                    perf_committed,
    output logic [31:0]                    perf_cdb_conflict,   // >1 FU wanted the bus
    output logic [31:0]                    perf_ooo_complete,   // finished before an older op
    output logic [31:0]                    perf_stall_rob,      // dispatch blocked, ROB full
    output logic [31:0]                    perf_stall_rs,       // dispatch blocked, RS full
    output logic [31:0]                    perf_flush,

    // packed mirrors of the three occupancy bitmaps.  Purely observational -
    // they carry no logic of their own, but ROB and station occupancy is the
    // single most useful thing to see in a waveform or on a debug port.
    output wire  [ROB_DEPTH-1:0]           dbg_rob_busy,
    output wire  [ROB_DEPTH-1:0]           dbg_rob_done,
    output wire  [RS_DEPTH-1:0]            dbg_rs_busy
);

    // ------------------------------------------------------------------ sizes
    localparam int AW  = $clog2(AREGS);
    localparam int TW  = $clog2(ROB_DEPTH);
    localparam int RW  = $clog2(RS_DEPTH);
    localparam int SHW = $clog2(XLEN);
    localparam int CW  = $clog2(ROB_DEPTH + 1);   // ROB occupancy counter

    localparam logic [CW-1:0]  ROB_FULL  = ROB_DEPTH;   // sized constants: Icarus
    localparam logic [SHW:0]   DIV_ITERS = XLEN;        // dislikes  W'(expr) casts

    // ------------------------------------------------------------- opcode map
    localparam logic [3:0] OP_ADD  = 4'd0;
    localparam logic [3:0] OP_SUB  = 4'd1;
    localparam logic [3:0] OP_AND  = 4'd2;
    localparam logic [3:0] OP_OR   = 4'd3;
    localparam logic [3:0] OP_XOR  = 4'd4;
    localparam logic [3:0] OP_SLL  = 4'd5;
    localparam logic [3:0] OP_SRL  = 4'd6;
    localparam logic [3:0] OP_SLT  = 4'd7;   // signed set-less-than
    localparam logic [3:0] OP_MUL  = 4'd8;   // low  half of a*b   (unsigned)
    localparam logic [3:0] OP_MULH = 4'd9;   // high half of a*b   (unsigned)
    localparam logic [3:0] OP_DIV  = 4'd10;  // a / b              (unsigned)
    localparam logic [3:0] OP_REM  = 4'd11;  // a % b              (unsigned)

    // functional-unit classes
    localparam logic [1:0] FU_ALU = 2'd0;
    localparam logic [1:0] FU_MUL = 2'd1;
    localparam logic [1:0] FU_DIV = 2'd2;

    // Pure: every input is an explicit argument, so it is correct in both a
    // procedural block and a continuous assign.
    function automatic logic [1:0] fu_of(input logic [3:0] op);
        if (op <= OP_SLT)       fu_of = FU_ALU;
        else if (op <= OP_MULH) fu_of = FU_MUL;
        else                    fu_of = FU_DIV;
    endfunction

    function automatic logic [XLEN-1:0] alu_exec(input logic [3:0]    op,
                                                 input logic [XLEN-1:0] a,
                                                 input logic [XLEN-1:0] b);
        case (op)
            OP_ADD : alu_exec = a + b;
            OP_SUB : alu_exec = a - b;
            OP_AND : alu_exec = a & b;
            OP_OR  : alu_exec = a | b;
            OP_XOR : alu_exec = a ^ b;
            OP_SLL : alu_exec = a << b[SHW-1:0];
            OP_SRL : alu_exec = a >> b[SHW-1:0];
            OP_SLT : alu_exec = {{(XLEN-1){1'b0}}, ($signed(a) < $signed(b))};
            default: alu_exec = {XLEN{1'b0}};
        endcase
    endfunction

    // program-order age of a ROB tag relative to the current head (0 = oldest)
    function automatic logic [TW-1:0] age_of(input logic [TW-1:0] tag,
                                             input logic [TW-1:0] head);
        age_of = tag - head;
    endfunction

    // =======================================================================
    // Architectural state (only ever written at commit)
    // =======================================================================
    logic [XLEN-1:0] arf      [AREGS];

    // Register alias table: which ROB entry, if any, owns each architectural
    // register's most recent definition.
    logic            rat_busy [AREGS];
    logic [TW-1:0]   rat_tag  [AREGS];

    // =======================================================================
    // Reorder buffer (circular, in-order allocate / in-order retire)
    // =======================================================================
    logic            rob_busy [ROB_DEPTH];
    logic            rob_done [ROB_DEPTH];
    logic            rob_wen  [ROB_DEPTH];
    logic [AW-1:0]   rob_rd   [ROB_DEPTH];
    logic [XLEN-1:0] rob_val  [ROB_DEPTH];

    logic [TW-1:0]   rob_head, rob_tail;
    logic [CW-1:0]   rob_count;

    genvar gi;
    generate
        for (gi = 0; gi < ROB_DEPTH; gi = gi + 1) begin : g_rob_map
            assign dbg_rob_busy[gi] = rob_busy[gi];
            assign dbg_rob_done[gi] = rob_done[gi];
        end
    endgenerate

    // =======================================================================
    // Unified reservation-station pool
    // =======================================================================
    logic            rs_busy [RS_DEPTH];
    logic [3:0]      rs_op   [RS_DEPTH];
    logic [1:0]      rs_fu   [RS_DEPTH];
    logic [TW-1:0]   rs_tag  [RS_DEPTH];   // destination ROB tag
    logic [XLEN-1:0] rs_vj   [RS_DEPTH];   // operand A value
    logic [XLEN-1:0] rs_vk   [RS_DEPTH];   // operand B value
    logic [TW-1:0]   rs_qj   [RS_DEPTH];   // operand A producer tag
    logic [TW-1:0]   rs_qk   [RS_DEPTH];
    logic            rs_rj   [RS_DEPTH];   // operand A ready
    logic            rs_rk   [RS_DEPTH];

    generate
        for (gi = 0; gi < RS_DEPTH; gi = gi + 1) begin : g_rs_map
            assign dbg_rs_busy[gi] = rs_busy[gi];
        end
    endgenerate

    // =======================================================================
    // Functional units
    // =======================================================================
    // ALU : 1-deep output register
    logic            alu_ov;
    logic [TW-1:0]   alu_otag;
    logic [XLEN-1:0] alu_oval;

    // MUL : MUL_STAGES-deep valid/tag/value shift pipeline
    logic            mul_v    [MUL_STAGES];
    logic [TW-1:0]   mul_tag  [MUL_STAGES];
    logic [XLEN-1:0] mul_val  [MUL_STAGES];

    // DIV : unpipelined restoring divider
    logic            div_run;                 // iterating
    logic            div_ov;                  // result held, waiting for the CDB
    logic [3:0]      div_op;
    logic [TW-1:0]   div_tag;
    logic [XLEN-1:0] div_b;
    logic [XLEN-1:0] div_q;                   // quotient  / shifting dividend
    logic [XLEN:0]   div_r;                   // remainder accumulator (1 guard bit)
    logic [SHW:0]    div_cnt;
    logic [XLEN-1:0] div_oval;

    // =======================================================================
    // Common Data Bus arbitration (rotating priority: no unit can starve)
    // =======================================================================
    logic [2:0]      cdb_req;
    logic [1:0]      cdb_rr;                  // next unit to get first refusal
    logic [1:0]      cdb_sel;                 // 2'd0/1/2 = ALU/MUL/DIV
    logic            cdb_valid;
    logic [TW-1:0]   cdb_tag;
    logic [XLEN-1:0] cdb_val;
    logic            gnt_alu, gnt_mul, gnt_div;

    assign cdb_req[0] = alu_ov;
    assign cdb_req[1] = mul_v[MUL_STAGES-1];
    assign cdb_req[2] = div_ov;

    // First requester at or after cdb_rr, wrapping. Written out explicitly
    // rather than as a loop so the priority chain is obvious in synthesis.
    always_comb begin
        case (cdb_rr)
            2'd0    : cdb_sel = cdb_req[0] ? 2'd0 : cdb_req[1] ? 2'd1 :
                                cdb_req[2] ? 2'd2 : 2'd3;
            2'd1    : cdb_sel = cdb_req[1] ? 2'd1 : cdb_req[2] ? 2'd2 :
                                cdb_req[0] ? 2'd0 : 2'd3;
            default : cdb_sel = cdb_req[2] ? 2'd2 : cdb_req[0] ? 2'd0 :
                                cdb_req[1] ? 2'd1 : 2'd3;
        endcase
    end

    assign cdb_valid = (cdb_sel != 2'd3);
    assign gnt_alu   = cdb_valid && (cdb_sel == 2'd0);
    assign gnt_mul   = cdb_valid && (cdb_sel == 2'd1);
    assign gnt_div   = cdb_valid && (cdb_sel == 2'd2);

    always_comb begin
        case (cdb_sel)
            2'd0    : begin cdb_tag = alu_otag;             cdb_val = alu_oval;             end
            2'd1    : begin cdb_tag = mul_tag[MUL_STAGES-1];cdb_val = mul_val[MUL_STAGES-1];end
            2'd2    : begin cdb_tag = div_tag;              cdb_val = div_oval;             end
            default : begin cdb_tag = {TW{1'b0}};           cdb_val = {XLEN{1'b0}};         end
        endcase
    end

    // A completion is "out of order" if some strictly older ROB entry is still
    // un-finished at the moment this result is broadcast.
    logic cdb_is_ooo;
    always_comb begin
        cdb_is_ooo = 1'b0;
        for (int i = 0; i < ROB_DEPTH; i++)
            if (rob_busy[i] && !rob_done[i] &&
                age_of(i[TW-1:0], rob_head) < age_of(cdb_tag, rob_head))
                cdb_is_ooo = cdb_valid;
    end

    // =======================================================================
    // Wakeup / select : oldest ready station per functional unit
    // =======================================================================
    logic [2:0]    sel_valid;
    logic [RW-1:0] sel_idx  [3];
    logic [TW-1:0] sel_age  [3];

    always_comb begin
        logic [1:0]    f;
        logic [TW-1:0] a;
        for (int k = 0; k < 3; k++) begin
            sel_valid[k] = 1'b0;
            sel_idx[k]   = {RW{1'b0}};
            sel_age[k]   = {TW{1'b0}};
        end
        for (int i = 0; i < RS_DEPTH; i++) begin
            if (rs_busy[i] && rs_rj[i] && rs_rk[i]) begin
                f = rs_fu[i];
                a = age_of(rs_tag[i], rob_head);
                if (!sel_valid[f] || (a < sel_age[f])) begin
                    sel_valid[f] = 1'b1;
                    sel_idx[f]   = i[RW-1:0];
                    sel_age[f]   = a;
                end
            end
        end
    end

    // A unit can take work when its output slot is free, or is freed this
    // cycle by winning the CDB.
    logic can_alu, can_mul, can_div;
    logic fire_alu, fire_mul, fire_div;

    assign can_alu = !alu_ov || gnt_alu;
    assign can_mul = !mul_v[MUL_STAGES-1] || gnt_mul;
    assign can_div = !div_run && (!div_ov || gnt_div);

    assign fire_alu = sel_valid[FU_ALU] && can_alu;
    assign fire_mul = sel_valid[FU_MUL] && can_mul;
    assign fire_div = sel_valid[FU_DIV] && can_div;

    // =======================================================================
    // Dispatch : allocate a ROB tag + a station, rename, read operands
    // =======================================================================
    logic            rs_free_valid;
    logic [RW-1:0]   rs_free_idx;
    always_comb begin
        rs_free_valid = 1'b0;
        rs_free_idx   = {RW{1'b0}};
        for (int i = RS_DEPTH - 1; i >= 0; i--)
            if (!rs_busy[i]) begin
                rs_free_valid = 1'b1;
                rs_free_idx   = i[RW-1:0];
            end
    end

    logic commit_fire, rob_has_room, disp_fire;

    assign rob_has_room = (rob_count != ROB_FULL) || commit_fire;
    assign commit_fire  = rob_busy[rob_head] && rob_done[rob_head] && !flush;
    assign disp_ready   = rob_has_room && rs_free_valid && !flush;
    assign disp_fire    = disp_valid && disp_ready;

    // Operand resolution, in priority order:
    //   1. not renamed          -> architectural register file
    //   2. renamed, already done-> the ROB entry's result
    //   3. renamed, on the CDB  -> same-cycle bypass off the result bus
    //   4. otherwise            -> record the producer tag and wait
    logic            srcA_rdy,  srcB_rdy;
    logic [XLEN-1:0] srcA_val,  srcB_val;
    logic [TW-1:0]   srcA_tag,  srcB_tag;

    always_comb begin
        srcA_tag = rat_tag[disp_rs1];
        if (!rat_busy[disp_rs1]) begin
            srcA_rdy = 1'b1;  srcA_val = arf[disp_rs1];
        end else if (rob_done[srcA_tag]) begin
            srcA_rdy = 1'b1;  srcA_val = rob_val[srcA_tag];
        end else if (cdb_valid && (cdb_tag == srcA_tag)) begin
            srcA_rdy = 1'b1;  srcA_val = cdb_val;
        end else begin
            srcA_rdy = 1'b0;  srcA_val = {XLEN{1'b0}};
        end
    end

    always_comb begin
        srcB_tag = rat_tag[disp_rs2];
        if (disp_use_imm) begin
            srcB_rdy = 1'b1;  srcB_val = disp_imm;
        end else if (!rat_busy[disp_rs2]) begin
            srcB_rdy = 1'b1;  srcB_val = arf[disp_rs2];
        end else if (rob_done[srcB_tag]) begin
            srcB_rdy = 1'b1;  srcB_val = rob_val[srcB_tag];
        end else if (cdb_valid && (cdb_tag == srcB_tag)) begin
            srcB_rdy = 1'b1;  srcB_val = cdb_val;
        end else begin
            srcB_rdy = 1'b0;  srcB_val = {XLEN{1'b0}};
        end
    end

    // divider first-step helpers (restoring, one bit per cycle)
    logic [XLEN:0] div_shift, div_diff;
    logic          div_ge;
    assign div_shift = {div_r[XLEN-1:0], div_q[XLEN-1]};
    assign div_diff  = div_shift - {1'b0, div_b};
    assign div_ge    = (div_shift >= {1'b0, div_b});

    // multiplier operand widening (unsigned)
    logic [2*XLEN-1:0] mul_prod;
    assign mul_prod = {{XLEN{1'b0}}, rs_vj[sel_idx[FU_MUL]]} *
                      {{XLEN{1'b0}}, rs_vk[sel_idx[FU_MUL]]};

    // =======================================================================
    // Sequential core
    //
    // Statement order inside the block is load-bearing:
    //   1. CDB write-back + station wakeup
    //   2. functional-unit advance, then issue (issue overwrites a freed slot)
    //   3. commit  (clears a RAT entry)
    //   4. dispatch(may re-claim that same RAT entry - must win)
    //   5. pointer/counter updates computed once from the fire flags
    //   6. flush override
    // =======================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < AREGS; i++) begin
                arf[i]      <= {XLEN{1'b0}};
                rat_busy[i] <= 1'b0;
                rat_tag[i]  <= {TW{1'b0}};
            end
            for (int i = 0; i < ROB_DEPTH; i++) begin
                rob_busy[i] <= 1'b0;
                rob_done[i] <= 1'b0;
                rob_wen[i]  <= 1'b0;
                rob_rd[i]   <= {AW{1'b0}};
                rob_val[i]  <= {XLEN{1'b0}};
            end
            for (int i = 0; i < RS_DEPTH; i++) begin
                rs_busy[i] <= 1'b0;
                rs_op[i]   <= 4'd0;
                rs_fu[i]   <= FU_ALU;
                rs_tag[i]  <= {TW{1'b0}};
                rs_vj[i]   <= {XLEN{1'b0}};
                rs_vk[i]   <= {XLEN{1'b0}};
                rs_qj[i]   <= {TW{1'b0}};
                rs_qk[i]   <= {TW{1'b0}};
                rs_rj[i]   <= 1'b0;
                rs_rk[i]   <= 1'b0;
            end
            for (int i = 0; i < MUL_STAGES; i++) begin
                mul_v[i]   <= 1'b0;
                mul_tag[i] <= {TW{1'b0}};
                mul_val[i] <= {XLEN{1'b0}};
            end
            rob_head <= {TW{1'b0}};
            rob_tail <= {TW{1'b0}};
            rob_count<= {CW{1'b0}};
            cdb_rr   <= 2'd0;
            alu_ov   <= 1'b0;
            alu_otag <= {TW{1'b0}};
            alu_oval <= {XLEN{1'b0}};
            div_run  <= 1'b0;
            div_ov   <= 1'b0;
            div_op   <= 4'd0;
            div_tag  <= {TW{1'b0}};
            div_b    <= {XLEN{1'b0}};
            div_q    <= {XLEN{1'b0}};
            div_r    <= {(XLEN+1){1'b0}};
            div_cnt  <= {(SHW+1){1'b0}};
            div_oval <= {XLEN{1'b0}};

            commit_valid  <= 1'b0;
            commit_rd     <= {AW{1'b0}};
            commit_rd_wen <= 1'b0;
            commit_val    <= {XLEN{1'b0}};
            commit_tag    <= {TW{1'b0}};

            perf_dispatched   <= 32'd0;
            perf_committed    <= 32'd0;
            perf_cdb_conflict <= 32'd0;
            perf_ooo_complete <= 32'd0;
            perf_stall_rob    <= 32'd0;
            perf_stall_rs     <= 32'd0;
            perf_flush        <= 32'd0;
        end else begin
            // ------------------------------------------------ 1. CDB effects
            commit_valid <= 1'b0;

            if (cdb_valid) begin
                rob_val[cdb_tag]  <= cdb_val;
                rob_done[cdb_tag] <= 1'b1;
                cdb_rr            <= (cdb_sel == 2'd2) ? 2'd0 : (cdb_sel + 2'd1);

                for (int i = 0; i < RS_DEPTH; i++) begin
                    if (rs_busy[i] && !rs_rj[i] && (rs_qj[i] == cdb_tag)) begin
                        rs_vj[i] <= cdb_val;
                        rs_rj[i] <= 1'b1;
                    end
                    if (rs_busy[i] && !rs_rk[i] && (rs_qk[i] == cdb_tag)) begin
                        rs_vk[i] <= cdb_val;
                        rs_rk[i] <= 1'b1;
                    end
                end
            end

            // ------------------------------- 2a. functional units: advance
            if (gnt_alu) alu_ov <= 1'b0;

            if (can_mul) begin
                mul_v[0] <= 1'b0;
                for (int s = MUL_STAGES - 1; s > 0; s--) begin
                    mul_v[s]   <= mul_v[s-1];
                    mul_tag[s] <= mul_tag[s-1];
                    mul_val[s] <= mul_val[s-1];
                end
            end

            if (gnt_div) div_ov <= 1'b0;

            if (div_run) begin
                if (div_cnt == {(SHW+1){1'b0}}) begin
                    // iteration finished on the previous cycle
                    div_run  <= 1'b0;
                    div_ov   <= 1'b1;
                    div_oval <= (div_op == OP_DIV) ? div_q : div_r[XLEN-1:0];
                end else begin
                    div_r   <= div_ge ? div_diff : div_shift;
                    div_q   <= {div_q[XLEN-2:0], div_ge};
                    div_cnt <= div_cnt - 1'b1;
                end
            end

            // ------------------------------- 2b. functional units: issue
            if (fire_alu) begin
                rs_busy[sel_idx[FU_ALU]] <= 1'b0;
                alu_ov   <= 1'b1;
                alu_otag <= rs_tag[sel_idx[FU_ALU]];
                alu_oval <= alu_exec(rs_op[sel_idx[FU_ALU]],
                                     rs_vj[sel_idx[FU_ALU]],
                                     rs_vk[sel_idx[FU_ALU]]);
            end

            if (fire_mul) begin
                rs_busy[sel_idx[FU_MUL]] <= 1'b0;
                mul_v[0]   <= 1'b1;
                mul_tag[0] <= rs_tag[sel_idx[FU_MUL]];
                mul_val[0] <= (rs_op[sel_idx[FU_MUL]] == OP_MUL)
                              ? mul_prod[XLEN-1:0]
                              : mul_prod[2*XLEN-1:XLEN];
            end

            if (fire_div) begin
                rs_busy[sel_idx[FU_DIV]] <= 1'b0;
                div_op  <= rs_op[sel_idx[FU_DIV]];
                div_tag <= rs_tag[sel_idx[FU_DIV]];
                div_b   <= rs_vk[sel_idx[FU_DIV]];
                if (rs_vk[sel_idx[FU_DIV]] == {XLEN{1'b0}}) begin
                    // RISC-V divide-by-zero: quotient = all ones, remainder = dividend
                    div_run  <= 1'b0;
                    div_ov   <= 1'b1;
                    div_oval <= (rs_op[sel_idx[FU_DIV]] == OP_DIV)
                                ? {XLEN{1'b1}} : rs_vj[sel_idx[FU_DIV]];
                end else begin
                    div_run <= 1'b1;
                    div_ov  <= 1'b0;
                    div_q   <= rs_vj[sel_idx[FU_DIV]];
                    div_r   <= {(XLEN+1){1'b0}};
                    div_cnt <= DIV_ITERS;
                end
            end

            // ------------------------------------------------- 3. commit
            if (commit_fire) begin
                rob_busy[rob_head] <= 1'b0;
                rob_done[rob_head] <= 1'b0;
                rob_head           <= rob_head + 1'b1;

                if (rob_wen[rob_head])
                    arf[rob_rd[rob_head]] <= rob_val[rob_head];

                // only release the alias if this entry is still the newest
                // definition of that register (a later writer may own it now)
                if (rob_wen[rob_head] && rat_busy[rob_rd[rob_head]] &&
                    (rat_tag[rob_rd[rob_head]] == rob_head))
                    rat_busy[rob_rd[rob_head]] <= 1'b0;

                commit_valid   <= 1'b1;
                commit_rd      <= rob_rd[rob_head];
                commit_rd_wen  <= rob_wen[rob_head];
                commit_val     <= rob_val[rob_head];
                commit_tag     <= rob_head;
                perf_committed <= perf_committed + 32'd1;
            end

            // ------------------------------------------------ 4. dispatch
            if (disp_fire) begin
                rob_busy[rob_tail] <= 1'b1;
                rob_done[rob_tail] <= 1'b0;
                rob_wen[rob_tail]  <= disp_rd_wen;
                rob_rd[rob_tail]   <= disp_rd;
                rob_val[rob_tail]  <= {XLEN{1'b0}};
                rob_tail           <= rob_tail + 1'b1;

                rs_busy[rs_free_idx] <= 1'b1;
                rs_op[rs_free_idx]   <= disp_op;
                rs_fu[rs_free_idx]   <= fu_of(disp_op);
                rs_tag[rs_free_idx]  <= rob_tail;
                rs_vj[rs_free_idx]   <= srcA_val;
                rs_qj[rs_free_idx]   <= srcA_tag;
                rs_rj[rs_free_idx]   <= srcA_rdy;
                rs_vk[rs_free_idx]   <= srcB_val;
                rs_qk[rs_free_idx]   <= srcB_tag;
                rs_rk[rs_free_idx]   <= srcB_rdy;

                if (disp_rd_wen) begin
                    rat_busy[disp_rd] <= 1'b1;
                    rat_tag[disp_rd]  <= rob_tail;
                end

                perf_dispatched <= perf_dispatched + 32'd1;
            end

            // ---------------------------------- 5. occupancy + statistics
            if (disp_fire != commit_fire)
                rob_count <= disp_fire ? (rob_count + 1'b1) : (rob_count - 1'b1);

            if (cdb_req != 3'd0 && cdb_req != 3'd1 &&
                cdb_req != 3'd2 && cdb_req != 3'd4)
                perf_cdb_conflict <= perf_cdb_conflict + 32'd1;
            if (cdb_is_ooo)
                perf_ooo_complete <= perf_ooo_complete + 32'd1;
            if (disp_valid && !rob_has_room)
                perf_stall_rob <= perf_stall_rob + 32'd1;
            if (disp_valid && rob_has_room && !rs_free_valid)
                perf_stall_rs  <= perf_stall_rs + 32'd1;

            // ---------------------------------------- 6. flush override
            // Squash the whole speculative window. The architectural register
            // file and the performance counters survive; everything that was
            // in flight does not.
            if (flush) begin
                for (int i = 0; i < AREGS; i++)
                    rat_busy[i] <= 1'b0;
                for (int i = 0; i < ROB_DEPTH; i++) begin
                    rob_busy[i] <= 1'b0;
                    rob_done[i] <= 1'b0;
                end
                for (int i = 0; i < RS_DEPTH; i++)
                    rs_busy[i] <= 1'b0;
                for (int i = 0; i < MUL_STAGES; i++)
                    mul_v[i] <= 1'b0;
                rob_head     <= {TW{1'b0}};
                rob_tail     <= {TW{1'b0}};
                rob_count    <= {CW{1'b0}};
                alu_ov       <= 1'b0;
                div_run      <= 1'b0;
                div_ov       <= 1'b0;
                cdb_rr       <= 2'd0;
                commit_valid <= 1'b0;
                perf_flush   <= perf_flush + 32'd1;
            end
        end
    end

`ifndef SYNTHESIS
    // ------------------------------------------------------------ assertions
    always_ff @(posedge clk) if (rst_n && !flush) begin
        // the ROB never over- or under-flows
        if (rob_count > ROB_FULL)
            $fatal(1, "%0t: ROB occupancy %0d exceeds depth", $time, rob_count);
        // a result may only ever be written into an allocated ROB entry
        if (cdb_valid && !rob_busy[cdb_tag])
            $fatal(1, "%0t: CDB wrote free ROB entry %0d", $time, cdb_tag);
        // a result may never be written into an entry that already has one
        if (cdb_valid && rob_done[cdb_tag])
            $fatal(1, "%0t: CDB double-completed ROB entry %0d", $time, cdb_tag);
        // at most one functional unit may drive the bus
        if (({2'b0, gnt_alu} + {2'b0, gnt_mul} + {2'b0, gnt_div}) > 3'd1)
            $fatal(1, "%0t: multiple CDB grants", $time);
    end
`endif

endmodule

`default_nettype wire
