// ============================================================================
//  Day 10 — SECDED Hamming ECC Codec  (hamming_secded)
//
//  A parameterized Single-Error-Correcting, Double-Error-Detecting (SECDED)
//  Hamming code encoder/decoder — the exact class of ECC used to protect DRAM,
//  caches, register files, and on-chip SRAM against soft errors.
//
//  For the default DATA_WIDTH = 64 this realizes the classic (72,64) SECDED
//  code: 64 data bits + 7 Hamming parity bits + 1 overall parity bit = 72.
//
//  Construction (standard extended Hamming code):
//    * Codeword positions 1..M carry Hamming parity bits (the power-of-two
//      positions 1,2,4,8,...) interleaved with the data bits (all other
//      positions).  M = DATA_WIDTH + PBITS.
//    * A single overall parity bit (position 0) makes the whole codeword
//      even-parity, upgrading plain SEC Hamming to SECDED.
//
//  Decode decision (syndrome S over positions 1..M, overall parity P0):
//    S == 0 , P0 == 0  -> no error
//    P0 == 1           -> odd # of errors -> single, correctable
//                          (S != 0 : flip data/parity position S;
//                           S == 0 : the flipped bit was the overall bit)
//    S != 0 , P0 == 0  -> even # of errors -> DOUBLE error, uncorrectable
//
//  This file contains three modules:
//    hamming_secded_enc  - pure combinational encoder  (data  -> codeword)
//    hamming_secded_dec  - pure combinational decoder  (codeword -> data + flags)
//    hamming_secded      - 2-stage pipelined top wiring enc -> channel -> dec,
//                          with an err_inject XOR mask to model bit flips.
//
//  Clean, reset-safe, lint-friendly, and parameterized on DATA_WIDTH.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

// ----------------------------------------------------------------------------
//  Shared elaboration-time helpers
// ----------------------------------------------------------------------------
package hamming_pkg;
  // Smallest number of Hamming parity bits p such that 2^p >= DATA_WIDTH+p+1.
  function automatic int calc_pbits(input int dw);
    int p;
    begin
      p = 2;
      while ((1 << p) < (dw + p + 1)) p = p + 1;
      calc_pbits = p;
    end
  endfunction

  // Is k a power of two (k = 1,2,4,8,...) ?  Those positions hold parity bits.
  function automatic bit is_pow2(input int k);
    is_pow2 = (k != 0) && ((k & (k - 1)) == 0);
  endfunction
endpackage

// ----------------------------------------------------------------------------
//  Encoder : DATA_WIDTH data bits  ->  CW-bit codeword
//    codeword[0]     = overall (extended) parity bit
//    codeword[M:1]   = Hamming positions 1..M (data interleaved with parity)
// ----------------------------------------------------------------------------
module hamming_secded_enc #(
  parameter int DATA_WIDTH = 64
) (
  input  wire [DATA_WIDTH-1:0]                                       data_i,
  output wire [DATA_WIDTH + hamming_pkg::calc_pbits(DATA_WIDTH):0]   code_o
);
  import hamming_pkg::*;

  localparam int PBITS = calc_pbits(DATA_WIDTH);
  localparam int M     = DATA_WIDTH + PBITS;   // # positions 1..M
  localparam int CW    = M + 1;                // + overall parity at index 0

  // position 1..M (index 0 = overall parity)
  logic [CW-1:0] cw;

  integer k, j, di;
  logic   par;

  always_comb begin
    cw = '0;

    // 1) drop data bits into non-power-of-two positions, LSB-first
    di = 0;
    for (k = 1; k <= M; k = k + 1) begin
      if (!is_pow2(k)) begin
        cw[k] = data_i[di];
        di    = di + 1;
      end
    end

    // 2) each Hamming parity bit (position 2^j) = XOR of every data position
    //    whose index has bit j set.  (Other parity positions have only their
    //    own bit set, so they never enter this XOR.)
    for (j = 0; j < PBITS; j = j + 1) begin
      par = 1'b0;
      for (k = 1; k <= M; k = k + 1)
        if ((k != (1 << j)) && (((k >> j) & 1) == 1))
          par = par ^ cw[k];
      cw[1 << j] = par;
    end

    // 3) overall parity over positions 1..M makes the whole word even parity
    par = 1'b0;
    for (k = 1; k <= M; k = k + 1)
      par = par ^ cw[k];
    cw[0] = par;
  end

  assign code_o = cw;
endmodule

// ----------------------------------------------------------------------------
//  Decoder : CW-bit (possibly corrupted) codeword -> corrected data + flags
// ----------------------------------------------------------------------------
module hamming_secded_dec #(
  parameter int DATA_WIDTH = 64
) (
  input  wire [DATA_WIDTH + hamming_pkg::calc_pbits(DATA_WIDTH):0]   code_i,
  output wire [DATA_WIDTH-1:0]                                       data_o,
  output wire                                                        single_error_o, // corrected
  output wire                                                        double_error_o, // uncorrectable
  output wire                                                        error_o          // any error seen
);
  import hamming_pkg::*;

  localparam int PBITS = calc_pbits(DATA_WIDTH);
  localparam int M     = DATA_WIDTH + PBITS;
  localparam int CW    = M + 1;

  logic [CW-1:0]     cw;
  logic [PBITS-1:0]  syndrome;
  logic              overall;         // XOR of all CW bits
  logic [CW-1:0]     corrected;
  logic [DATA_WIDTH-1:0] data;

  integer k, j, di;
  logic   par;
  logic   single, dbl;

  always_comb begin
    cw = code_i;

    // syndrome bit j = parity check j over positions 1..M (incl. its own
    // parity position).  Zero for a clean codeword; equals the error position
    // for a single error within positions 1..M.
    for (j = 0; j < PBITS; j = j + 1) begin
      par = 1'b0;
      for (k = 1; k <= M; k = k + 1)
        if (((k >> j) & 1) == 1)
          par = par ^ cw[k];
      syndrome[j] = par;
    end

    // overall parity across the entire received codeword (positions 0..M)
    par = 1'b0;
    for (k = 0; k <= M; k = k + 1)
      par = par ^ cw[k];
    overall = par;

    // SECDED decision
    single = 1'b0;
    dbl    = 1'b0;
    corrected = cw;
    if (overall == 1'b1) begin
      // odd number of errors -> single, correctable
      single = 1'b1;
      if (syndrome != '0) begin
        if (syndrome <= M[PBITS-1:0])            // guard: valid position
          corrected[syndrome] = ~cw[syndrome];
      end
      // syndrome == 0 here means the overall parity bit itself flipped;
      // data is already correct, nothing to fix.
    end else begin
      // even parity: either no error (S==0) or a double error (S!=0)
      if (syndrome != '0)
        dbl = 1'b1;
    end

    // extract data bits back out of the non-power-of-two positions
    di = 0;
    data = '0;
    for (k = 1; k <= M; k = k + 1) begin
      if (!is_pow2(k)) begin
        data[di] = corrected[k];
        di       = di + 1;
      end
    end
  end

  assign data_o         = data;
  assign single_error_o = single;
  assign double_error_o = dbl;
  assign error_o        = single | dbl;
endmodule

// ----------------------------------------------------------------------------
//  Top : pipelined encode -> (channel with error injection) -> decode
//
//  Stage 1 : register the encoded, error-injected codeword + valid
//  Stage 2 : register the decoded data + status flags + valid
//  Latency : 2 clocks.  Throughput : 1 word/clock.
// ----------------------------------------------------------------------------
module hamming_secded #(
  parameter int DATA_WIDTH = 64
) (
  input  wire                                                     clk,
  input  wire                                                     rst_n,

  input  wire                                                     in_valid,
  input  wire [DATA_WIDTH-1:0]                                    data_i,
  // XOR mask applied to the codeword to model channel/soft-error bit flips
  input  wire [DATA_WIDTH + hamming_pkg::calc_pbits(DATA_WIDTH):0] err_inject,

  output reg                                                      out_valid,
  output reg  [DATA_WIDTH-1:0]                                    data_o,
  output reg                                                      single_error_o,
  output reg                                                      double_error_o,
  output reg                                                      error_o
);
  localparam int PBITS = hamming_pkg::calc_pbits(DATA_WIDTH);
  localparam int CW    = DATA_WIDTH + PBITS + 1;

  // ---- combinational encoder ----
  wire [CW-1:0] enc_code;
  hamming_secded_enc #(.DATA_WIDTH(DATA_WIDTH)) u_enc (
    .data_i (data_i),
    .code_o (enc_code)
  );

  // ---- stage 1 : capture corrupted codeword ----
  reg [CW-1:0] s1_code;
  reg          s1_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_code  <= '0;
      s1_valid <= 1'b0;
    end else begin
      s1_code  <= enc_code ^ err_inject;   // inject the bit flips here
      s1_valid <= in_valid;
    end
  end

  // ---- combinational decoder ----
  wire [DATA_WIDTH-1:0] dec_data;
  wire                  dec_single, dec_double, dec_error;
  hamming_secded_dec #(.DATA_WIDTH(DATA_WIDTH)) u_dec (
    .code_i         (s1_code),
    .data_o         (dec_data),
    .single_error_o (dec_single),
    .double_error_o (dec_double),
    .error_o        (dec_error)
  );

  // ---- stage 2 : register decoded results ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid      <= 1'b0;
      data_o         <= '0;
      single_error_o <= 1'b0;
      double_error_o <= 1'b0;
      error_o        <= 1'b0;
    end else begin
      out_valid      <= s1_valid;
      data_o         <= dec_data;
      single_error_o <= dec_single;
      double_error_o <= dec_double;
      error_o        <= dec_error;
    end
  end
endmodule

`default_nettype wire
