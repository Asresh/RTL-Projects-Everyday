// ---------------------------------------------------------------------------
// Day 29 : Cut-Through Order-Entry Egress Serializer (wire encoder)
// ---------------------------------------------------------------------------
// The LAST hop of the HFT tick-to-trade path. After the pre-trade risk gate
// (Day 26) accepts a child order, *something* has to turn the parallel order
// descriptor {token, side, price, shares, symbol} into the exchange's binary
// order-entry wire message and shove it out one byte per clock onto the SerDes
// / MAC egress lane. This is the inverse of Day 25's feed parser (ingress
// deserializer). It is where "tick-to-trade" literally becomes "trade".
//
// Why it matters for ultra-low latency:
//   * CUT-THROUGH assembly: the message is built and its checksum computed the
//     same cycle the descriptor is accepted, so emission starts on the very
//     next clock -- no store-and-forward, no content-dependent stall. The frame
//     is fixed length, so worst-case latency == typical latency (the metric
//     that wins in HFT).
//   * REGISTERED, backpressure-safe egress: outputs feed a proper 2-slot SKID
//     BUFFER, so the valid/last/data bus is fully registered (short combinational
//     path => high fmax on the FPGA) AND it can absorb a downstream `m_ready`
//     stall for one cycle WITHOUT dropping or duplicating a byte and WITHOUT
//     losing 1-byte/clock throughput once ready returns.
//   * Deterministic framing: `m_last` marks the final (checksum) byte; a running
//     8-bit XOR checksum trailer lets the exchange gateway catch line errors.
//
// Wire message (fixed, big-endian) -- a simplified OUCH-style "Enter Order":
//   byte  0     : message type   (MSG_TYPE, default 'O')
//   bytes 1..4  : order token    (TOKEN_W = 32b)
//   byte  5     : side           ('B'=buy when side_i=0, 'S'=sell when side_i=1)
//   bytes 6..9  : price          (PRICE_W = 32b)
//   bytes 10..13: shares         (QTY_W   = 32b)
//   bytes 14..15: symbol id      (SYM_W   = 16b)
//   byte  16    : checksum       = XOR of bytes 0..15
//   => TOTAL_BYTES = 17 (BODY_BYTES = 16 + 1 checksum)
//
// Handshake:
//   in_valid / in_ready : accept one parallel descriptor when idle.
//   m_valid / m_ready / m_data / m_last : AXI-Stream-like byte egress.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module oe_egress_serializer #(
    parameter int          TOKEN_W  = 32,
    parameter int          PRICE_W  = 32,
    parameter int          QTY_W    = 32,
    parameter int          SYM_W    = 16,
    parameter logic [7:0]  MSG_TYPE = 8'h4F,   // 'O'  (Enter Order)
    parameter logic [7:0]  SIDE_BUY = 8'h42,   // 'B'
    parameter logic [7:0]  SIDE_SELL= 8'h53    // 'S'
)(
    input  wire                 clk,
    input  wire                 rst,        // synchronous, active-high

    // ---- parallel order descriptor (from the risk gate) -------------------
    input  wire                 in_valid,
    output wire                 in_ready,
    input  wire [TOKEN_W-1:0]   token_i,
    input  wire                 side_i,     // 0 = buy, 1 = sell
    input  wire [PRICE_W-1:0]   price_i,
    input  wire [QTY_W-1:0]     shares_i,
    input  wire [SYM_W-1:0]     symbol_i,

    // ---- serialized byte egress (registered, backpressure-safe) -----------
    output wire                 m_valid,
    input  wire                 m_ready,
    output wire [7:0]           m_data,
    output wire                 m_last
);

    // -----------------------------------------------------------------------
    // Byte-layout constants (all bytes fixed => deterministic latency)
    // -----------------------------------------------------------------------
    localparam int BODY_BYTES  = 1                 // type
                               + (TOKEN_W/8)       // token
                               + 1                 // side
                               + (PRICE_W/8)       // price
                               + (QTY_W/8)         // shares
                               + (SYM_W/8);        // symbol
    localparam int TOTAL_BYTES = BODY_BYTES + 1;   // + checksum trailer
    localparam int MSG_BITS    = TOTAL_BYTES*8;
    localparam int IDX_W       = $clog2(TOTAL_BYTES);

    // -----------------------------------------------------------------------
    // Combinational message assembly (cut-through): build the full big-endian
    // body from the *live* inputs, compute the XOR checksum, pack the frame.
    // Registered into msg_r only on the accepting edge.
    // -----------------------------------------------------------------------
    logic [7:0] body   [BODY_BYTES];
    logic [7:0] csum_c;
    integer     bi;

    always_comb begin
        // Assemble body bytes, most-significant field-byte first (big-endian).
        integer p;
        body[0] = MSG_TYPE;
        p = 1;
        // token (TOKEN_W/8 bytes, MSB first)
        for (int k = 0; k < TOKEN_W/8; k++)
            body[p+k] = token_i[(TOKEN_W-8) - 8*k +: 8];
        p = p + TOKEN_W/8;
        // side
        body[p] = side_i ? SIDE_SELL : SIDE_BUY;
        p = p + 1;
        // price
        for (int k = 0; k < PRICE_W/8; k++)
            body[p+k] = price_i[(PRICE_W-8) - 8*k +: 8];
        p = p + PRICE_W/8;
        // shares
        for (int k = 0; k < QTY_W/8; k++)
            body[p+k] = shares_i[(QTY_W-8) - 8*k +: 8];
        p = p + QTY_W/8;
        // symbol
        for (int k = 0; k < SYM_W/8; k++)
            body[p+k] = symbol_i[(SYM_W-8) - 8*k +: 8];

        // running 8-bit XOR checksum over the whole body
        csum_c = 8'h00;
        for (bi = 0; bi < BODY_BYTES; bi++)
            csum_c = csum_c ^ body[bi];
    end

    // Pack {body, checksum} into one big-endian vector, byte 0 in the MSBs so
    // that byte index j selects msg[(TOTAL_BYTES-1-j)*8 +: 8] (first byte first).
    logic [MSG_BITS-1:0] asm_msg;
    always_comb begin
        for (int j = 0; j < BODY_BYTES; j++)
            asm_msg[(TOTAL_BYTES-1-j)*8 +: 8] = body[j];
        asm_msg[0 +: 8] = csum_c;              // checksum is the last byte
    end

    // -----------------------------------------------------------------------
    // Serializer FSM : latch frame on accept, emit one byte/clock into the skid
    // buffer whenever the skid can accept (sk_in_ready).
    // -----------------------------------------------------------------------
    logic                 busy;
    logic [MSG_BITS-1:0]  msg_r;
    logic [IDX_W-1:0]     idx;                 // next byte to emit

    wire sk_in_ready;                          // skid buffer can accept a byte
    wire accept = in_valid && in_ready;

    // producer-side stream into the skid buffer
    wire        p_valid = busy;
    wire [7:0]  p_data  = msg_r[(TOTAL_BYTES-1-idx)*8 +: 8];
    wire        p_last  = (idx == IDX_W'(TOTAL_BYTES-1));
    wire        p_fire  = p_valid && sk_in_ready;   // a byte is handed off

    assign in_ready = !busy;                   // accept a new order only when idle

    always_ff @(posedge clk) begin
        if (rst) begin
            busy  <= 1'b0;
            idx   <= '0;
            msg_r <= '0;
        end else begin
            if (accept) begin
                // cut-through: capture the fully assembled + checksummed frame
                busy  <= 1'b1;
                idx   <= '0;
                msg_r <= asm_msg;
            end else if (p_fire) begin
                if (p_last) busy <= 1'b0;      // last byte handed off -> idle
                else        idx  <= idx + 1'b1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // 2-slot skid buffer : registered outputs, sustains 1 byte/clock through a
    // downstream stall without drop/dup. (EMPTY / BUSY / FULL micro-FSM.)
    // -----------------------------------------------------------------------
    localparam logic [1:0] SK_EMPTY = 2'd0,
                           SK_BUSY  = 2'd1,   // main slot valid, skid empty
                           SK_FULL  = 2'd2;   // main + skid both valid

    logic [1:0] sk_state;
    logic [7:0] main_d, skid_d;
    logic       main_l, skid_l;

    assign sk_in_ready = (sk_state != SK_FULL);   // accept unless both slots full
    assign m_valid     = (sk_state != SK_EMPTY);
    assign m_data      = main_d;
    assign m_last      = main_l;

    wire sk_out_fire = m_valid && m_ready;

    always_ff @(posedge clk) begin
        if (rst) begin
            sk_state <= SK_EMPTY;
            main_d   <= 8'h00; main_l <= 1'b0;
            skid_d   <= 8'h00; skid_l <= 1'b0;
        end else begin
            unique case (sk_state)
                SK_EMPTY: begin
                    if (p_fire) begin
                        main_d <= p_data; main_l <= p_last;
                        sk_state <= SK_BUSY;
                    end
                end
                SK_BUSY: begin
                    case ({p_fire, sk_out_fire})
                        2'b11: begin                     // in and out same cycle
                            main_d <= p_data; main_l <= p_last;
                        end
                        2'b10: begin                     // in only -> fill skid
                            skid_d <= p_data; skid_l <= p_last;
                            sk_state <= SK_FULL;
                        end
                        2'b01: begin                     // out only -> drain
                            sk_state <= SK_EMPTY;
                        end
                        default: ;                       // hold
                    endcase
                end
                SK_FULL: begin
                    if (sk_out_fire) begin               // drain main <- skid
                        main_d <= skid_d; main_l <= skid_l;
                        sk_state <= SK_BUSY;
                    end
                end
                default: sk_state <= SK_EMPTY;
            endcase
        end
    end

`ifdef FORMAL_ASSERT
    // sanity: skid never accepts when full
    always @(posedge clk) if (!rst)
        assert (!(sk_state == SK_FULL && p_fire));
`endif

endmodule

`default_nettype wire
