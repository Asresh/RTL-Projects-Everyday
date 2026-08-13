// -----------------------------------------------------------------------------
// Day 3 : spi_master
// -----------------------------------------------------------------------------
// A configurable, full-duplex SPI master controller.
//
//   * Supports all four SPI modes at run time via the cpol / cpha inputs.
//   * Programmable SCLK frequency through the clk_div input
//     (SCLK half-period = (clk_div + 1) system-clock cycles).
//   * Parameterized transfer width (DATA_WIDTH), MSB-first shifting.
//   * Simultaneously transmits tx_data on MOSI and captures rx_data from MISO.
//   * Single-bit chip-select (cs_n), a level 'busy' status and a one-cycle
//     'done' strobe when a transfer completes.
//
// The datapath is one shift register per direction; the control path is a small
// 3-state FSM plus a clock-divider that produces one "half-SCLK-period" tick.
// Every SCLK edge is numbered 0 .. 2*DATA_WIDTH-1; even edges are *leading*
// edges (idle -> active) and odd edges are *trailing* edges (active -> idle).
// The (cpol, cpha) pair only decides, per edge, whether the master samples MISO
// or shifts the next MOSI bit -- the classic SPI mode table:
//
//     cpha = 0 : sample on leading edge, shift on trailing edge
//     cpha = 1 : shift  on leading edge, sample on trailing edge
//
// cpol only sets the idle level of SCLK, so a "leading" edge is a rising edge
// when cpol = 0 and a falling edge when cpol = 1.
// -----------------------------------------------------------------------------

`default_nettype none

module spi_master #(
    parameter int DATA_WIDTH = 8,   // bits per transfer (>= 2)
    parameter int DIV_WIDTH  = 16   // width of the clk_div input
) (
    input  wire                    clk,       // system clock
    input  wire                    rst_n,     // active-low async reset

    // ---- configuration (latched at the start of a transfer) ----------------
    input  wire                    cpol,      // clock polarity  (idle SCLK level)
    input  wire                    cpha,      // clock phase
    input  wire [DIV_WIDTH-1:0]    clk_div,   // SCLK half-period = clk_div+1 clks

    // ---- control / data -----------------------------------------------------
    input  wire                    start,     // pulse high to launch a transfer
    input  wire [DATA_WIDTH-1:0]   tx_data,   // word to shift out (MSB first)
    output wire [DATA_WIDTH-1:0]   rx_data,   // word shifted in  (MSB first)
    output wire                    busy,      // high while a transfer is running
    output reg                     done,      // 1-cycle strobe at end of transfer

    // ---- SPI bus -------------------------------------------------------------
    output reg                     sclk,      // serial clock
    output wire                    mosi,      // master-out slave-in
    input  wire                    miso,      // master-in  slave-out
    output reg                     cs_n       // active-low chip select
);

    // Total number of SCLK edges in one word (two per bit).
    localparam int EDGES     = 2 * DATA_WIDTH;
    // Counter widths.
    localparam int EDGE_W    = $clog2(EDGES + 1);

    // ------------------------------------------------------------------ FSM ---
    typedef enum logic [1:0] {
        S_IDLE,      // waiting for 'start'
        S_XFER,      // shifting bits
        S_DONE       // one-cycle completion state
    } state_t;

    state_t                  state;

    // Latched configuration (frozen for the duration of a transfer).
    logic                    cpol_q;
    logic                    cpha_q;
    logic [DIV_WIDTH-1:0]    div_q;

    // Datapath.
    logic [DATA_WIDTH-1:0]   tx_shift;   // MOSI shift register (MSB = current bit)
    logic [DATA_WIDTH-1:0]   rx_shift;   // MISO capture register
    logic [DIV_WIDTH-1:0]    div_cnt;    // half-period counter
    logic [EDGE_W-1:0]       edge_cnt;   // 0 .. EDGES-1

    // A "tick" marks the boundary of one SCLK half-period.
    wire tick = (div_cnt == div_q);

    // MOSI is always the top bit of the transmit shift register.
    assign mosi    = tx_shift[DATA_WIDTH-1];
    assign rx_data = rx_shift;
    assign busy    = (state != S_IDLE);

    // On even (leading) edges SCLK leaves its idle level; edge_cnt[0] therefore
    // distinguishes leading (0) from trailing (1) edges.
    wire is_leading = ~edge_cnt[0];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            cpol_q   <= 1'b0;
            cpha_q   <= 1'b0;
            div_q    <= '0;
            tx_shift <= '0;
            rx_shift <= '0;
            div_cnt  <= '0;
            edge_cnt <= '0;
            sclk     <= 1'b0;
            cs_n     <= 1'b1;
            done     <= 1'b0;
        end else begin
            done <= 1'b0;   // default: 'done' is a single-cycle strobe

            case (state)
                // ---------------------------------------------------------- IDLE
                S_IDLE: begin
                    sclk     <= cpol;      // hold SCLK at the idle level
                    cs_n     <= 1'b1;
                    div_cnt  <= '0;
                    edge_cnt <= '0;
                    if (start) begin
                        // Latch configuration and prime the datapath.
                        cpol_q   <= cpol;
                        cpha_q   <= cpha;
                        div_q    <= clk_div;
                        tx_shift <= tx_data;   // MSB presented on MOSI right away
                        rx_shift <= '0;
                        sclk     <= cpol;      // idle level before first edge
                        cs_n     <= 1'b0;      // select the slave
                        state    <= S_XFER;
                    end
                end

                // ---------------------------------------------------------- XFER
                S_XFER: begin
                    if (tick) begin
                        div_cnt <= '0;
                        sclk    <= ~sclk;            // generate the SCLK edge
                        edge_cnt <= edge_cnt + 1'b1;

                        if (cpha_q == 1'b0) begin
                            // Mode 0/2: sample on leading, shift on trailing.
                            if (is_leading)
                                rx_shift <= {rx_shift[DATA_WIDTH-2:0], miso};
                            else
                                tx_shift <= {tx_shift[DATA_WIDTH-2:0], 1'b0};
                        end else begin
                            // Mode 1/3: shift on leading (except the very first
                            // edge, whose bit is already presented), sample on
                            // trailing.
                            if (is_leading) begin
                                if (edge_cnt != '0)
                                    tx_shift <= {tx_shift[DATA_WIDTH-2:0], 1'b0};
                            end else begin
                                rx_shift <= {rx_shift[DATA_WIDTH-2:0], miso};
                            end
                        end

                        // Last edge of the word -> finish.
                        if (edge_cnt == (EDGES - 1)) begin
                            sclk  <= cpol_q;   // return SCLK to its idle level
                            state <= S_DONE;
                        end
                    end else begin
                        div_cnt <= div_cnt + 1'b1;
                    end
                end

                // ---------------------------------------------------------- DONE
                S_DONE: begin
                    cs_n <= 1'b1;    // deselect the slave
                    done <= 1'b1;    // announce completion for one cycle
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
