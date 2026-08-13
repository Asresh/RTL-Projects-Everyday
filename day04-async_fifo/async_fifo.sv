// -----------------------------------------------------------------------------
// Day 4 - async_fifo
// Dual-clock (asynchronous) FIFO with Gray-code pointer clock-domain crossing.
//
// A FIFO whose write and read ports live in *independent* clock domains. The
// hard part is not the storage - it is passing the write/read pointers safely
// across the clock boundary so that the full/empty flags are always correct and
// never glitch. The classic solution (Clifford Cummings, SNUG 2002) is used:
//
//   * pointers are kept in binary (for addressing/arithmetic) AND in Gray code
//     (for crossing the clock boundary) - Gray code changes exactly one bit per
//     increment, so a value sampled mid-transition is always either the old or
//     the new pointer, never a corrupt in-between code.
//   * each pointer is passed to the other domain through a two-flop
//     synchronizer to resolve metastability.
//   * FULL and EMPTY are computed locally in each domain from the local pointer
//     and the synchronized remote pointer.
//
// The design is split into small, individually reviewable modules and is fully
// parameterized, reset-safe (independent async resets per domain) and
// lint-clean (`default_nettype none`, no latches, no unused nets).
// -----------------------------------------------------------------------------
`default_nettype none

// -----------------------------------------------------------------------------
// Two-flop synchronizer for a bus (used to carry a Gray-coded pointer across a
// clock domain boundary). Gray coding guarantees at most one bit is unsettled.
// -----------------------------------------------------------------------------
module sync_ff #(
    parameter int WIDTH = 4
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [WIDTH-1:0]  d,
    output reg  [WIDTH-1:0]  q
);
    reg [WIDTH-1:0] q1;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q1 <= '0;
            q  <= '0;
        end else begin
            q1 <= d;    // first capture flop (may go metastable)
            q  <= q1;   // second flop - output is settled
        end
    end
endmodule

// -----------------------------------------------------------------------------
// Dual-port memory: synchronous write (wclk), asynchronous/combinational read.
// Reading the word currently addressed by the read pointer is standard for a
// show-ahead FIFO - the data is valid whenever the FIFO is not empty.
// -----------------------------------------------------------------------------
module fifo_mem #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 4
) (
    input  wire                   wclk,
    input  wire                   wen,        // write enable (write & !full)
    input  wire [ADDR_WIDTH-1:0]  waddr,
    input  wire [DATA_WIDTH-1:0]  wdata,
    input  wire [ADDR_WIDTH-1:0]  raddr,
    output wire [DATA_WIDTH-1:0]  rdata
);
    localparam int DEPTH = 1 << ADDR_WIDTH;
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    always_ff @(posedge wclk) begin
        if (wen) mem[waddr] <= wdata;
    end

    assign rdata = mem[raddr];  // combinational (show-ahead) read
endmodule

// -----------------------------------------------------------------------------
// Write-pointer + FULL generation (lives in the write clock domain).
//
// FULL is asserted when the next write Gray pointer would equal the read Gray
// pointer with its top two bits inverted - i.e. the write side has wrapped one
// extra time and caught up to the read side.
// -----------------------------------------------------------------------------
module wptr_full #(
    parameter int ADDR_WIDTH = 4
) (
    input  wire                   wclk,
    input  wire                   wrst_n,
    input  wire                   winc,        // write request
    input  wire [ADDR_WIDTH:0]    wq2_rptr,    // read Gray ptr, synced into wclk
    output reg  [ADDR_WIDTH:0]    wptr,         // write Gray pointer (to reader)
    output wire [ADDR_WIDTH-1:0]  waddr,        // memory write address (binary)
    output reg                    wfull
);
    reg  [ADDR_WIDTH:0] wbin;
    wire [ADDR_WIDTH:0] wbin_next  = wbin + {{ADDR_WIDTH{1'b0}}, (winc & ~wfull)};
    wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;  // bin -> Gray

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= '0;
            wptr <= '0;
        end else begin
            wbin <= wbin_next;
            wptr <= wgray_next;
        end
    end

    assign waddr = wbin[ADDR_WIDTH-1:0];

    // full when next write Gray ptr == read Gray ptr with top two bits flipped
    wire wfull_val = (wgray_next ==
                      {~wq2_rptr[ADDR_WIDTH:ADDR_WIDTH-1],
                        wq2_rptr[ADDR_WIDTH-2:0]});

    always_ff @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) wfull <= 1'b0;
        else         wfull <= wfull_val;
    end
endmodule

// -----------------------------------------------------------------------------
// Read-pointer + EMPTY generation (lives in the read clock domain).
//
// EMPTY is asserted when the next read Gray pointer equals the (synchronized)
// write Gray pointer - the read side has consumed everything the write side has
// produced.
// -----------------------------------------------------------------------------
module rptr_empty #(
    parameter int ADDR_WIDTH = 4
) (
    input  wire                   rclk,
    input  wire                   rrst_n,
    input  wire                   rinc,        // read request
    input  wire [ADDR_WIDTH:0]    rq2_wptr,    // write Gray ptr, synced into rclk
    output reg  [ADDR_WIDTH:0]    rptr,         // read Gray pointer (to writer)
    output wire [ADDR_WIDTH-1:0]  raddr,        // memory read address (binary)
    output reg                    rempty
);
    reg  [ADDR_WIDTH:0] rbin;
    wire [ADDR_WIDTH:0] rbin_next  = rbin + {{ADDR_WIDTH{1'b0}}, (rinc & ~rempty)};
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;  // bin -> Gray

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= '0;
            rptr <= '0;
        end else begin
            rbin <= rbin_next;
            rptr <= rgray_next;
        end
    end

    assign raddr = rbin[ADDR_WIDTH-1:0];

    // empty when next read Gray ptr has caught up to the synced write Gray ptr
    wire rempty_val = (rgray_next == rq2_wptr);

    always_ff @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) rempty <= 1'b1;   // reset -> empty
        else         rempty <= rempty_val;
    end
endmodule

// -----------------------------------------------------------------------------
// Top level: wires the four blocks together with the two pointer synchronizers.
// -----------------------------------------------------------------------------
module async_fifo #(
    parameter int DATA_WIDTH = 8,
    parameter int ADDR_WIDTH = 4          // depth = 2**ADDR_WIDTH
) (
    // write clock domain
    input  wire                   wclk,
    input  wire                   wrst_n,
    input  wire                   wr_en,
    input  wire [DATA_WIDTH-1:0]  wdata,
    output wire                   wfull,
    // read clock domain
    input  wire                   rclk,
    input  wire                   rrst_n,
    input  wire                   rd_en,
    output wire [DATA_WIDTH-1:0]  rdata,
    output wire                   rempty
);
    wire [ADDR_WIDTH:0]   wptr, rptr;          // Gray pointers
    wire [ADDR_WIDTH:0]   wq2_rptr, rq2_wptr;  // cross-domain synchronized copies
    wire [ADDR_WIDTH-1:0] waddr, raddr;

    // read Gray pointer -> write clock domain
    sync_ff #(.WIDTH(ADDR_WIDTH+1)) sync_r2w (
        .clk(wclk), .rst_n(wrst_n), .d(rptr), .q(wq2_rptr));

    // write Gray pointer -> read clock domain
    sync_ff #(.WIDTH(ADDR_WIDTH+1)) sync_w2r (
        .clk(rclk), .rst_n(rrst_n), .d(wptr), .q(rq2_wptr));

    wptr_full #(.ADDR_WIDTH(ADDR_WIDTH)) u_wptr (
        .wclk(wclk), .wrst_n(wrst_n), .winc(wr_en),
        .wq2_rptr(wq2_rptr), .wptr(wptr), .waddr(waddr), .wfull(wfull));

    rptr_empty #(.ADDR_WIDTH(ADDR_WIDTH)) u_rptr (
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rd_en),
        .rq2_wptr(rq2_wptr), .rptr(rptr), .raddr(raddr), .rempty(rempty));

    fifo_mem #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) u_mem (
        .wclk(wclk), .wen(wr_en & ~wfull), .waddr(waddr), .wdata(wdata),
        .raddr(raddr), .rdata(rdata));
endmodule

`default_nettype wire
