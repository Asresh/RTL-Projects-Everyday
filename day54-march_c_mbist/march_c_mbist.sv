// Author: Asresh Kuricheti
// Day 54 - March C- SRAM memory built-in self-test controller
// Executes {down(w0), up(r0,w1), up(r1,w0), down(r0,w1),
//           down(r1,w0), down(r0)} against a synchronous-read SRAM port.

`timescale 1ns/1ps

module march_c_mbist #(
    parameter int ADDR_WIDTH = 6,
    parameter int DATA_WIDTH = 32,
    parameter int DEPTH      = 1 << ADDR_WIDTH
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  start_i,
    output logic                  busy_o,
    output logic                  done_o,
    output logic                  fail_o,
    output logic [ADDR_WIDTH-1:0] fail_addr_o,
    output logic [DATA_WIDTH-1:0] fail_expected_o,
    output logic [DATA_WIDTH-1:0] fail_actual_o,
    output logic [2:0]            phase_o,
    output logic                  mem_en_o,
    output logic                  mem_we_o,
    output logic [ADDR_WIDTH-1:0] mem_addr_o,
    output logic [DATA_WIDTH-1:0] mem_wdata_o,
    input  logic [DATA_WIDTH-1:0] mem_rdata_i
);

  typedef enum logic [3:0] {
    IDLE, W0_DN, R0_UP_RD, R0_UP_CHK, W1_UP,
    R1_UP_RD, R1_UP_CHK, W0_UP,
    R0_DN_RD, R0_DN_CHK, W1_DN,
    R1_DN_RD, R1_DN_CHK, W0_DN_2,
    R0_DN_FINAL_RD, R0_DN_FINAL_CHK
  } state_t;

  state_t state_q;
  logic [ADDR_WIDTH-1:0] addr_q;
  localparam logic [ADDR_WIDTH-1:0] LAST_ADDR = ADDR_WIDTH'(DEPTH-1);

  initial begin
    if (DEPTH < 2 || DEPTH > (1 << ADDR_WIDTH))
      $error("DEPTH must be in [2, 2**ADDR_WIDTH]");
  end

  always_comb begin
    mem_en_o    = 1'b0;
    mem_we_o    = 1'b0;
    mem_addr_o  = addr_q;
    mem_wdata_o = '0;
    phase_o     = 3'd0;
    case (state_q)
      W0_DN: begin
        mem_en_o = 1'b1; mem_we_o = 1'b1; phase_o = 3'd0;
      end
      R0_UP_RD: begin
        mem_en_o = 1'b1; phase_o = 3'd1;
      end
      R0_UP_CHK: phase_o = 3'd1;
      W1_UP: begin
        mem_en_o = 1'b1; mem_we_o = 1'b1;
        mem_wdata_o = '1; phase_o = 3'd1;
      end
      R1_UP_RD: begin
        mem_en_o = 1'b1; phase_o = 3'd2;
      end
      R1_UP_CHK: phase_o = 3'd2;
      W0_UP: begin
        mem_en_o = 1'b1; mem_we_o = 1'b1; phase_o = 3'd2;
      end
      R0_DN_RD: begin
        mem_en_o = 1'b1; phase_o = 3'd3;
      end
      R0_DN_CHK: phase_o = 3'd3;
      W1_DN: begin
        mem_en_o = 1'b1; mem_we_o = 1'b1;
        mem_wdata_o = '1; phase_o = 3'd3;
      end
      R1_DN_RD: begin
        mem_en_o = 1'b1; phase_o = 3'd4;
      end
      R1_DN_CHK: phase_o = 3'd4;
      W0_DN_2: begin
        mem_en_o = 1'b1; mem_we_o = 1'b1; phase_o = 3'd4;
      end
      R0_DN_FINAL_RD: begin
        mem_en_o = 1'b1; phase_o = 3'd5;
      end
      R0_DN_FINAL_CHK: phase_o = 3'd5;
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q         <= IDLE;
      addr_q          <= '0;
      busy_o          <= 1'b0;
      done_o          <= 1'b0;
      fail_o          <= 1'b0;
      fail_addr_o     <= '0;
      fail_expected_o <= '0;
      fail_actual_o   <= '0;
    end else begin
      done_o <= 1'b0;
      case (state_q)
        IDLE: if (start_i) begin
          state_q         <= W0_DN;
          addr_q          <= LAST_ADDR;
          busy_o          <= 1'b1;
          fail_o          <= 1'b0;
          fail_addr_o     <= '0;
          fail_expected_o <= '0;
          fail_actual_o   <= '0;
        end
        W0_DN: if (addr_q == '0) begin
          addr_q <= '0; state_q <= R0_UP_RD;
        end else addr_q <= addr_q - 1'b1;
        R0_UP_RD: state_q <= R0_UP_CHK;
        R0_UP_CHK: begin
          if ((mem_rdata_i !== '0) && !fail_o) begin
            fail_o <= 1'b1; fail_addr_o <= addr_q;
            fail_expected_o <= '0; fail_actual_o <= mem_rdata_i;
          end
          state_q <= W1_UP;
        end
        W1_UP: if (addr_q == LAST_ADDR) begin
          addr_q <= '0; state_q <= R1_UP_RD;
        end else begin addr_q <= addr_q + 1'b1; state_q <= R0_UP_RD; end
        R1_UP_RD: state_q <= R1_UP_CHK;
        R1_UP_CHK: begin
          if ((mem_rdata_i !== {DATA_WIDTH{1'b1}}) && !fail_o) begin
            fail_o <= 1'b1; fail_addr_o <= addr_q;
            fail_expected_o <= '1; fail_actual_o <= mem_rdata_i;
          end
          state_q <= W0_UP;
        end
        W0_UP: if (addr_q == LAST_ADDR) begin
          addr_q <= LAST_ADDR; state_q <= R0_DN_RD;
        end else begin addr_q <= addr_q + 1'b1; state_q <= R1_UP_RD; end
        R0_DN_RD: state_q <= R0_DN_CHK;
        R0_DN_CHK: begin
          if ((mem_rdata_i !== '0) && !fail_o) begin
            fail_o <= 1'b1; fail_addr_o <= addr_q;
            fail_expected_o <= '0; fail_actual_o <= mem_rdata_i;
          end
          state_q <= W1_DN;
        end
        W1_DN: if (addr_q == '0) begin
          addr_q <= LAST_ADDR; state_q <= R1_DN_RD;
        end else begin addr_q <= addr_q - 1'b1; state_q <= R0_DN_RD; end
        R1_DN_RD: state_q <= R1_DN_CHK;
        R1_DN_CHK: begin
          if ((mem_rdata_i !== {DATA_WIDTH{1'b1}}) && !fail_o) begin
            fail_o <= 1'b1; fail_addr_o <= addr_q;
            fail_expected_o <= '1; fail_actual_o <= mem_rdata_i;
          end
          state_q <= W0_DN_2;
        end
        W0_DN_2: if (addr_q == '0) begin
          addr_q <= LAST_ADDR; state_q <= R0_DN_FINAL_RD;
        end else begin addr_q <= addr_q - 1'b1; state_q <= R1_DN_RD; end
        R0_DN_FINAL_RD: state_q <= R0_DN_FINAL_CHK;
        R0_DN_FINAL_CHK: begin
          if ((mem_rdata_i !== '0) && !fail_o) begin
            fail_o <= 1'b1; fail_addr_o <= addr_q;
            fail_expected_o <= '0; fail_actual_o <= mem_rdata_i;
          end
          if (addr_q == '0) begin
            state_q <= IDLE; busy_o <= 1'b0; done_o <= 1'b1;
          end else begin addr_q <= addr_q - 1'b1; state_q <= R0_DN_FINAL_RD; end
        end
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
