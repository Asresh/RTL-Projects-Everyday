// -----------------------------------------------------------------------------
// Day 7 : axi4lite_regs  --  AXI4-Lite slave register block
// -----------------------------------------------------------------------------
// A complete AXI4-Lite *slave* fronting a small internal register file.  It
// implements all five AXI4-Lite channels with proper VALID/READY handshakes,
// honours the write byte strobes (WSTRB), and returns OKAY / SLVERR responses.
//
//   Channels:  AW (write address), W (write data + WSTRB), B (write response),
//              AR (read address),  R (read data + response).
//
//   The slave carries a single outstanding transaction per direction (the usual
//   lightweight AXI4-Lite style): it accepts an address+data pair, performs the
//   access, then drives the response until the master accepts it.
//
// Register map (DATA_WIDTH = 32, NUM_REGS = 8, byte addresses, word-aligned):
//
//   offset  name   type   reset        behaviour
//   ------  -----  -----   ----------   ------------------------------------------
//   0x00    REG0   RW      0x00000000   general read/write scratch
//   0x04    REG1   RW      0x00000000   general read/write scratch
//   0x08    REG2   RW      0x00000000   general read/write scratch
//   0x0C    REG3   RO      -            read-only ID, reads 0xDEADBEEF, writes ignored
//   0x10    REG4   RW      0x00000000   general read/write scratch
//   0x14    REG5   W1C     0xA5A5A5A5   write-1-to-clear status (per strobed byte)
//   0x18    REG6   RW      0x00000000   general read/write scratch
//   0x1C    REG7   RW      0x00000000   general read/write scratch
//
//   Any address at/above NUM_REGS*4 (here 0x20) is unmapped and returns SLVERR
//   on both read and write (read data = 0).  Writes to the RO register are
//   accepted with an OKAY response but have no effect.  WSTRB masks writes at
//   byte granularity for the RW and W1C registers.
// -----------------------------------------------------------------------------

`default_nettype none

module axi4lite_regs #(
    parameter int ADDR_WIDTH = 8,          // byte-address width
    parameter int DATA_WIDTH = 32,         // must be 32 for classic AXI4-Lite
    parameter int NUM_REGS   = 8           // number of word registers (power of 2)
) (
    input  wire                     clk,
    input  wire                     rst_n,      // active-low async reset

    // ---- AW: write address channel -----------------------------------------
    input  wire [ADDR_WIDTH-1:0]    awaddr,
    input  wire                     awvalid,
    output wire                     awready,

    // ---- W: write data channel ---------------------------------------------
    input  wire [DATA_WIDTH-1:0]    wdata,
    input  wire [DATA_WIDTH/8-1:0]  wstrb,
    input  wire                     wvalid,
    output wire                     wready,

    // ---- B: write response channel -----------------------------------------
    output reg  [1:0]               bresp,
    output reg                      bvalid,
    input  wire                     bready,

    // ---- AR: read address channel ------------------------------------------
    input  wire [ADDR_WIDTH-1:0]    araddr,
    input  wire                     arvalid,
    output wire                     arready,

    // ---- R: read data channel ----------------------------------------------
    output reg  [DATA_WIDTH-1:0]    rdata,
    output reg  [1:0]               rresp,
    output reg                      rvalid,
    input  wire                     rready
);
    // ---- AXI response codes -------------------------------------------------
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    // ---- register map constants ---------------------------------------------
    localparam int REG_SEL_W = $clog2(NUM_REGS);
    localparam int RO_IDX    = 3;                 // read-only register index
    localparam int W1C_IDX   = 5;                 // write-1-to-clear index
    localparam logic [DATA_WIDTH-1:0] RO_CONST  = 32'hDEAD_BEEF;
    localparam logic [DATA_WIDTH-1:0] W1C_RESET = 32'hA5A5_A5A5;

    localparam int NBYTES = DATA_WIDTH/8;

    // ---- storage ------------------------------------------------------------
    reg [DATA_WIDTH-1:0] regfile [0:NUM_REGS-1];

    integer i;

    // =========================================================================
    // Byte-strobe helpers
    // =========================================================================
    // Replace the strobed bytes of `oldv` with those of `neww` (normal RW).
    function automatic [DATA_WIDTH-1:0] apply_strb(
            input [DATA_WIDTH-1:0] oldv,
            input [DATA_WIDTH-1:0] neww,
            input [NBYTES-1:0]     strb);
        integer b;
        begin
            apply_strb = oldv;
            for (b = 0; b < NBYTES; b = b + 1)
                if (strb[b]) apply_strb[8*b +: 8] = neww[8*b +: 8];
        end
    endfunction

    // Write-1-to-clear: on strobed bytes, clear any bit written as 1.
    function automatic [DATA_WIDTH-1:0] apply_w1c(
            input [DATA_WIDTH-1:0] oldv,
            input [DATA_WIDTH-1:0] neww,
            input [NBYTES-1:0]     strb);
        integer b;
        begin
            apply_w1c = oldv;
            for (b = 0; b < NBYTES; b = b + 1)
                if (strb[b]) apply_w1c[8*b +: 8] = oldv[8*b +: 8] & ~neww[8*b +: 8];
        end
    endfunction

    // =========================================================================
    // Write channels (AW + W -> commit -> B)
    // =========================================================================
    reg                    aw_seen, w_seen;
    reg [ADDR_WIDTH-1:0]   awaddr_q;
    reg [DATA_WIDTH-1:0]   wdata_q;
    reg [NBYTES-1:0]       wstrb_q;

    // Accept AW / W while we are not already holding one and no response pending.
    assign awready = ~aw_seen & ~bvalid;
    assign wready  = ~w_seen  & ~bvalid;

    wire aw_hs = awvalid & awready;
    wire w_hs  = wvalid  & wready;

    // decode of the latched write address
    wire [REG_SEL_W-1:0] w_sel    = awaddr_q[2 +: REG_SEL_W];
    wire                 w_mapped = (awaddr_q < (NUM_REGS << 2));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_seen  <= 1'b0;
            w_seen   <= 1'b0;
            awaddr_q <= '0;
            wdata_q  <= '0;
            wstrb_q  <= '0;
            bvalid   <= 1'b0;
            bresp    <= RESP_OKAY;
            for (i = 0; i < NUM_REGS; i = i + 1)
                regfile[i] <= (i == W1C_IDX) ? W1C_RESET : '0;
        end else begin
            // collect the address and data beats (may arrive in either order)
            if (aw_hs) begin aw_seen <= 1'b1; awaddr_q <= awaddr; end
            if (w_hs)  begin w_seen  <= 1'b1; wdata_q  <= wdata; wstrb_q <= wstrb; end

            // commit once both beats are in and no response is pending
            if (aw_seen & w_seen & ~bvalid) begin
                if (w_mapped) begin
                    case (w_sel)
                        RO_IDX[REG_SEL_W-1:0]:  /* read-only: ignore write */ ;
                        W1C_IDX[REG_SEL_W-1:0]:
                            regfile[W1C_IDX] <= apply_w1c(regfile[W1C_IDX],
                                                          wdata_q, wstrb_q);
                        default:
                            regfile[w_sel]   <= apply_strb(regfile[w_sel],
                                                           wdata_q, wstrb_q);
                    endcase
                    bresp <= RESP_OKAY;
                end else begin
                    bresp <= RESP_SLVERR;       // unmapped address
                end
                bvalid  <= 1'b1;
                aw_seen <= 1'b0;
                w_seen  <= 1'b0;
            end

            // response accepted by the master
            if (bvalid & bready)
                bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // Read channels (AR -> R)
    // =========================================================================
    assign arready = ~rvalid;                    // accept a read when R is free
    wire ar_hs = arvalid & arready;

    // decode of the live read address at the AR handshake
    wire [REG_SEL_W-1:0] ar_sel    = araddr[2 +: REG_SEL_W];
    wire                 ar_mapped = (araddr < (NUM_REGS << 2));
    wire [DATA_WIDTH-1:0] ar_rdata =
             ~ar_mapped              ? '0        :
             (ar_sel == RO_IDX[REG_SEL_W-1:0]) ? RO_CONST :
                                       regfile[ar_sel];
    wire [1:0] ar_rresp = ar_mapped ? RESP_OKAY : RESP_SLVERR;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rvalid <= 1'b0;
            rdata  <= '0;
            rresp  <= RESP_OKAY;
        end else begin
            if (ar_hs) begin
                rdata  <= ar_rdata;
                rresp  <= ar_rresp;
                rvalid <= 1'b1;
            end else if (rvalid & rready) begin
                rvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
