//==============================================================================
// Module      : sync_fifo
// Description : Parameterized single-clock (synchronous) FIFO.
//               - Registered read: data appears one cycle after rd_en asserts
//                 while the FIFO is not empty.
//               - full / empty / count status flags.
//               - Works for any DEPTH (power-of-two or not) via explicit
//                 pointer wrap.
// Author      : Asresh Kuricheti
//==============================================================================
module sync_fifo #(
    parameter int DATA_WIDTH = 8,   // width of each data word
    parameter int DEPTH      = 16   // number of entries the FIFO can hold
) (
    input  logic                     clk,     // system clock
    input  logic                     rst_n,   // active-low asynchronous reset
    input  logic                     wr_en,   // write enable
    input  logic                     rd_en,   // read enable
    input  logic [DATA_WIDTH-1:0]    din,     // write data
    output logic [DATA_WIDTH-1:0]    dout,    // read data (registered)
    output logic                     full,    // asserted when FIFO is full
    output logic                     empty,   // asserted when FIFO is empty
    output logic [$clog2(DEPTH):0]   count    // number of valid entries
);

    localparam int ADDR_WIDTH = $clog2(DEPTH);

    // Storage and pointers
    logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    logic [ADDR_WIDTH-1:0] wr_ptr;
    logic [ADDR_WIDTH-1:0] rd_ptr;

    // Qualified enables: only act when there is room / data.
    wire do_write = wr_en && !full;
    wire do_read  = rd_en && !empty;

    //--------------------------------------------------------------------------
    // Write pointer + memory write
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (do_write) begin
            mem[wr_ptr] <= din;
            wr_ptr      <= (wr_ptr == ADDR_WIDTH'(DEPTH-1)) ? '0 : wr_ptr + 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Read pointer + registered read data
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= '0;
            dout   <= '0;
        end else if (do_read) begin
            dout   <= mem[rd_ptr];
            rd_ptr <= (rd_ptr == ADDR_WIDTH'(DEPTH-1)) ? '0 : rd_ptr + 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // Occupancy counter drives the full / empty flags
    //--------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count <= '0;
        end else begin
            unique case ({do_write, do_read})
                2'b10:   count <= count + 1'b1; // write only
                2'b01:   count <= count - 1'b1; // read only
                default: count <= count;        // simultaneous or idle
            endcase
        end
    end

    assign full  = (count == DEPTH[$clog2(DEPTH):0]);
    assign empty = (count == '0);

endmodule
