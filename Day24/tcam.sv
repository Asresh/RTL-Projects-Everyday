// ---------------------------------------------------------------------------
// tcam.sv -- Pipelined Ternary Content-Addressable Memory (TCAM) lookup engine
//
// A parameterized hardware TCAM: DEPTH entries, each a KEY_WIDTH-bit ternary
// pattern {value, care-mask} plus a valid bit. On a search the incoming key is
// compared against ALL entries in parallel; an entry matches iff every "care"
// bit agrees:
//
//     match[i] = valid[i] && ( ((skey ^ key[i]) & mask[i]) == 0 )
//
// mask[i][b] = 1 -> bit b is a "care" bit (must match)
// mask[i][b] = 0 -> bit b is a "don't-care" (wildcard, matches 0 or 1)
//
// The DEPTH match lines are priority-encoded so the LOWEST index wins, giving a
// single winning index. This is the workhorse of:
//   * line-rate networking  -- ACLs, flow tables, and (with prefix masks)
//     longest-prefix-match routing / policy classification in NICs & switches;
//   * FPGA-for-finance / HFT -- constant-latency symbol -> internal-id lookup,
//     order/quote tag matching, and rule-based feed classification where every
//     lookup must return in a fixed number of cycles at line rate.
//
// Datapath: the parallel ternary compare cone + priority encoder are purely
// combinational from the live search key against the registered entry array;
// the winner (hit / index / stored key / full match bitmap) is registered once,
// giving a deterministic 1-cycle search latency (occupancy-independent).
//
// Fully synchronous, active-high synchronous reset, lint-friendly, parameterized.
// ---------------------------------------------------------------------------
`default_nettype none

module tcam #(
    parameter int DEPTH     = 16,          // number of TCAM entries
    parameter int KEY_WIDTH = 32,          // ternary key width in bits
    // derived ---------------------------------------------------------------
    parameter int IDXW      = (DEPTH > 1) ? $clog2(DEPTH) : 1
) (
    input  wire                     clk,
    input  wire                     rst,      // synchronous, active-high

    // ---- write / configure port (one entry per cycle) --------------------
    input  wire                     we,       // write-enable strobe
    input  wire [IDXW-1:0]          waddr,    // entry to write
    input  wire [KEY_WIDTH-1:0]     wkey,     // stored value bits
    input  wire [KEY_WIDTH-1:0]     wmask,    // care mask (1=care, 0=wildcard)
    input  wire                     wvalid,   // entry valid bit (0 = invalidate)

    // ---- search / lookup port --------------------------------------------
    input  wire                     search,   // search-request strobe
    input  wire [KEY_WIDTH-1:0]     skey,     // key to look up

    // ---- registered result (valid 1 cycle after `search`) ----------------
    output logic                    match_valid_o, // a search result is present
    output logic                    match_o,       // at least one entry matched
    output logic [IDXW-1:0]         match_index_o, // winning (lowest) index
    output logic [KEY_WIDTH-1:0]    match_key_o,   // stored value of the winner
    output logic [DEPTH-1:0]        hit_map_o      // full parallel match bitmap
);

    // ---- entry storage ----------------------------------------------------
    logic [KEY_WIDTH-1:0] key  [DEPTH];
    logic [KEY_WIDTH-1:0] mask [DEPTH];
    logic [DEPTH-1:0]     valid;

    // ---- parallel ternary compare cone (combinational) --------------------
    // raw_match[i] is high when entry i is valid AND every care bit agrees.
    logic [DEPTH-1:0] raw_match;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            raw_match[i] = valid[i] &&
                           ( ((skey ^ key[i]) & mask[i]) == '0 );
        end
    end

    // ---- priority encoder: lowest matching index wins ---------------------
    logic             any_match;
    logic [IDXW-1:0]  win_index;
    always_comb begin
        any_match = 1'b0;
        win_index = '0;
        for (int i = DEPTH-1; i >= 0; i--) begin
            if (raw_match[i]) begin
                any_match = 1'b1;
                win_index = i[IDXW-1:0];   // last write (i==0) sticks -> lowest
            end
        end
    end

    // ---- write / reset / registered result --------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            valid         <= '0;
            match_valid_o <= 1'b0;
            match_o       <= 1'b0;
            match_index_o <= '0;
            match_key_o   <= '0;
            hit_map_o     <= '0;
        end else begin
            // configure port (nonblocking -> visible to NEXT cycle's search)
            if (we) begin
                key[waddr]   <= wkey;
                mask[waddr]  <= wmask;
                valid[waddr] <= wvalid;
            end

            // search result register (1-cycle latency)
            match_valid_o <= search;
            if (search) begin
                match_o       <= any_match;
                match_index_o <= win_index;
                match_key_o   <= key[win_index];
                hit_map_o     <= raw_match;
            end
        end
    end

`ifndef SYNTHESIS
    // sanity: winning index must be a real hit whenever match_o is asserted
    always_ff @(posedge clk) begin
        if (!rst && match_valid_o && match_o) begin
            assert (hit_map_o[match_index_o])
              else $error("tcam: match_index_o=%0d not set in hit_map_o=%b",
                          match_index_o, hit_map_o);
        end
    end
`endif

endmodule

`default_nettype wire
