// =============================================================================
// crc32_parallel.sv
// -----------------------------------------------------------------------------
// Parameterized parallel (unrolled) CRC-32 engine — IEEE 802.3 / Ethernet FCS.
//
//   * Consumes DATA_WIDTH bits per clock (a "W-bit slice" of the frame),
//     the standard line-rate FPGA trick: instead of clocking the classic
//     bit-serial LFSR once per bit, the state-transition function is unrolled
//     DATA_WIDTH times at elaboration into a single combinational GF(2) block.
//     One 8-bit slice  -> 1 byte/clock   (~1 Gb/s @ 125 MHz)
//     One 32-bit slice -> 4 bytes/clock  (~10 GbE-class throughput)
//     One 64-bit slice -> 8 bytes/clock  (~25/40 GbE-class throughput)
//
//   * Algorithm: reflected CRC-32 (zlib / Ethernet FCS)
//         polynomial  0x04C11DB7  (reflected 0xEDB88320)
//         init        0xFFFFFFFF
//         reflect in  yes  (LSB-first)
//         reflect out yes
//         xor out     0xFFFFFFFF
//     "123456789" -> 0xCBF43926 (the canonical CRC-32/ISO-HDLC check value).
//
//   * Byte/bit ordering contract (matches Ethernet on the wire):
//       - within the DATA_WIDTH bus, bit 0 is processed first, bit W-1 last;
//       - a byte stream is packed byte0->data[7:0], byte1->data[15:8], ... so
//         processing bits 0..W-1 in order == byte0 LSB-first, then byte1, ...
//
//   Handshake:
//       init  : synchronous load of the 0xFFFFFFFF seed (start of a new frame)
//       en    : this beat carries a valid DATA_WIDTH-bit slice
//       last  : this beat is the final slice of the frame; one cycle later
//               result_o is registered and result_valid_o pulses high.
//
//   Fully synthesizable, reset-safe, lint-friendly, width-generic.
// =============================================================================
`default_nettype none

module crc32_parallel #(
    parameter int DATA_WIDTH = 32                 // bits consumed per clock
) (
    input  wire                    clk,
    input  wire                    rst_n,         // active-low synchronous reset

    input  wire                    init,          // load 0xFFFFFFFF seed
    input  wire                    en,            // valid data slice this cycle
    input  wire                    last,          // final slice of the frame
    input  wire [DATA_WIDTH-1:0]   data,          // input slice (bit0 first)

    output logic [31:0]            crc_o,         // live running CRC (post xor-out)
    output logic [31:0]            result_o,      // frame CRC, latched on `last`
    output logic                   result_valid_o // 1-cycle strobe after `last`
);

    // ---------------------------------------------------------------------
    // Reflected CRC-32 constants.
    // ---------------------------------------------------------------------
    localparam logic [31:0] SEED         = 32'hFFFF_FFFF;
    localparam logic [31:0] POLY_REFLECT = 32'hEDB8_8320;
    localparam logic [31:0] XOR_OUT      = 32'hFFFF_FFFF;

    // ---------------------------------------------------------------------
    // One bit-serial LFSR step (reflected form). This is the primitive that
    // the parallel engine unrolls DATA_WIDTH times.
    //     fb  = crc[0] ^ data_bit
    //     crc = (crc >> 1) ^ (fb ? POLY_REFLECT : 0)
    // ---------------------------------------------------------------------
    function automatic logic [31:0] crc_step (input logic [31:0] c,
                                              input logic        b);
        logic fb;
        begin
            fb       = c[0] ^ b;
            crc_step = (c >> 1) ^ (fb ? POLY_REFLECT : 32'h0);
        end
    endfunction

    // Unrolled next-state: apply crc_step for bit0..bit(W-1) in order.
    // The fixed-bound loop is fully unrolled at elaboration into a flat
    // combinational cone (the classic CRC "F/G matrix" logic).
    function automatic logic [31:0] crc_next (input logic [31:0]           c,
                                              input logic [DATA_WIDTH-1:0] d);
        logic [31:0] tmp;
        begin
            tmp = c;
            for (int i = 0; i < DATA_WIDTH; i++)
                tmp = crc_step(tmp, d[i]);
            crc_next = tmp;
        end
    endfunction

    // ---------------------------------------------------------------------
    // Running CRC state register.
    //
    // `cur_state` is the state this beat operates on: the fresh SEED when
    // `init` is asserted (start of frame), otherwise the accumulated crc_r.
    // Folding `init` into the combinational state makes the single-beat
    // frame (init & last in the same cycle) behave identically to a
    // multi-beat frame — the result path always sees a correctly-seeded CRC.
    // ---------------------------------------------------------------------
    logic [31:0] crc_r;
    logic [31:0] cur_state;
    logic [31:0] crc_comb;

    always_comb cur_state = init ? SEED : crc_r;
    always_comb crc_comb  = crc_next(cur_state, data);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            crc_r <= SEED;
        end else if (en) begin
            crc_r <= crc_comb;      // absorb this slice (crc_comb already seeded)
        end else if (init) begin
            crc_r <= SEED;          // seed only, no data this beat
        end
    end

    // Live CRC (with final reflect-out already applied by the reflected
    // formulation, so only the output XOR remains).
    assign crc_o = crc_r ^ XOR_OUT;

    // ---------------------------------------------------------------------
    // Output register stage: `last` closes the current frame and, one cycle
    // later, presents the finished CRC on result_o with a result_valid_o
    // strobe. The closing beat may or may not carry data:
    //     last & en   : this beat is the final data slice -> use crc_comb
    //     last & init  (en=0) : empty frame                -> use SEED
    //     last only   : close on the already-accumulated crc_r
    // In every case the running state has NOT yet been written back to crc_r,
    // so the result is computed from the pre-writeback value.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            result_o       <= 32'h0;
            result_valid_o <= 1'b0;
        end else begin
            result_valid_o <= last;
            if (last)
                result_o <= XOR_OUT ^ (en ? crc_comb : cur_state);
        end
    end

endmodule

`default_nettype wire
