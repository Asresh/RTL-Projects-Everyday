// ============================================================================
// Day 38 : Classic 5-Stage Pipelined RISC-V RV32I Integer Core
// ----------------------------------------------------------------------------
// A synthesizable, in-order, single-issue RV32I processor with the textbook
// IF -> ID -> EX -> MEM -> WB pipeline, a full data-forwarding network, a
// load-use hazard interlock (1-bubble stall), and branch/jump resolution in
// the EX stage (2-cycle control-flow penalty with pipeline flush).
//
// Implements the RV32I base integer ISA (user level, no CSR/FENCE/ECALL):
//   LUI  AUIPC  JAL  JALR
//   BEQ BNE BLT BGE BLTU BGEU
//   LB LH LW LBU LHU     SB SH SW
//   ADDI SLTI SLTIU XORI ORI ANDI SLLI SRLI SRAI
//   ADD  SUB  SLL SLT SLTU XOR SRL SRA OR AND
//
// The register file uses write-through (WB-forward) read so a WB in the same
// cycle as an ID read is observed. Instruction and data memories are on-chip
// synchronous-style arrays (single-cycle, combinational read) so the core is a
// self-contained, simulate-able unit. A "commit trace" port exposes the
// architectural retirement of each instruction at WB so an external golden
// ISS can check every committed instruction.
//
// Reset-safe, latch-free, `default_nettype none`. Parameterized memory depths.
// ============================================================================
`default_nettype none

module riscv_pipeline #(
    parameter int IMEM_WORDS = 1024,   // instruction memory depth (words)
    parameter int DMEM_WORDS = 1024    // data        memory depth (words)
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- architectural commit trace (from WB stage) -----------------------
    output logic        commit_valid,     // a real (non-bubble) instr retired
    output logic [31:0] commit_pc,         // its PC
    output logic [31:0] commit_instr,      // its raw encoding
    output logic        commit_reg_we,     // writes a GP register (rd != x0)
    output logic [4:0]  commit_rd,         // destination register
    output logic [31:0] commit_wdata,      // value written back
    output logic        commit_mem_we,     // performed a store
    output logic [31:0] commit_mem_addr,   // store byte address
    output logic [31:0] commit_mem_wdata,  // store data (rs2, pre-mask)
    output logic [2:0]  commit_funct3      // funct3 (load/store width)
);

    localparam int IAW = $clog2(IMEM_WORDS);
    localparam int DAW = $clog2(DMEM_WORDS);

    localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0,x0,0

    // ---- ALU operation codes ---------------------------------------------
    localparam logic [3:0] ALU_ADD=4'd0, ALU_SUB=4'd1, ALU_SLL=4'd2, ALU_SLT=4'd3,
                           ALU_SLTU=4'd4, ALU_XOR=4'd5, ALU_SRL=4'd6, ALU_SRA=4'd7,
                           ALU_OR=4'd8, ALU_AND=4'd9;

    // ---- operand-A source select -----------------------------------------
    localparam logic [1:0] OPA_RS1=2'd0, OPA_PC=2'd1, OPA_ZERO=2'd2;

    // =====================================================================
    // On-chip memories (initialized to NOP / 0 for clean off-program fetch)
    // =====================================================================
    logic [31:0] imem [0:IMEM_WORDS-1];
    logic [31:0] dmem [0:DMEM_WORDS-1];
    integer ii;
    initial begin
        for (ii = 0; ii < IMEM_WORDS; ii = ii + 1) imem[ii] = NOP;
        for (ii = 0; ii < DMEM_WORDS; ii = ii + 1) dmem[ii] = 32'h0;
    end

    // =====================================================================
    // Register file (32 x 32b), x0 hardwired zero, write-through read
    // =====================================================================
    logic [31:0] regs [0:31];
    integer jj;
    initial for (jj = 0; jj < 32; jj = jj + 1) regs[jj] = 32'h0;

    // hazard / control-flow wires (declared up front)
    logic        stall;       // load-use interlock
    logic        redirect;    // taken branch / jump in EX
    logic [31:0] redirect_pc; // its target

    // =====================================================================
    // IF : instruction fetch
    // =====================================================================
    logic [31:0] pc, pc_next, pc_plus4;
    assign pc_plus4 = pc + 32'd4;

    always_comb begin
        if (redirect)      pc_next = redirect_pc;
        else if (stall)    pc_next = pc;          // freeze on load-use
        else               pc_next = pc_plus4;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pc <= 32'h0;
        else        pc <= pc_next;
    end

    wire [IAW-1:0] if_widx = pc[IAW+1:2];
    wire [31:0]    if_instr = imem[if_widx];

    // =====================================================================
    // IF/ID pipeline register
    // =====================================================================
    logic        ifid_valid;
    logic [31:0] ifid_pc, ifid_instr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ifid_valid <= 1'b0;
            ifid_pc    <= 32'h0;
            ifid_instr <= NOP;
        end else if (redirect) begin          // squash wrong-path fetch
            ifid_valid <= 1'b0;
            ifid_pc    <= 32'h0;
            ifid_instr <= NOP;
        end else if (stall) begin             // hold consumer in ID
            ifid_valid <= ifid_valid;
            ifid_pc    <= ifid_pc;
            ifid_instr <= ifid_instr;
        end else begin
            ifid_valid <= 1'b1;
            ifid_pc    <= pc;
            ifid_instr <= if_instr;
        end
    end

    // =====================================================================
    // ID : decode + control + register read
    // =====================================================================
    wire [6:0] op    = ifid_instr[6:0];
    wire [4:0] rd_d  = ifid_instr[11:7];
    wire [2:0] f3_d  = ifid_instr[14:12];
    wire [4:0] rs1_d = ifid_instr[19:15];
    wire [4:0] rs2_d = ifid_instr[24:20];
    wire       f7b5  = ifid_instr[30];        // funct7[5] / imm shift-type bit

    // opcode groups
    localparam logic [6:0] OP_LUI=7'b0110111, OP_AUIPC=7'b0010111, OP_JAL=7'b1101111,
                           OP_JALR=7'b1100111, OP_BR=7'b1100011, OP_LOAD=7'b0000011,
                           OP_STORE=7'b0100011, OP_IMM=7'b0010011, OP_REG=7'b0110011;

    // immediate generation
    wire [31:0] imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
    wire [31:0] imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
    wire [31:0] imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7],
                         ifid_instr[30:25], ifid_instr[11:8], 1'b0};
    wire [31:0] imm_u = {ifid_instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12],
                         ifid_instr[20], ifid_instr[30:21], 1'b0};

    // control signals
    logic        c_regwrite, c_memread, c_memwrite, c_memtoreg, c_alusrc;
    logic        c_branch, c_jump, c_jalr, c_link;
    logic [1:0]  c_opa;
    logic [3:0]  c_aluctrl;
    logic [31:0] c_imm;
    logic        c_rs1_used, c_rs2_used;

    always_comb begin
        // safe defaults (a bubble / unknown op = NOP behaviour)
        c_regwrite = 1'b0; c_memread = 1'b0; c_memwrite = 1'b0; c_memtoreg = 1'b0;
        c_alusrc   = 1'b0; c_branch  = 1'b0; c_jump    = 1'b0;  c_jalr    = 1'b0;
        c_link     = 1'b0; c_opa     = OPA_RS1; c_aluctrl = ALU_ADD;
        c_imm      = imm_i; c_rs1_used = 1'b0; c_rs2_used = 1'b0;

        unique case (op)
            OP_LUI: begin
                c_regwrite = 1'b1; c_alusrc = 1'b1; c_opa = OPA_ZERO;
                c_aluctrl = ALU_ADD; c_imm = imm_u;
            end
            OP_AUIPC: begin
                c_regwrite = 1'b1; c_alusrc = 1'b1; c_opa = OPA_PC;
                c_aluctrl = ALU_ADD; c_imm = imm_u;
            end
            OP_JAL: begin
                c_regwrite = 1'b1; c_jump = 1'b1; c_link = 1'b1; c_imm = imm_j;
            end
            OP_JALR: begin
                c_regwrite = 1'b1; c_jump = 1'b1; c_jalr = 1'b1; c_link = 1'b1;
                c_alusrc = 1'b1; c_imm = imm_i; c_rs1_used = 1'b1;
            end
            OP_BR: begin
                c_branch = 1'b1; c_imm = imm_b;
                c_rs1_used = 1'b1; c_rs2_used = 1'b1;
            end
            OP_LOAD: begin
                c_regwrite = 1'b1; c_memread = 1'b1; c_memtoreg = 1'b1;
                c_alusrc = 1'b1; c_aluctrl = ALU_ADD; c_imm = imm_i;
                c_rs1_used = 1'b1;
            end
            OP_STORE: begin
                c_memwrite = 1'b1; c_alusrc = 1'b1; c_aluctrl = ALU_ADD;
                c_imm = imm_s; c_rs1_used = 1'b1; c_rs2_used = 1'b1;
            end
            OP_IMM: begin
                c_regwrite = 1'b1; c_alusrc = 1'b1; c_imm = imm_i;
                c_rs1_used = 1'b1;
                unique case (f3_d)
                    3'b000: c_aluctrl = ALU_ADD;                 // ADDI
                    3'b010: c_aluctrl = ALU_SLT;                 // SLTI
                    3'b011: c_aluctrl = ALU_SLTU;                // SLTIU
                    3'b100: c_aluctrl = ALU_XOR;                 // XORI
                    3'b110: c_aluctrl = ALU_OR;                  // ORI
                    3'b111: c_aluctrl = ALU_AND;                 // ANDI
                    3'b001: c_aluctrl = ALU_SLL;                 // SLLI
                    3'b101: c_aluctrl = f7b5 ? ALU_SRA : ALU_SRL;// SRAI/SRLI
                    default: c_aluctrl = ALU_ADD;
                endcase
            end
            OP_REG: begin
                c_regwrite = 1'b1; c_rs1_used = 1'b1; c_rs2_used = 1'b1;
                unique case (f3_d)
                    3'b000: c_aluctrl = f7b5 ? ALU_SUB : ALU_ADD;// SUB/ADD
                    3'b001: c_aluctrl = ALU_SLL;                 // SLL
                    3'b010: c_aluctrl = ALU_SLT;                 // SLT
                    3'b011: c_aluctrl = ALU_SLTU;                // SLTU
                    3'b100: c_aluctrl = ALU_XOR;                 // XOR
                    3'b101: c_aluctrl = f7b5 ? ALU_SRA : ALU_SRL;// SRA/SRL
                    3'b110: c_aluctrl = ALU_OR;                  // OR
                    3'b111: c_aluctrl = ALU_AND;                 // AND
                    default: c_aluctrl = ALU_ADD;
                endcase
            end
            default: ; // NOP / unrecognized: all-zero control (harmless bubble)
        endcase
    end

    // register-file read with WB write-through (declared here, driven from WB)
    logic        wb_we;
    logic [4:0]  wb_rd;
    logic [31:0] wb_val;

    wire [31:0] rf_rs1 = (rs1_d == 5'd0) ? 32'h0 :
                         (wb_we && (wb_rd == rs1_d)) ? wb_val : regs[rs1_d];
    wire [31:0] rf_rs2 = (rs2_d == 5'd0) ? 32'h0 :
                         (wb_we && (wb_rd == rs2_d)) ? wb_val : regs[rs2_d];

    // =====================================================================
    // ID/EX pipeline register
    // =====================================================================
    logic        idex_valid, idex_regwrite, idex_memread, idex_memwrite, idex_memtoreg;
    logic        idex_alusrc, idex_branch, idex_jump, idex_jalr, idex_link;
    logic [1:0]  idex_opa;
    logic [3:0]  idex_aluctrl;
    logic [2:0]  idex_f3;
    logic [4:0]  idex_rs1, idex_rs2, idex_rd;
    logic [31:0] idex_pc, idex_rs1v, idex_rs2v, idex_imm, idex_instr;

    wire idex_bubble = redirect | stall;   // insert bubble into EX on flush/stall

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || idex_bubble) begin
            idex_valid <= 1'b0; idex_regwrite <= 1'b0; idex_memread <= 1'b0;
            idex_memwrite <= 1'b0; idex_memtoreg <= 1'b0; idex_alusrc <= 1'b0;
            idex_branch <= 1'b0; idex_jump <= 1'b0; idex_jalr <= 1'b0; idex_link <= 1'b0;
            idex_opa <= OPA_RS1; idex_aluctrl <= ALU_ADD; idex_f3 <= 3'b0;
            idex_rs1 <= 5'b0; idex_rs2 <= 5'b0; idex_rd <= 5'b0;
            idex_pc <= 32'h0; idex_rs1v <= 32'h0; idex_rs2v <= 32'h0;
            idex_imm <= 32'h0; idex_instr <= NOP;
        end else begin
            idex_valid    <= ifid_valid;
            idex_regwrite <= c_regwrite; idex_memread  <= c_memread;
            idex_memwrite <= c_memwrite; idex_memtoreg <= c_memtoreg;
            idex_alusrc   <= c_alusrc;   idex_branch   <= c_branch;
            idex_jump     <= c_jump;     idex_jalr     <= c_jalr;
            idex_link     <= c_link;     idex_opa      <= c_opa;
            idex_aluctrl  <= c_aluctrl;  idex_f3       <= f3_d;
            idex_rs1      <= rs1_d;       idex_rs2      <= rs2_d;
            idex_rd       <= rd_d;        idex_pc       <= ifid_pc;
            idex_rs1v     <= rf_rs1;      idex_rs2v     <= rf_rs2;
            idex_imm      <= c_imm;       idex_instr    <= ifid_instr;
        end
    end

    // =====================================================================
    // EX : forwarding, ALU, branch resolution
    // =====================================================================
    // EX/MEM & MEM/WB registers (declared before use in forwarding)
    logic        exmem_valid, exmem_regwrite, exmem_memread, exmem_memwrite, exmem_memtoreg;
    logic [2:0]  exmem_f3;
    logic [4:0]  exmem_rd;
    logic [31:0] exmem_result, exmem_stdata, exmem_pc, exmem_instr;

    logic        memwb_valid, memwb_regwrite, memwb_memwrite;
    logic [2:0]  memwb_f3;
    logic [4:0]  memwb_rd;
    logic [31:0] memwb_wbval, memwb_pc, memwb_instr, memwb_memaddr, memwb_stdata;

    // forwarding selects: 00 = RF/ID value, 01 = EX/MEM result, 10 = MEM/WB value
    logic [1:0] fwdA, fwdB;
    always_comb begin
        fwdA = 2'b00;
        if (exmem_regwrite && (exmem_rd != 5'd0) && (exmem_rd == idex_rs1))
            fwdA = 2'b01;
        else if (memwb_regwrite && (memwb_rd != 5'd0) && (memwb_rd == idex_rs1))
            fwdA = 2'b10;

        fwdB = 2'b00;
        if (exmem_regwrite && (exmem_rd != 5'd0) && (exmem_rd == idex_rs2))
            fwdB = 2'b01;
        else if (memwb_regwrite && (memwb_rd != 5'd0) && (memwb_rd == idex_rs2))
            fwdB = 2'b10;
    end

    logic [31:0] fA, fB;
    always_comb begin
        unique case (fwdA)
            2'b01:   fA = exmem_result;
            2'b10:   fA = memwb_wbval;
            default: fA = idex_rs1v;
        endcase
        unique case (fwdB)
            2'b01:   fB = exmem_result;
            2'b10:   fB = memwb_wbval;
            default: fB = idex_rs2v;
        endcase
    end

    // ALU operands
    logic [31:0] alu_a, alu_b;
    always_comb begin
        unique case (idex_opa)
            OPA_PC:   alu_a = idex_pc;
            OPA_ZERO: alu_a = 32'h0;
            default:  alu_a = fA;
        endcase
        alu_b = idex_alusrc ? idex_imm : fB;
    end

    logic [31:0] alu_y;
    always_comb begin
        unique case (idex_aluctrl)
            ALU_ADD:  alu_y = alu_a + alu_b;
            ALU_SUB:  alu_y = alu_a - alu_b;
            ALU_SLL:  alu_y = alu_a << alu_b[4:0];
            ALU_SLT:  alu_y = ($signed(alu_a) < $signed(alu_b)) ? 32'h1 : 32'h0;
            ALU_SLTU: alu_y = (alu_a < alu_b) ? 32'h1 : 32'h0;
            ALU_XOR:  alu_y = alu_a ^ alu_b;
            ALU_SRL:  alu_y = alu_a >> alu_b[4:0];
            ALU_SRA:  alu_y = $signed(alu_a) >>> alu_b[4:0];
            ALU_OR:   alu_y = alu_a | alu_b;
            ALU_AND:  alu_y = alu_a & alu_b;
            default:  alu_y = alu_a + alu_b;
        endcase
    end

    // branch condition (compare forwarded operands)
    logic branch_taken;
    always_comb begin
        unique case (idex_f3)
            3'b000:  branch_taken = (fA == fB);                       // BEQ
            3'b001:  branch_taken = (fA != fB);                       // BNE
            3'b100:  branch_taken = ($signed(fA) <  $signed(fB));     // BLT
            3'b101:  branch_taken = ($signed(fA) >= $signed(fB));     // BGE
            3'b110:  branch_taken = (fA <  fB);                       // BLTU
            3'b111:  branch_taken = (fA >= fB);                       // BGEU
            default: branch_taken = 1'b0;
        endcase
    end

    // resolve control flow
    assign redirect    = idex_valid & (idex_jump | (idex_branch & branch_taken));
    wire [31:0] tgt_pcimm = idex_pc  + idex_imm;               // JAL / branch
    wire [31:0] tgt_jalr  = (fA + idex_imm) & 32'hFFFF_FFFE;   // JALR (clear LSB)
    assign redirect_pc = idex_jalr ? tgt_jalr : tgt_pcimm;

    // writeback candidate produced in EX (link = return address for jumps)
    wire [31:0] ex_result = idex_link ? (idex_pc + 32'd4) : alu_y;

    // =====================================================================
    // EX/MEM pipeline register
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exmem_valid <= 1'b0; exmem_regwrite <= 1'b0; exmem_memread <= 1'b0;
            exmem_memwrite <= 1'b0; exmem_memtoreg <= 1'b0; exmem_f3 <= 3'b0;
            exmem_rd <= 5'b0; exmem_result <= 32'h0; exmem_stdata <= 32'h0;
            exmem_pc <= 32'h0; exmem_instr <= NOP;
        end else begin
            exmem_valid    <= idex_valid;
            exmem_regwrite <= idex_regwrite & idex_valid;
            exmem_memread  <= idex_memread  & idex_valid;
            exmem_memwrite <= idex_memwrite & idex_valid;
            exmem_memtoreg <= idex_memtoreg;
            exmem_f3       <= idex_f3;
            exmem_rd       <= idex_rd;
            exmem_result   <= ex_result;
            exmem_stdata   <= fB;             // forwarded store data
            exmem_pc       <= idex_pc;
            exmem_instr    <= idex_instr;
        end
    end

    // =====================================================================
    // MEM : data memory access (loads combinational, stores synchronous)
    // =====================================================================
    wire [DAW-1:0] mem_widx = exmem_result[DAW+1:2];
    wire [1:0]     mem_boff = exmem_result[1:0];
    wire [31:0]    mem_word = dmem[mem_widx];

    // load data (sign / zero extended by funct3)
    logic [7:0]  lb_byte;
    logic [15:0] lh_half;
    logic [31:0] load_data;
    always_comb begin
        lb_byte = mem_word[8*mem_boff +: 8];
        lh_half = mem_boff[1] ? mem_word[31:16] : mem_word[15:0];
        unique case (exmem_f3)
            3'b000:  load_data = {{24{lb_byte[7]}},  lb_byte};   // LB
            3'b001:  load_data = {{16{lh_half[15]}}, lh_half};   // LH
            3'b010:  load_data = mem_word;                       // LW
            3'b100:  load_data = {24'h0, lb_byte};               // LBU
            3'b101:  load_data = {16'h0, lh_half};               // LHU
            default: load_data = mem_word;
        endcase
    end

    // store (byte-enabled read-modify-write of the addressed word)
    always_ff @(posedge clk) begin
        if (exmem_memwrite) begin
            unique case (exmem_f3)
                3'b000:  dmem[mem_widx][8*mem_boff  +: 8]  <= exmem_stdata[7:0];   // SB
                3'b001:  dmem[mem_widx][16*mem_boff[1] +: 16] <= exmem_stdata[15:0];// SH
                default: dmem[mem_widx] <= exmem_stdata;                            // SW
            endcase
        end
    end

    wire [31:0] mem_wbval = exmem_memtoreg ? load_data : exmem_result;

    // =====================================================================
    // MEM/WB pipeline register
    // =====================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            memwb_valid <= 1'b0; memwb_regwrite <= 1'b0; memwb_memwrite <= 1'b0;
            memwb_f3 <= 3'b0; memwb_rd <= 5'b0; memwb_wbval <= 32'h0;
            memwb_pc <= 32'h0; memwb_instr <= NOP; memwb_memaddr <= 32'h0;
            memwb_stdata <= 32'h0;
        end else begin
            memwb_valid    <= exmem_valid;
            memwb_regwrite <= exmem_regwrite;
            memwb_memwrite <= exmem_memwrite;
            memwb_f3       <= exmem_f3;
            memwb_rd       <= exmem_rd;
            memwb_wbval    <= mem_wbval;
            memwb_pc       <= exmem_pc;
            memwb_instr    <= exmem_instr;
            memwb_memaddr  <= exmem_result;
            memwb_stdata   <= exmem_stdata;
        end
    end

    // =====================================================================
    // WB : register-file write + commit trace
    // =====================================================================
    assign wb_we  = memwb_regwrite & (memwb_rd != 5'd0);
    assign wb_rd  = memwb_rd;
    assign wb_val = memwb_wbval;

    always_ff @(posedge clk) begin
        if (wb_we) regs[wb_rd] <= wb_val;
    end

    assign commit_valid     = memwb_valid;
    assign commit_pc        = memwb_pc;
    assign commit_instr     = memwb_instr;
    assign commit_reg_we    = wb_we;
    assign commit_rd        = memwb_rd;
    assign commit_wdata     = memwb_wbval;
    assign commit_mem_we    = memwb_memwrite;
    assign commit_mem_addr  = memwb_memaddr;
    assign commit_mem_wdata = memwb_stdata;
    assign commit_funct3    = memwb_f3;

    // =====================================================================
    // Hazard : load-use interlock (declared wire `stall` driven here)
    // =====================================================================
    always_comb begin
        stall = 1'b0;
        if (idex_valid && idex_memread && (idex_rd != 5'd0) &&
            ((c_rs1_used && (idex_rd == rs1_d)) ||
             (c_rs2_used && (idex_rd == rs2_d))))
            stall = 1'b1;
    end

endmodule

`default_nettype wire
