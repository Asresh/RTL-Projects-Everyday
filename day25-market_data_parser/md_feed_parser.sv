`default_nettype none
`timescale 1ns/1ps
//============================================================================
// Day 25 : Cut-Through Streaming Market-Data Feed Parser
//          (NASDAQ ITCH-style Add / Execute / Cancel / Delete decoder)
//----------------------------------------------------------------------------
// Ultra-low-latency HFT feed-handler datapath. This is the very front door of
// the "tick-to-trade" path: raw exchange bytes arrive off the wire and must be
// turned into normalized, field-aligned market-data events *inline* on the
// FPGA, with DETERMINISTIC (jitter-free) latency -- not shipped to a CPU.
//
// The block ingests a length-framed byte stream (1 byte / clock) and emits a
// decoded event exactly ONE cycle after the final message byte, independent of
// message type or field values. It is "cut-through": fields are assembled on
// the fly as bytes land, so there is NO store-and-forward of the whole message
// and NO content-dependent stall -- worst-case latency == typical latency.
//
//   Wire protocol (simplified, faithful ITCH-style layout; big-endian fields)
//   ------------------------------------------------------------------------
//   Framing : [LEN][ body[0] .. body[LEN-1] ]   (LEN byte flagged by in_sop)
//             body[0] is always the message TYPE char.
//
//   'A' Add Order    (LEN=8): type refH refL side sharesH sharesL priceH priceL
//   'E' Order Exec   (LEN=5): type refH refL sharesH sharesL
//   'X' Order Cancel (LEN=5): type refH refL sharesH sharesL
//   'D' Order Delete (LEN=3): type refH refL
//
//   side byte: 'B' => buy/bid (ev_side=1), anything else => sell/ask (0)
//
// Any unknown type char, or a LEN that does not match the type's schema, still
// produces exactly one event with ev_error=1 (so a bad/garbled frame cannot
// wedge the parser -- it self-resynchronizes on the next in_sop). A new in_sop
// arriving mid-message aborts the in-flight message (dropped, no event) and
// re-frames -- exactly what a dropped-byte / gap-fill event must do on a feed.
//
// NOTE ON PARAMETERIZATION: a wire parser's field map is fixed by the exchange
// protocol, so the 16-bit ref/shares/price fields are protocol-constants, not
// knobs. The reusable, parameterizable ideas here are the *datapath technique*
// (cut-through assembly, deterministic 1-cycle emit, self-resync framing), not
// the byte offsets.
//============================================================================
module md_feed_parser (
    input  wire        clk,
    input  wire        rst,       // synchronous, active-high

    // ---- length-framed input byte stream (1 byte / clock) --------------
    input  wire        in_valid,  // a byte is present this cycle
    input  wire        in_sop,    // this byte is a message LENGTH byte
    input  wire [7:0]  in_data,   // the stream byte

    // ---- decoded, normalized market-data event -------------------------
    output reg         ev_valid,  // 1-cycle strobe: a message was decoded
    output reg  [7:0]  ev_type,   // raw type char ('A'/'E'/'X'/'D')
    output reg         ev_error,  // unknown type OR length/schema mismatch
    output reg  [15:0] ev_ref,    // order reference number
    output reg         ev_side,   // 1=buy/bid, 0=sell/ask   (Add only)
    output reg  [15:0] ev_shares, // shares  (Add=order qty, Exec/Cancel=qty)
    output reg  [15:0] ev_price   // price                    (Add only)
);

    // Message type characters
    localparam [7:0] T_ADD    = "A";
    localparam [7:0] T_EXEC   = "E";
    localparam [7:0] T_CANCEL = "X";
    localparam [7:0] T_DELETE = "D";
    localparam [7:0] SIDE_BUY = "B";

    // Expected total message length (body bytes incl. type) for a given type;
    // 0 => unknown type. Pure combinational schema table.
    function automatic [7:0] exp_len(input [7:0] t);
        case (t)
            T_ADD    : exp_len = 8'd8;
            T_EXEC   : exp_len = 8'd5;
            T_CANCEL : exp_len = 8'd5;
            T_DELETE : exp_len = 8'd3;
            default  : exp_len = 8'd0;
        endcase
    endfunction

    // Parse state
    reg        capturing;  // currently collecting a message body
    reg [7:0]  len_r;      // declared LEN of the current message
    reg [7:0]  rem;        // body bytes still expected (incl. current one)
    reg [7:0]  off;        // byte offset within message (0 == type byte)

    wire        is_body   = in_valid & ~in_sop & capturing;
    wire [7:0]  err_type  = (off == 8'd0) ? in_data : ev_type; // type of this msg

    always @(posedge clk) begin
        if (rst) begin
            ev_valid  <= 1'b0;
            ev_type   <= 8'd0;
            ev_error  <= 1'b0;
            ev_ref    <= 16'd0;
            ev_side   <= 1'b0;
            ev_shares <= 16'd0;
            ev_price  <= 16'd0;
            capturing <= 1'b0;
            len_r     <= 8'd0;
            rem       <= 8'd0;
            off       <= 8'd0;
        end else begin
            ev_valid <= 1'b0;   // default: ev_valid is a 1-cycle pulse

            if (in_valid && in_sop) begin
                // ---- LENGTH byte: (re)frame; drop any in-flight message ----
                len_r     <= in_data;
                rem       <= in_data;
                off       <= 8'd0;
                capturing <= (in_data != 8'd0);   // zero-length frame => no event
            end else if (is_body) begin
                // ---- BODY byte at position `off` : cut-through assembly -----
                if (off == 8'd0) begin
                    ev_type <= in_data;                    // message type
                end else begin
                    case (ev_type)
                        T_ADD: case (off)
                            8'd1: ev_ref   [15:8] <= in_data;
                            8'd2: ev_ref   [ 7:0] <= in_data;
                            8'd3: ev_side         <= (in_data == SIDE_BUY);
                            8'd4: ev_shares[15:8] <= in_data;
                            8'd5: ev_shares[ 7:0] <= in_data;
                            8'd6: ev_price [15:8] <= in_data;
                            8'd7: ev_price [ 7:0] <= in_data;
                            default: ;                     // (over-length) ignore
                        endcase
                        T_EXEC, T_CANCEL: case (off)
                            8'd1: ev_ref   [15:8] <= in_data;
                            8'd2: ev_ref   [ 7:0] <= in_data;
                            8'd3: ev_shares[15:8] <= in_data;
                            8'd4: ev_shares[ 7:0] <= in_data;
                            default: ;
                        endcase
                        T_DELETE: case (off)
                            8'd1: ev_ref   [15:8] <= in_data;
                            8'd2: ev_ref   [ 7:0] <= in_data;
                            default: ;
                        endcase
                        default: ;                         // unknown type: ignore
                    endcase
                end

                // ---- advance counters / detect completion ------------------
                if (rem == 8'd1) begin
                    // final byte of this message -> emit event next cycle.
                    // Deterministic: exactly 1 cycle, no content-dependent stall.
                    ev_valid  <= 1'b1;
                    ev_error  <= (exp_len(err_type) == 8'd0) ||
                                 (len_r != exp_len(err_type));
                    capturing <= 1'b0;

                    // Normalize fields that do not apply to this message type so
                    // the event bus is clean regardless of stale accumulators.
                    if (err_type != T_ADD) begin
                        ev_side  <= 1'b0;
                        ev_price <= 16'd0;
                    end
                    if (err_type == T_DELETE) begin
                        ev_shares <= 16'd0;
                    end
                end else begin
                    rem <= rem - 8'd1;
                    off <= off + 8'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
