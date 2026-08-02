// =============================================================================
// Day 35 : 8b/10b Line Encoder (Widmer / Franaszek, ANSI X3.230 / IEEE 802.3-36)
// -----------------------------------------------------------------------------
// The physical-coding-sublayer (PCS) workhorse that sits between the byte-domain
// logic and the SerDes of PCIe Gen1/2, SATA, 1000BASE-X Gigabit Ethernet, USB 3.0
// (Gen1), DisplayPort, Fibre Channel and DVI/HDMI TMDS-adjacent links. It maps
// each 8-bit character (plus a 1-bit control flag K) to a 10-bit line code that is
//   * DC-balanced      -- the number of 1s and 0s stays bounded, so the serial
//                         stream carries no long-term DC bias (AC-coupling / PLL
//                         friendly); the encoder tracks a 1-bit RUNNING DISPARITY
//                         and picks the code variant that pulls the balance back,
//   * transition-rich  -- guaranteed <= 5 consecutive identical bits, giving the
//                         receiver CDR enough edges to recover the clock, and
//   * comma-alignable  -- the control codes (K.28.1/.5/.7) embed the unique 7-bit
//                         "comma" 0011111 / 1100000 that appears in no other code
//                         position, letting the deserializer find byte boundaries.
//
// THE STANDOUT is how compact the datapath is. 8b/10b splits the byte into a
// 5b/6b and a 3b/4b sub-block, each of which has TWO line representations chosen
// by the current running disparity. Naively that is two full code tables. But
// every RD+ codeword is exactly the BITWISE COMPLEMENT of its RD- partner -- for
// BOTH the disparity-neutral codes (which stay balanced) AND the disparity-+/-2
// codes (which flip the balance). So this core stores ONLY the RD- column
//   emit = (running_disparity == NEG) ? code_minus : ~code_minus
// and the running disparity simply flips whenever a sub-block is non-neutral
//   rd_next = neutral ? rd : ~rd
// -- one 6-bit table, one 4-bit table, two XOR cones, two 1-bit flips. No 20-Kbit
// dual ROM, no adders in the disparity path.
//
// CORRECTNESS SUBTLETIES handled:
//   * K.28 remaps the 5b/6b sub-block to the special comma code 001111 (its RD-
//     form) instead of D.28's 001110, so the comma pattern only ever appears in
//     control codes -- the property that makes byte alignment unambiguous.
//   * Dx.A7 alternate 3b/4b encoding: the primary D.x.7 code (1110/0001) is
//     replaced by the alternate (0111/1000) exactly when RD=-1 & x in {17,18,20}
//     or RD=+1 & x in {11,13,14}. This is the ONE rule that prevents a run of
//     five bits in one sub-block abutting a same-polarity run in the neighbour,
//     which would otherwise produce six identical bits and break the 5-run limit.
//     All control (.7) codes always use the alternate form.
//   * Invalid control requests (K asserted for anything other than K.28.x or
//     K.{23,27,29,30}.7) raise code_err_o and are not emitted as a valid code.
//
// Registered outputs => the byte->line latency is a deterministic single clock,
// independent of the data (no data-dependent timing). Output bit order: code_o[9]
// is 'a' (first on the wire, MSB-first), code_o[0] is 'j'.
//
// STRICT: no vendor primitives, latch-free, `default_nettype none`.
// =============================================================================
`timescale 1ns/1ps
`default_nettype none

module encoder_8b10b (
    input  wire        clk,
    input  wire        rst_n,       // active-low synchronous reset
    input  wire        valid_i,     // present a character this cycle
    input  wire [7:0]  data_i,      // HGF EDCBA  (data_i[4:0]=x=EDCBA, data_i[7:5]=y=HGF)
    input  wire        k_i,         // 1 => control (K) character, 0 => data (D)
    output reg  [9:0]  code_o,      // 10-bit line code, code_o[9]='a' first on wire
    output reg         valid_o,     // code_o holds a fresh encoded character
    output reg         rd_o,        // running disparity AFTER this character (0=RD-1, 1=RD+1)
    output reg         code_err_o   // set when valid_i & k_i requested an illegal control code
);
    // running-disparity encoding: 1'b0 == RD-1 (negative), 1'b1 == RD+1 (positive)
    localparam bit NEG = 1'b0;
    localparam bit POS = 1'b1;

    reg rd_r;   // current running disparity state (persists between characters)

    // ------------------------------------------------------------------ tables
    // 5b/6b RD- column {a,b,c,d,e,i}, indexed by x = data_i[4:0].
    function automatic [5:0] map6 (input [4:0] x);
        case (x)
            5'd0 : map6 = 6'b100111;  5'd1 : map6 = 6'b011101;
            5'd2 : map6 = 6'b101101;  5'd3 : map6 = 6'b110001;
            5'd4 : map6 = 6'b110101;  5'd5 : map6 = 6'b101001;
            5'd6 : map6 = 6'b011001;  5'd7 : map6 = 6'b111000;
            5'd8 : map6 = 6'b111001;  5'd9 : map6 = 6'b100101;
            5'd10: map6 = 6'b010101;  5'd11: map6 = 6'b110100;
            5'd12: map6 = 6'b001101;  5'd13: map6 = 6'b101100;
            5'd14: map6 = 6'b011100;  5'd15: map6 = 6'b010111;
            5'd16: map6 = 6'b011011;  5'd17: map6 = 6'b100011;
            5'd18: map6 = 6'b010011;  5'd19: map6 = 6'b110010;
            5'd20: map6 = 6'b001011;  5'd21: map6 = 6'b101010;
            5'd22: map6 = 6'b011010;  5'd23: map6 = 6'b111010;
            5'd24: map6 = 6'b110011;  5'd25: map6 = 6'b100110;
            5'd26: map6 = 6'b010110;  5'd27: map6 = 6'b110110;
            5'd28: map6 = 6'b001110;  5'd29: map6 = 6'b101110;
            5'd30: map6 = 6'b011110;  5'd31: map6 = 6'b101011;
        endcase
    endfunction

    // 3b/4b RD- column {f,g,h,j}, indexed by y = data_i[7:5]; y==7 is the PRIMARY
    // D.x.7 form (alternate handled separately).
    function automatic [3:0] map4 (input [2:0] y);
        case (y)
            3'd0: map4 = 4'b1011;  3'd1: map4 = 4'b0110;
            3'd2: map4 = 4'b1010;  3'd3: map4 = 4'b1100;
            3'd4: map4 = 4'b1101;  3'd5: map4 = 4'b0101;
            3'd6: map4 = 4'b1001;  3'd7: map4 = 4'b1110;
        endcase
    endfunction

    localparam [5:0] K28_6B = 6'b001111;  // K.28 special 5b/6b (RD- form): the comma root
    localparam [3:0] D7_ALT = 4'b0111;     // Dx.A7 alternate 3b/4b (RD- form)

    // -------------------------------------------------------- combinational core
    reg  [4:0] x;
    reg  [2:0] y;
    reg  [5:0] cm6;      // 6b RD- (code-minus) after K.28 remap
    reg  [3:0] cm4;      // 4b RD- (code-minus) after A7 remap
    reg  [5:0] e6;       // emitted 6b
    reg  [3:0] e4;       // emitted 4b
    reg        rd6;      // running disparity between the two sub-blocks
    reg        rd_next;  // running disparity after the whole character
    reg        alt7;     // use Dx.A7 alternate 3b/4b
    reg        k_ok;     // requested control code is legal
    reg        neutral6, neutral4;

    always @* begin
        x = data_i[4:0];
        y = data_i[7:5];

        // legal control codes: K.28.y (any y) and K.{23,27,29,30}.7
        k_ok = (x == 5'd28) ||
               ((x == 5'd23 || x == 5'd27 || x == 5'd29 || x == 5'd30) && (y == 3'd7));

        // ---- 5b/6b sub-block (K.28 remaps the code, disparity computed from it)
        cm6      = (k_i && x == 5'd28) ? K28_6B : map6(x);
        neutral6 = ($countones(cm6) == 3);                 // 3 ones => disparity-neutral
        e6       = (rd_r == NEG) ? cm6 : ~cm6;             // uniform-complement select
        rd6      = neutral6 ? rd_r : ~rd_r;                 // flip only on non-neutral

        // ---- 3b/4b sub-block (A7 alternate; all K .7 codes use the alternate)
        alt7 = (y == 3'd7) &&
               ( k_i ||
                 (rd_r == NEG && (x == 5'd17 || x == 5'd18 || x == 5'd20)) ||
                 (rd_r == POS && (x == 5'd11 || x == 5'd13 || x == 5'd14)) );
        cm4      = (y == 3'd7) ? (alt7 ? D7_ALT : map4(3'd7)) : map4(y);
        neutral4 = ($countones(cm4) == 2);                 // 2 ones => disparity-neutral
        e4       = (rd6 == NEG) ? cm4 : ~cm4;
        rd_next  = neutral4 ? rd6 : ~rd6;
    end

    // --------------------------------------------------------- registered output
    always @(posedge clk) begin
        if (!rst_n) begin
            code_o     <= 10'd0;
            valid_o    <= 1'b0;
            rd_o       <= NEG;
            code_err_o <= 1'b0;
            rd_r       <= NEG;                              // spec initial RD = -1
        end else begin
            valid_o    <= valid_i;
            code_err_o <= valid_i && k_i && !k_ok;
            if (valid_i) begin
                code_o <= {e6, e4};                        // {a..i , f..j}, code_o[9]='a'
                rd_o   <= rd_next;
                rd_r   <= rd_next;                         // commit running disparity
            end
            // when idle (no valid_i) code_o / rd_r hold their last value
        end
    end
endmodule

`default_nettype wire
