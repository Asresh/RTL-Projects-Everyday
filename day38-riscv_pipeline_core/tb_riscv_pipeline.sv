// ============================================================================
// Day 38 : Self-checking testbench for the 5-stage pipelined RV32I core.
// ----------------------------------------------------------------------------
// The DUT exposes an architectural COMMIT-TRACE port (one retirement per WB).
// This testbench contains a fully independent golden RV32I instruction-set
// simulator (a sequential interpreter). For EVERY instruction the DUT commits
// it checks, in lockstep:
//     * the committed PC equals the ISS program counter  (control-flow proof:
//       branches taken/not-taken, jal/jalr targets all match the ISA)
//     * the committed raw encoding equals what the ISS fetched
//     * the register writeback (rd, value, write-enable) matches the ISS
//     * any store (addr, width, data) matches the ISS
// and updates the ISS. After the run it also compares the ENTIRE DUT register
// file and data memory against the golden model.
//
// The program mixes directed coverage (all opcodes, all load/store widths,
// taken & not-taken branches, a backward loop, a jal/jalr call+return that
// forces forwarding) with a long randomized ALU stream that hammers the
// forwarding network and the load-use interlock.
//
// Dumps riscv_pipeline.vcd. Prints "RESULT: *** PASS ***" iff 0 mismatches.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_riscv_pipeline;

    localparam int IMEMW = 1024;
    localparam int DMEMW = 1024;

    // ---- clock / reset ----------------------------------------------------
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    // ---- DUT commit-trace wires ------------------------------------------
    logic        commit_valid, commit_reg_we, commit_mem_we;
    logic [31:0] commit_pc, commit_instr, commit_wdata, commit_mem_addr, commit_mem_wdata;
    logic [4:0]  commit_rd;
    logic [2:0]  commit_funct3;

    riscv_pipeline #(.IMEM_WORDS(IMEMW), .DMEM_WORDS(DMEMW)) dut (
        .clk(clk), .rst_n(rst_n),
        .commit_valid(commit_valid), .commit_pc(commit_pc), .commit_instr(commit_instr),
        .commit_reg_we(commit_reg_we), .commit_rd(commit_rd), .commit_wdata(commit_wdata),
        .commit_mem_we(commit_mem_we), .commit_mem_addr(commit_mem_addr),
        .commit_mem_wdata(commit_mem_wdata), .commit_funct3(commit_funct3)
    );

    // =====================================================================
    // Program image + golden architectural state
    // =====================================================================
    logic [31:0] prog   [0:IMEMW-1];
    logic [31:0] g_imem [0:IMEMW-1];
    logic [31:0] g_reg  [0:31];
    logic [31:0] g_mem  [0:DMEMW-1];
    logic [31:0] g_pc;

    integer checks = 0;
    integer errors = 0;
    integer retired = 0;

    // ---------------------------------------------------------------------
    // Instruction encoders
    // ---------------------------------------------------------------------
    function automatic [31:0] enc_r(input [6:0] opc, input [2:0] f3, input [6:0] f7,
                                    input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        enc_r = {f7, rs2, rs1, f3, rd, opc};
    endfunction
    function automatic [31:0] enc_i(input [6:0] opc, input [2:0] f3,
                                    input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        enc_i = {imm, rs1, f3, rd, opc};
    endfunction
    function automatic [31:0] enc_ish(input [2:0] f3, input [6:0] f7,
                                      input [4:0] rd, input [4:0] rs1, input [4:0] sh);
        enc_ish = {f7, sh, rs1, f3, rd, 7'b0010011};
    endfunction
    function automatic [31:0] enc_s(input [2:0] f3, input [4:0] rs1, input [4:0] rs2,
                                    input [11:0] imm);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], 7'b0100011};
    endfunction
    function automatic [31:0] enc_b(input [2:0] f3, input [4:0] rs1, input [4:0] rs2,
                                    input [12:0] imm);
        enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], 7'b1100011};
    endfunction
    function automatic [31:0] enc_u(input [6:0] opc, input [4:0] rd, input [19:0] imm20);
        enc_u = {imm20, rd, opc};
    endfunction
    function automatic [31:0] enc_j(input [4:0] rd, input [20:0] imm);
        enc_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, 7'b1101111};
    endfunction

    // convenient mnemonics
    localparam [6:0] LUI=7'b0110111, AUIPC=7'b0010111, JALR=7'b1100111,
                     LOAD=7'b0000011, IMM=7'b0010011, REG=7'b0110011;

    // program assembly cursor + patch support
    integer pcw;
    task automatic emit(input [31:0] w); begin prog[pcw] = w; pcw = pcw + 1; end endtask

    integer idx_call, idx_skip;          // forward-reference patch slots
    integer w_loop, w_sub, w_end;

    integer ri, rt, rd_r, rs1_r, rs2_r;
    logic [11:0] rimm;

    // ---------------------------------------------------------------------
    // Build the test program
    // ---------------------------------------------------------------------
    task automatic build_program;
    begin
        for (pcw = 0; pcw < IMEMW; pcw = pcw + 1) prog[pcw] = 32'h0000_0013; // NOP fill
        pcw = 0;

        // ---- segment A : constant/upper-immediate setup ------------------
        emit(enc_u(LUI,   5, 20'h12345));                 // x5  = 0x12345000
        emit(enc_i(IMM, 3'b000, 5, 5, 12'h678));          // x5 += 0x678  -> 0x12345678
        emit(enc_u(AUIPC, 6, 20'h00010));                 // x6  = pc + 0x10000
        emit(enc_i(IMM, 3'b000, 7, 0, 12'd100));          // x7  = 100
        emit(enc_i(IMM, 3'b000, 8, 0, 12'hF9C));          // x8  = -100 (sext)
        emit(enc_i(IMM, 3'b000, 9, 0, 12'd15));           // x9  = 15

        // ---- segment B : all OP-IMM (immediate ALU) ----------------------
        emit(enc_i(IMM, 3'b010, 10, 8, 12'd5));           // SLTI  x10 = (-100 < 5)  = 1
        emit(enc_i(IMM, 3'b011, 11, 7, 12'd200));         // SLTIU x11 = (100 <u 200)= 1
        emit(enc_i(IMM, 3'b100, 12, 5, 12'h0FF));         // XORI  x12 = x5 ^ 0xFF
        emit(enc_i(IMM, 3'b110, 13, 7, 12'h00F));         // ORI   x13 = 100 | 0xF
        emit(enc_i(IMM, 3'b111, 14, 5, 12'h0F0));         // ANDI  x14 = x5 & 0xF0
        emit(enc_ish(3'b001, 7'b0000000, 15, 9, 5'd4));   // SLLI  x15 = 15 << 4
        emit(enc_ish(3'b101, 7'b0000000, 16, 5, 5'd8));   // SRLI  x16 = x5 >> 8
        emit(enc_ish(3'b101, 7'b0100000, 17, 8, 5'd2));   // SRAI  x17 = (-100) >>> 2

        // ---- segment C : all OP (register ALU), back-to-back deps --------
        emit(enc_r(REG, 3'b000, 7'b0000000, 18, 7, 9));   // ADD  x18 = 100+15
        emit(enc_r(REG, 3'b000, 7'b0100000, 19, 7, 9));   // SUB  x19 = 100-15
        emit(enc_r(REG, 3'b001, 7'b0000000, 20, 9, 7));   // SLL  x20 = 15 << (100&31)
        emit(enc_r(REG, 3'b010, 7'b0000000, 21, 8, 7));   // SLT  x21 = (-100 < 100)=1
        emit(enc_r(REG, 3'b011, 7'b0000000, 22, 8, 7));   // SLTU x22 = (-100 <u 100)=0
        emit(enc_r(REG, 3'b100, 7'b0000000, 23, 5, 9));   // XOR  x23 = x5 ^ 15
        emit(enc_r(REG, 3'b101, 7'b0000000, 24, 5, 9));   // SRL  x24 = x5 >> 15
        emit(enc_r(REG, 3'b101, 7'b0100000, 25, 8, 9));   // SRA  x25 = (-100) >>> 15
        emit(enc_r(REG, 3'b110, 7'b0000000, 26, 7, 9));   // OR   x26 = 100 | 15
        emit(enc_r(REG, 3'b111, 7'b0000000, 27, 7, 9));   // AND  x27 = 100 & 15

        // ---- segment D : stores + loads of every width -------------------
        // base pointer x28 = 0x40 (word 16 in dmem)
        emit(enc_i(IMM, 3'b000, 28, 0, 12'h040));         // x28 = 0x40
        emit(enc_i(IMM, 3'b000, 29, 0, 12'h7A5));         // x29 = 0x7A5 (test pattern, sext)
        emit(enc_s(3'b010, 28, 5,  12'd0));               // SW  [x28+0]  = x5
        emit(enc_s(3'b001, 28, 29, 12'd8));               // SH  [x28+8]  = x29[15:0]
        emit(enc_s(3'b000, 28, 29, 12'd12));              // SB  [x28+12] = x29[7:0]
        emit(enc_s(3'b000, 28, 5,  12'd13));              // SB  [x28+13] = x5[7:0]
        emit(enc_i(LOAD, 3'b010, 30, 28, 12'd0));         // LW  x30 = [x28+0]  (load-use next)
        emit(enc_r(REG, 3'b000, 7'b0000000, 31, 30, 9));  // ADD x31 = x30 + 15  (LOAD-USE HAZARD)
        emit(enc_i(LOAD, 3'b001, 3,  28, 12'd8));         // LH  x3  = [x28+8]   sign-ext
        emit(enc_i(LOAD, 3'b101, 4,  28, 12'd8));         // LHU x4  = [x28+8]   zero-ext
        emit(enc_i(LOAD, 3'b000, 2,  28, 12'd12));        // LB  x2  = [x28+12]  sign-ext
        emit(enc_i(LOAD, 3'b100, 1,  28, 12'd13));        // LBU x1  = [x28+13]  zero-ext

        // ---- segment E : branches (taken + not-taken) + backward loop ----
        // not-taken: BEQ x7,x9 (100==15? no) -> falls through
        emit(enc_b(3'b000, 7, 9, 13'd8));                 // BEQ (not taken)
        emit(enc_i(IMM, 3'b000, 6, 0, 12'd777));          // x6 = 777 (executes, since not taken)
        // taken forward: BNE x7,x9 -> skip the next instr
        emit(enc_b(3'b001, 7, 9, 13'd8));                 // BNE (taken, skip +8)
        emit(enc_i(IMM, 3'b000, 6, 0, 12'd888));          // SKIPPED
        // backward loop: sum 1..10 into x5 (=55)
        emit(enc_i(IMM, 3'b000, 5, 0, 12'd0));            // x5 = 0 (sum)
        emit(enc_i(IMM, 3'b000, 6, 0, 12'd1));            // x6 = 1 (i)
        emit(enc_i(IMM, 3'b000, 7, 0, 12'd11));           // x7 = 11 (limit)
        w_loop = pcw;                                     // loop target
        emit(enc_r(REG, 3'b000, 7'b0000000, 5, 5, 6));    // sum += i
        emit(enc_i(IMM, 3'b000, 6, 6, 12'd1));            // i++
        emit(enc_b(3'b100, 6, 7, (13'(w_loop) - 13'(pcw)) << 2)); // BLT i<11 -> loop (backward)

        // ---- segment F : jal / jalr call + return (forwarding of link) ---
        emit(enc_i(IMM, 3'b000, 10, 0, 12'd7));           // a0 = 7
        idx_call = pcw;  emit(32'h0);                     // JAL x1, sub   (patched)
        emit(enc_i(IMM, 3'b000, 11, 10, 12'd100));        // x11 = a0 + 100  (after return: 8+100=108)
        idx_skip = pcw;  emit(32'h0);                     // JAL x0, end   (patched, skip sub)
        w_sub = pcw;
        emit(enc_i(IMM, 3'b000, 10, 10, 12'd1));          // sub: a0 += 1  -> 8
        emit(enc_i(JALR, 3'b000, 0, 1, 12'd0));           // ret: jalr x0, x1, 0
        w_end = pcw;
        // patch the two forward jumps
        prog[idx_call] = enc_j(1, (21'(w_sub) - 21'(idx_call)) << 2);
        prog[idx_skip] = enc_j(0, (21'(w_end) - 21'(idx_skip)) << 2);

        // ---- segment G : long randomized ALU stream (forwarding stress) --
        rt = 0;
        for (ri = 0; ri < 300; ri = ri + 1) begin
            rt    = $random & 32'hF;                      // 0..15 op selector
            rd_r  = ($random % 30) + 1; if (rd_r < 1) rd_r = 1;   // 1..30
            rs1_r = $random % 32;                         // 0..31
            rs2_r = $random % 32;                         // 0..31
            rimm  = $random;                              // 12-bit immediate
            case (rt)
                0: emit(enc_r(REG, 3'b000, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // ADD
                1: emit(enc_r(REG, 3'b000, 7'b0100000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SUB
                2: emit(enc_r(REG, 3'b100, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // XOR
                3: emit(enc_r(REG, 3'b110, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // OR
                4: emit(enc_r(REG, 3'b111, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // AND
                5: emit(enc_r(REG, 3'b001, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SLL
                6: emit(enc_r(REG, 3'b101, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SRL
                7: emit(enc_r(REG, 3'b101, 7'b0100000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SRA
                8: emit(enc_r(REG, 3'b010, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SLT
                9: emit(enc_r(REG, 3'b011, 7'b0000000, rd_r[4:0], rs1_r[4:0], rs2_r[4:0])); // SLTU
               10: emit(enc_i(IMM, 3'b000, rd_r[4:0], rs1_r[4:0], rimm));                   // ADDI
               11: emit(enc_i(IMM, 3'b100, rd_r[4:0], rs1_r[4:0], rimm));                   // XORI
               12: emit(enc_i(IMM, 3'b110, rd_r[4:0], rs1_r[4:0], rimm));                   // ORI
               13: emit(enc_i(IMM, 3'b111, rd_r[4:0], rs1_r[4:0], rimm));                   // ANDI
               14: emit(enc_ish(3'b001, 7'b0000000, rd_r[4:0], rs1_r[4:0], rimm[4:0]));     // SLLI
               15: emit(enc_ish(3'b101, 7'b0100000, rd_r[4:0], rs1_r[4:0], rimm[4:0]));     // SRAI
            endcase
        end

        // ---- terminator : self-loop (halts forward progress) -------------
        emit(enc_j(0, 21'd0));                            // jal x0, 0  (spin)
    end
    endtask

    // ---------------------------------------------------------------------
    // Golden RV32I single-step: execute g_imem[g_pc] and check against commit
    // ---------------------------------------------------------------------
    function automatic [31:0] rrd(input [4:0] a);
        rrd = (a == 5'd0) ? 32'h0 : g_reg[a];
    endfunction

    task automatic chk(input cond, input [1023:0] msg);
    begin
        checks = checks + 1;
        if (!cond) begin
            errors = errors + 1;
            $display("  [MISMATCH #%0d] pc=%08h instr=%08h : %0s",
                     errors, g_pc, g_imem[(g_pc>>2) & (IMEMW-1)], msg);
        end
    end
    endtask

    task automatic golden_step;
        logic [31:0] iw, imm_i, imm_s, imm_b, imm_u, imm_j;
        logic [6:0]  opc; logic [2:0] f3; logic f7b5;
        logic [4:0]  rd, rs1, rs2;
        logic [31:0] a, b, res, addr, ld, npc, word;
        logic signed [31:0] sa;
        logic [1:0]  boff;
        logic        we_r, we_m, taken;
        logic [2:0]  ldst_f3;
    begin
        iw   = g_imem[(g_pc>>2) & (IMEMW-1)];
        opc  = iw[6:0];  rd = iw[11:7]; f3 = iw[14:12];
        rs1  = iw[19:15]; rs2 = iw[24:20]; f7b5 = iw[30];
        imm_i = {{20{iw[31]}}, iw[31:20]};
        imm_s = {{20{iw[31]}}, iw[31:25], iw[11:7]};
        imm_b = {{19{iw[31]}}, iw[31], iw[7], iw[30:25], iw[11:8], 1'b0};
        imm_u = {iw[31:12], 12'b0};
        imm_j = {{11{iw[31]}}, iw[31], iw[19:12], iw[20], iw[30:21], 1'b0};
        a = rrd(rs1); b = rrd(rs2); sa = a;
        we_r = 1'b0; we_m = 1'b0; res = 32'h0; addr = 32'h0; ld = 32'h0;
        npc = g_pc + 32'd4; taken = 1'b0; ldst_f3 = f3;

        case (opc)
          7'b0110111: begin res = imm_u;            we_r = 1'b1; end               // LUI
          7'b0010111: begin res = g_pc + imm_u;     we_r = 1'b1; end               // AUIPC
          7'b1101111: begin res = g_pc + 32'd4;     we_r = 1'b1; npc = g_pc + imm_j; end // JAL
          7'b1100111: begin res = g_pc + 32'd4;     we_r = 1'b1;                    // JALR
                            npc = (a + imm_i) & 32'hFFFF_FFFE; end
          7'b1100011: begin                                                        // BRANCH
                            case (f3)
                              3'b000: taken = (a == b);
                              3'b001: taken = (a != b);
                              3'b100: taken = ($signed(a) <  $signed(b));
                              3'b101: taken = ($signed(a) >= $signed(b));
                              3'b110: taken = (a <  b);
                              3'b111: taken = (a >= b);
                              default: taken = 1'b0;
                            endcase
                            if (taken) npc = g_pc + imm_b;
                      end
          7'b0000011: begin                                                        // LOADs
                            addr = a + imm_i; boff = addr[1:0];
                            word = g_mem[(addr>>2) & (DMEMW-1)];
                            case (f3)
                              3'b000: ld = {{24{word[8*boff+7]}}, word[8*boff +: 8]};   // LB
                              3'b001: ld = boff[1] ? {{16{word[31]}}, word[31:16]}
                                                   : {{16{word[15]}}, word[15:0]};      // LH
                              3'b010: ld = word;                                        // LW
                              3'b100: ld = {24'h0, word[8*boff +: 8]};                  // LBU
                              3'b101: ld = boff[1] ? {16'h0, word[31:16]}
                                                   : {16'h0, word[15:0]};               // LHU
                              default: ld = word;
                            endcase
                            res = ld; we_r = 1'b1;
                      end
          7'b0100011: begin                                                        // STOREs
                            addr = a + imm_s; we_m = 1'b1;
                      end
          7'b0010011: begin                                                        // OP-IMM
                            we_r = 1'b1;
                            case (f3)
                              3'b000: res = a + imm_i;                                   // ADDI
                              3'b010: res = ($signed(a) < $signed(imm_i)) ? 32'h1:32'h0; // SLTI
                              3'b011: res = (a < imm_i) ? 32'h1 : 32'h0;                 // SLTIU
                              3'b100: res = a ^ imm_i;                                   // XORI
                              3'b110: res = a | imm_i;                                   // ORI
                              3'b111: res = a & imm_i;                                   // ANDI
                              3'b001: res = a << imm_i[4:0];                             // SLLI
                              3'b101: begin                                             // SRAI/SRLI
                                        if (f7b5) res = sa >>> imm_i[4:0];
                                        else      res = a  >>  imm_i[4:0];
                                      end
                              default: res = a + imm_i;
                            endcase
                      end
          7'b0110011: begin                                                        // OP
                            we_r = 1'b1;
                            case (f3)
                              3'b000: res = f7b5 ? (a - b) : (a + b);                    // SUB/ADD
                              3'b001: res = a << b[4:0];                                 // SLL
                              3'b010: res = ($signed(a) < $signed(b)) ? 32'h1 : 32'h0;   // SLT
                              3'b011: res = (a < b) ? 32'h1 : 32'h0;                     // SLTU
                              3'b100: res = a ^ b;                                       // XOR
                              3'b101: begin                                             // SRA/SRL
                                        if (f7b5) res = sa >>> b[4:0];
                                        else      res = a  >>  b[4:0];
                                      end
                              3'b110: res = a | b;                                       // OR
                              3'b111: res = a & b;                                       // AND
                              default: res = a + b;
                            endcase
                      end
          default: ; // treated as NOP
        endcase

        if (rd == 5'd0) we_r = 1'b0;   // writes to x0 discarded

        // ---- checks vs the DUT commit -----------------------------------
        chk(commit_pc    === g_pc, "committed PC != ISS PC");
        chk(commit_instr === iw,   "committed encoding != program image");
        if (we_r) begin
            chk(commit_reg_we === 1'b1,      "expected a register write");
            chk(commit_rd     === rd,        "wrong destination register");
            chk(commit_wdata  === res,       "wrong writeback value");
        end else begin
            chk(commit_reg_we === 1'b0,      "unexpected register write");
        end
        if (we_m) begin
            chk(commit_mem_we    === 1'b1,   "expected a store");
            chk(commit_mem_addr  === addr,   "wrong store address");
            chk(commit_funct3    === ldst_f3,"wrong store width");
            chk(commit_mem_wdata === b,      "wrong store data");
        end else begin
            chk(commit_mem_we === 1'b0,      "unexpected store");
        end

        // ---- commit into the golden state -------------------------------
        if (we_r) g_reg[rd] <= res;
        if (we_m) begin
            boff = addr[1:0];
            case (f3)
              3'b000: g_mem[(addr>>2)&(DMEMW-1)][8*boff  +: 8]     <= b[7:0];     // SB
              3'b001: g_mem[(addr>>2)&(DMEMW-1)][16*boff[1] +: 16] <= b[15:0];    // SH
              default: g_mem[(addr>>2)&(DMEMW-1)]                  <= b;          // SW
            endcase
        end
        g_pc <= npc;
        retired = retired + 1;
    end
    endtask

    // ---------------------------------------------------------------------
    // Checker : sample the commit trace on the falling edge (stable), step ISS
    // ---------------------------------------------------------------------
    logic run = 1'b0;
    always @(negedge clk) begin
        if (run && commit_valid) golden_step;
    end

    // ---------------------------------------------------------------------
    // Stimulus / lifecycle
    // ---------------------------------------------------------------------
    integer i;
    localparam int MAX_CYCLES = 4000;

    initial begin
        $dumpfile("riscv_pipeline.vcd");
        $dumpvars(0, tb_riscv_pipeline);

        build_program;

        // load the program into DUT imem + golden imem; clear golden state
        for (i = 0; i < IMEMW; i = i + 1) begin
            dut.imem[i] = prog[i];
            g_imem[i]   = prog[i];
        end
        for (i = 0; i < DMEMW; i = i + 1) g_mem[i] = 32'h0;
        for (i = 0; i < 32;    i = i + 1) g_reg[i] = 32'h0;
        g_pc = 32'h0;

        // reset for a few cycles, then release and start checking
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        run   = 1'b1;

        // run until the golden model has retired well past the program end
        for (i = 0; i < MAX_CYCLES; i = i + 1) @(posedge clk);

        // ---- final full-state comparison (DUT vs golden) ----------------
        for (i = 1; i < 32; i = i + 1) begin
            checks = checks + 1;
            if (dut.regs[i] !== g_reg[i]) begin
                errors = errors + 1;
                $display("  [FINAL REG MISMATCH] x%0d dut=%08h gold=%08h",
                         i, dut.regs[i], g_reg[i]);
            end
        end
        for (i = 0; i < 64; i = i + 1) begin      // check the exercised dmem window
            checks = checks + 1;
            if (dut.dmem[i] !== g_mem[i]) begin
                errors = errors + 1;
                $display("  [FINAL MEM MISMATCH] word %0d dut=%08h gold=%08h",
                         i, dut.dmem[i], g_mem[i]);
            end
        end

        $display("--------------------------------------------------------");
        $display("Day 38  5-stage pipelined RV32I core");
        $display("  instructions retired : %0d", retired);
        $display("  checks performed     : %0d", checks);
        $display("  mismatches           : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $display("--------------------------------------------------------");
        $finish;
    end

    // global watchdog
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
