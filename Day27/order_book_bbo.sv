// ============================================================================
// Day 27 : Direct-Mapped L2 Limit Order Book + BBO (Best-Bid/Offer) Engine
// ----------------------------------------------------------------------------
// The compute heart of the HFT tick-to-trade path. Day 25's feed parser turns
// exchange bytes into normalized market-data events (Add / Reduce). Those
// events must be folded into a *live order book*, and the single pair of
// numbers every strategy reads on every tick is the BBO — the best (highest)
// resting bid price and the best (lowest) resting ask price, with their sizes.
//
// A software book keeps price levels in a balanced tree / skip-list / heap and
// walks it to find the top of book: O(log N) pointer chases whose latency
// depends on tree shape and cache state -> jitter. This block instead holds the
// book as a *direct-mapped array indexed by price level* and recomputes the BBO
// **combinationally over ALL levels every single cycle** via a parallel
// priority encoder (a balanced reduction tree in silicon). The result is
// registered exactly one clock after the event that changed it:
//
//     ULL lesson: BBO latency is CONSTANT and OCCUPANCY-INDEPENDENT.
//     A book with 1 level and a book with LEVELS levels both resolve in the
//     SAME single clock. Worst-case == typical -> the flat tail HFT lives on.
//
// Datapath (all combinational, then registered):
//   event -> saturating add/sub at book[level]  (next-state book)
//         -> occupied bitmap (qty != 0 per level)
//         -> best bid  = priority-encode occupied bids from the TOP  (highest px)
//            best ask  = priority-encode occupied asks from the BOTTOM (lowest px)
//         -> spread / crossed-market detection
//   registered -> book arrays + BBO outputs (deterministic 1-clock latency)
//
// Coherency: BBO is computed from the *next-state* book, so the registered BBO
// on cycle N+1 already reflects the event applied on the edge of cycle N — a
// back-to-back one-event/clock burst never sees a stale top of book.
//
// Clean, synthesizable, latch-free, `default_nettype none`, parameterized.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module order_book_bbo #(
    parameter int LEVELS = 16,          // number of price levels (buckets); pow2
    parameter int QW     = 16,          // resting-quantity width (per level)
    // ---- derived (do not override) ----
    parameter int LVLW   = (LEVELS <= 1) ? 1 : $clog2(LEVELS)
) (
    input  wire                 clk,
    input  wire                 rst,          // sync, active-high: clears book+BBO

    // -------- update port: exactly one book event per clock -----------------
    input  wire                 upd_valid,    // apply an event this cycle
    input  wire                 upd_side,     // 0 = BID book, 1 = ASK book
    input  wire                 upd_op,       // 0 = ADD (+qty), 1 = REMOVE (-qty)
    input  wire [LVLW-1:0]      upd_level,    // price bucket (index) to touch
    input  wire [QW-1:0]        upd_qty,      // delta quantity (saturating)

    // -------- registered top-of-book (1-clock latency after an event) -------
    output logic                book_event,   // registered echo of upd_valid

    output logic                bid_valid,    // a resting bid exists
    output logic [LVLW-1:0]     bid_level,    // best (highest) bid price level
    output logic [QW-1:0]       bid_qty,      // size resting at best bid

    output logic                ask_valid,    // a resting ask exists
    output logic [LVLW-1:0]     ask_level,    // best (lowest) ask price level
    output logic [QW-1:0]       ask_qty,      // size resting at best ask

    output logic                both_valid,   // both sides have a top of book
    output logic [LVLW:0]       spread,       // ask_level - bid_level (signed-safe)
    output logic                crossed       // bid_level >= ask_level (locked/crossed)
);

    // ------------------------------------------------------------------------
    // Book state: one aggregate resting quantity per price level, per side.
    // Direct-mapped -> no pointer chasing, no tree rebalancing.
    // ------------------------------------------------------------------------
    logic [QW-1:0] bid_q [LEVELS];
    logic [QW-1:0] ask_q [LEVELS];

    // Next-state book (current book with this cycle's single event applied).
    logic [QW-1:0] bid_nq [LEVELS];
    logic [QW-1:0] ask_nq [LEVELS];

    localparam logic [QW-1:0] QMAX = {QW{1'b1}};

    // Saturating apply of one event to one level's quantity.
    function automatic logic [QW-1:0] apply_evt
        (input logic [QW-1:0] cur, input logic op, input logic [QW-1:0] delta);
        logic            carry;   // add-overflow flag (top bit of cur+delta)
        logic [QW-1:0]   res;     // low QW bits of the sum
        begin
            if (op == 1'b0) begin                 // ADD, saturate high
                {carry, res} = cur + delta;       // concat capture avoids overflow loss
                apply_evt = carry ? QMAX : res;
            end else begin                        // REMOVE, saturate at zero
                apply_evt = (delta >= cur) ? '0 : (cur - delta);
            end
        end
    endfunction

    // ---- combinational next-state: copy book, mutate exactly one cell ------
    integer i;
    always_comb begin
        for (i = 0; i < LEVELS; i = i + 1) begin
            bid_nq[i] = bid_q[i];
            ask_nq[i] = ask_q[i];
        end
        if (upd_valid) begin
            if (upd_side == 1'b0)
                bid_nq[upd_level] = apply_evt(bid_q[upd_level], upd_op, upd_qty);
            else
                ask_nq[upd_level] = apply_evt(ask_q[upd_level], upd_op, upd_qty);
        end
    end

    // ------------------------------------------------------------------------
    // Parallel BBO extraction over the NEXT-STATE book (constant-time in HW):
    //   best bid = HIGHEST-indexed level whose bid qty != 0  (buyers bid up)
    //   best ask = LOWEST-indexed  level whose ask qty != 0  (sellers ask low)
    // Written as scanning loops for clarity; synthesizes to a balanced
    // priority-encoder / reduction tree — its depth (and therefore the BBO
    // latency) is fixed by LEVELS, NOT by how many levels are occupied.
    // ------------------------------------------------------------------------
    logic            c_bid_valid;
    logic [LVLW-1:0] c_bid_level;
    logic [QW-1:0]   c_bid_qty;
    logic            c_ask_valid;
    logic [LVLW-1:0] c_ask_level;
    logic [QW-1:0]   c_ask_qty;

    integer j;
    always_comb begin
        // best bid: scan low->high, keep the last (highest) occupied level
        c_bid_valid = 1'b0;
        c_bid_level = '0;
        c_bid_qty   = '0;
        for (j = 0; j < LEVELS; j = j + 1) begin
            if (bid_nq[j] != '0) begin
                c_bid_valid = 1'b1;
                c_bid_level = LVLW'(j);
                c_bid_qty   = bid_nq[j];
            end
        end
        // best ask: scan high->low, keep the last (lowest) occupied level
        c_ask_valid = 1'b0;
        c_ask_level = '0;
        c_ask_qty   = '0;
        for (j = LEVELS-1; j >= 0; j = j - 1) begin
            if (ask_nq[j] != '0) begin
                c_ask_valid = 1'b1;
                c_ask_level = LVLW'(j);
                c_ask_qty   = ask_nq[j];
            end
        end
    end

    // Cross-side status, also from the next-state combinational view.
    logic            c_both;
    logic [LVLW:0]   c_spread;
    logic            c_crossed;
    always_comb begin
        c_both    = c_bid_valid & c_ask_valid;
        // ask_level - bid_level as a widened value (>=0 in a healthy book)
        c_spread  = {1'b0, c_ask_level} - {1'b0, c_bid_level};
        c_crossed = c_both & (c_bid_level >= c_ask_level);
    end

    // ------------------------------------------------------------------------
    // Register everything -> deterministic 1-clock event->BBO latency.
    // ------------------------------------------------------------------------
    integer k;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < LEVELS; k = k + 1) begin
                bid_q[k] <= '0;
                ask_q[k] <= '0;
            end
            book_event <= 1'b0;
            bid_valid  <= 1'b0;  bid_level <= '0;  bid_qty <= '0;
            ask_valid  <= 1'b0;  ask_level <= '0;  ask_qty <= '0;
            both_valid <= 1'b0;  spread    <= '0;  crossed <= 1'b0;
        end else begin
            for (k = 0; k < LEVELS; k = k + 1) begin
                bid_q[k] <= bid_nq[k];
                ask_q[k] <= ask_nq[k];
            end
            book_event <= upd_valid;
            bid_valid  <= c_bid_valid;  bid_level <= c_bid_level;  bid_qty <= c_bid_qty;
            ask_valid  <= c_ask_valid;  ask_level <= c_ask_level;  ask_qty <= c_ask_qty;
            both_valid <= c_both;       spread    <= c_spread;     crossed <= c_crossed;
        end
    end

endmodule

`default_nettype wire
