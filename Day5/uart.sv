// -----------------------------------------------------------------------------
// Day 5 : uart  --  configurable full-duplex UART (TX + RX)
// -----------------------------------------------------------------------------
// A classic 8-N-1 UART (8 data bits, No parity, 1 stop bit), LSB-first, with a
// *run-time* programmable baud-rate divider.  The line is idle-high; a frame is
//
//     start(0) | d0 d1 d2 d3 d4 d5 d6 d7 (LSB-first) | stop(1)
//
// The design is split into two independent, self-contained blocks and a small
// full-duplex wrapper:
//
//   * uart_tx  -- shifts a byte out on `tx_serial` at the programmed baud rate,
//                 raising `tx_busy` for the whole frame and pulsing `tx_done`
//                 for one clock at the end of the stop bit.
//   * uart_rx  -- watches `rx_serial`, detects the start bit, samples each data
//                 bit at its *centre* (mid-bit sampling), and pulses `rx_valid`
//                 for one clock with the assembled byte on `rx_data`.  If the
//                 stop bit is not high it raises `rx_frame_err` alongside.
//   * uart     -- instantiates one TX and one RX so a single core is full-duplex
//                 (it can send and receive simultaneously).
//
// Baud rate is set by `clks_per_bit` = number of system-clock cycles per bit
// period.  Both blocks count `clks_per_bit` cycles per bit; the receiver first
// waits half a bit period after the start edge so that every subsequent sample
// lands in the middle of a bit cell.  `clks_per_bit` must be >= 2 (>= 4 for
// robust centre sampling); it is read continuously, so hold it stable while a
// frame is in flight.
// -----------------------------------------------------------------------------

`default_nettype none

// =============================================================================
// Transmitter
// =============================================================================
module uart_tx #(
    parameter int DATA_BITS = 8,
    parameter int DIV_WIDTH = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [DIV_WIDTH-1:0]  clks_per_bit, // system clocks per bit period
    input  wire                  tx_start,     // pulse high (while !tx_busy) to send
    input  wire [DATA_BITS-1:0]  tx_data,      // byte to transmit (LSB first)
    output reg                   tx_serial,    // serial line out (idle high)
    output wire                  tx_busy,      // high for the whole frame
    output reg                   tx_done       // one-cycle strobe at end of stop bit
);
    localparam int IDX_W = (DATA_BITS > 1) ? $clog2(DATA_BITS) : 1;

    typedef enum logic [1:0] {
        T_IDLE, T_START, T_DATA, T_STOP
    } tstate_t;

    tstate_t                 state;
    logic [DIV_WIDTH-1:0]    clk_cnt;
    logic [IDX_W-1:0]        bit_idx;
    logic [DATA_BITS-1:0]    shreg;

    assign tx_busy = (state != T_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= T_IDLE;
            tx_serial <= 1'b1;      // idle high
            tx_done   <= 1'b0;
            clk_cnt   <= '0;
            bit_idx   <= '0;
            shreg     <= '0;
        end else begin
            tx_done <= 1'b0;        // default: single-cycle strobe

            case (state)
                // ---------------------------------------------------------- IDLE
                T_IDLE: begin
                    tx_serial <= 1'b1;
                    clk_cnt   <= '0;
                    bit_idx   <= '0;
                    if (tx_start) begin
                        shreg <= tx_data;   // latch the byte
                        state <= T_START;
                    end
                end

                // ------------------------------------------------------ START BIT
                T_START: begin
                    tx_serial <= 1'b0;      // drive start bit low
                    if (clk_cnt < clks_per_bit - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt <= '0;
                        state   <= T_DATA;
                    end
                end

                // ------------------------------------------------------ DATA BITS
                T_DATA: begin
                    tx_serial <= shreg[bit_idx];   // LSB-first
                    if (clk_cnt < clks_per_bit - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt <= '0;
                        if (bit_idx < DATA_BITS - 1) begin
                            bit_idx <= bit_idx + 1'b1;
                        end else begin
                            bit_idx <= '0;
                            state   <= T_STOP;
                        end
                    end
                end

                // ------------------------------------------------------- STOP BIT
                T_STOP: begin
                    tx_serial <= 1'b1;      // stop bit high
                    if (clk_cnt < clks_per_bit - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt <= '0;
                        tx_done <= 1'b1;    // announce completion
                        state   <= T_IDLE;
                    end
                end

                default: state <= T_IDLE;
            endcase
        end
    end
endmodule

// =============================================================================
// Receiver
// =============================================================================
module uart_rx #(
    parameter int DATA_BITS = 8,
    parameter int DIV_WIDTH = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [DIV_WIDTH-1:0]  clks_per_bit,
    input  wire                  rx_serial,    // serial line in (idle high)
    output reg  [DATA_BITS-1:0]  rx_data,      // assembled byte (valid with rx_valid)
    output reg                   rx_valid,     // one-cycle strobe when a byte arrives
    output reg                   rx_frame_err  // stop bit was not high (with rx_valid)
);
    localparam int IDX_W = (DATA_BITS > 1) ? $clog2(DATA_BITS) : 1;

    typedef enum logic [1:0] {
        R_IDLE, R_START, R_DATA, R_STOP
    } rstate_t;

    rstate_t                 state;
    logic [DIV_WIDTH-1:0]    clk_cnt;
    logic [IDX_W-1:0]        bit_idx;
    logic [DATA_BITS-1:0]    shreg;

    // Two-flop synchronizer on the incoming serial line (good practice even in
    // loopback; resolves metastability when RX is fed from another clock domain).
    logic [1:0] rx_sync;
    wire  rx_in = rx_sync[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_sync <= 2'b11;   // idle high
        else        rx_sync <= {rx_sync[0], rx_serial};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= R_IDLE;
            clk_cnt      <= '0;
            bit_idx      <= '0;
            shreg        <= '0;
            rx_data      <= '0;
            rx_valid     <= 1'b0;
            rx_frame_err <= 1'b0;
        end else begin
            rx_valid <= 1'b0;   // default: single-cycle strobe

            case (state)
                // ---------------------------------------------------------- IDLE
                R_IDLE: begin
                    clk_cnt <= '0;
                    bit_idx <= '0;
                    if (rx_in == 1'b0)      // falling edge => start bit
                        state <= R_START;
                end

                // --------------------------------------------- confirm start bit
                R_START: begin
                    // sample at the middle of the start bit
                    if (clk_cnt == (clks_per_bit - 1) >> 1) begin
                        if (rx_in == 1'b0) begin
                            clk_cnt <= '0;      // re-centre: now at mid-start-bit
                            bit_idx <= '0;
                            state   <= R_DATA;
                        end else begin
                            state <= R_IDLE;    // false start (glitch)
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // ------------------------------------------------------ DATA BITS
                R_DATA: begin
                    // one full bit period after mid-start lands at mid-bit-0, etc.
                    if (clk_cnt < clks_per_bit - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt        <= '0;
                        shreg[bit_idx] <= rx_in;    // sample at bit centre, LSB-first
                        if (bit_idx < DATA_BITS - 1) begin
                            bit_idx <= bit_idx + 1'b1;
                        end else begin
                            bit_idx <= '0;
                            state   <= R_STOP;
                        end
                    end
                end

                // ------------------------------------------------------- STOP BIT
                R_STOP: begin
                    if (clk_cnt < clks_per_bit - 1) begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end else begin
                        clk_cnt      <= '0;
                        rx_data      <= shreg;
                        rx_frame_err <= ~rx_in;   // stop bit must be high
                        rx_valid     <= 1'b1;     // announce the byte
                        state        <= R_IDLE;
                    end
                end

                default: state <= R_IDLE;
            endcase
        end
    end
endmodule

// =============================================================================
// Full-duplex wrapper
// =============================================================================
module uart #(
    parameter int DATA_BITS = 8,
    parameter int DIV_WIDTH = 16
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [DIV_WIDTH-1:0]  clks_per_bit,

    // ---- transmit side ------------------------------------------------------
    input  wire                  tx_start,
    input  wire [DATA_BITS-1:0]  tx_data,
    output wire                  tx_serial,
    output wire                  tx_busy,
    output wire                  tx_done,

    // ---- receive side -------------------------------------------------------
    input  wire                  rx_serial,
    output wire [DATA_BITS-1:0]  rx_data,
    output wire                  rx_valid,
    output wire                  rx_frame_err
);
    uart_tx #(.DATA_BITS(DATA_BITS), .DIV_WIDTH(DIV_WIDTH)) u_tx (
        .clk          (clk),
        .rst_n        (rst_n),
        .clks_per_bit (clks_per_bit),
        .tx_start     (tx_start),
        .tx_data      (tx_data),
        .tx_serial    (tx_serial),
        .tx_busy      (tx_busy),
        .tx_done      (tx_done)
    );

    uart_rx #(.DATA_BITS(DATA_BITS), .DIV_WIDTH(DIV_WIDTH)) u_rx (
        .clk          (clk),
        .rst_n        (rst_n),
        .clks_per_bit (clks_per_bit),
        .rx_serial    (rx_serial),
        .rx_data      (rx_data),
        .rx_valid     (rx_valid),
        .rx_frame_err (rx_frame_err)
    );
endmodule

`default_nettype wire
