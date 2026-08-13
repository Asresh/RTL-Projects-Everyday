// ===========================================================================
// Day 26 : Pre-Trade Risk Check Gate  (Market-Access "Risk Firewall")
// ---------------------------------------------------------------------------
// The mandatory last hop of the HFT tick-to-trade path.  Every child order a
// strategy wants to fire MUST clear this gate before it is allowed onto the
// wire.  In production this block is the hardware embodiment of the regulatory
// pre-trade risk controls (SEC Rule 15c3-5 "Market Access Rule", MiFID II
// RTS 6): an exchange/broker will not let an order out that has not been
// checked for fat-finger size, price sanity, notional, and position limits.
//
// WHY IT LIVES IN THE FPGA (ultra-low-latency lesson of the day)
//   * The risk check sits *directly in series* with the order-egress path, so
//     its latency is added to EVERY order.  A software risk check (context
//     switch, cache miss, GC pause) would add microseconds of jitter to the
//     one path where nanoseconds decide fills.  In hardware the whole battery
//     of checks is a single wide *combinational cone* evaluated in parallel,
//     and the answer is registered exactly ONE clock later.
//   * DETERMINISTIC latency is the real product.  Whether the order passes,
//     trips one limit, or trips all five, `resp_valid` fires on the *same*
//     cycle count.  Worst-case latency == typical latency == 1 clock.  There
//     is no data-dependent stall, no variable-length loop, no back-pressure
//     that depends on *which* check failed.  That is what wins in HFT.
//   * The running signed position accumulator is updated on the *accepting*
//     edge, so a burst of back-to-back orders each sees the position left by
//     its predecessor -- no software round-trip, no race, 1 order/clock.
//
// DATAPATH (all five checks run in parallel, then AND-reduce)
//   req {side, price, qty}
//        |
//        +--> KILL    : global kill-switch / trading-halt asserted?
//        +--> QTY     : qty==0  OR  qty > max_qty            (fat-finger size)
//        +--> BAND    : price outside [min,max] for this side (price collar)
//        +--> NOTIONAL: price*qty > max_notional              (capital-at-risk)
//        +--> POS     : |position after fill| > max_pos       (net exposure)
//        |
//   reason_bitmap = {POS,NOTIONAL,BAND,QTY,KILL}   (sticky per-order)
//   accept        = req_valid & (reason_bitmap == 0)
//   position     += accept ? (side==BUY ? +qty : -qty) : 0
//
// Registered outputs => occupancy-independent 1-cycle latency.
//
// Style: `default_nettype none`, fully synchronous active-high reset,
// latch-free, parameterized, lint-clean.
// ===========================================================================
`default_nettype none

module risk_gate #(
    parameter int PW        = 16,          // price field width (unsigned ticks)
    parameter int QW        = 16,          // quantity field width (unsigned)
    parameter int POSW      = 32,          // signed running-position acc width
    // notional = price*qty needs PW+QW bits; give the limit that width
    parameter int NOTW      = PW + QW
)(
    input  wire                     clk,
    input  wire                     rst,        // sync, active-high

    // ---- static risk configuration (driven by host / CSR block) -----------
    input  wire                     cfg_kill,   // 1 = halt: reject everything
    input  wire [QW-1:0]            cfg_max_qty,       // max shares per order
    input  wire [NOTW-1:0]          cfg_max_notional,  // max price*qty per order
    input  wire [POSW-1:0]          cfg_max_pos,       // max |net position|
    // per-side price collar: index 0 = BUY, 1 = SELL
    input  wire [1:0][PW-1:0]       cfg_price_min,
    input  wire [1:0][PW-1:0]       cfg_price_max,

    // ---- order request (candidate order from the strategy) ----------------
    input  wire                     req_valid,
    input  wire                     req_side,   // 0 = BUY, 1 = SELL
    input  wire [PW-1:0]            req_price,
    input  wire [QW-1:0]            req_qty,

    // ---- registered decision (1 clock after a valid request) --------------
    output reg                      resp_valid,
    output reg                      resp_accept,
    output reg  [4:0]               resp_reason, // {POS,NOTIONAL,BAND,QTY,KILL}
    output reg                      resp_side,   // echoed for the egress stage
    output reg  [PW-1:0]            resp_price,
    output reg  [QW-1:0]            resp_qty,

    // ---- live risk state --------------------------------------------------
    output wire signed [POSW-1:0]   pos_o,       // current net signed position
    output reg                      viol_o       // pulses when an order rejected
);

    // --- reject-reason bit positions --------------------------------------
    localparam int R_KILL = 0;
    localparam int R_QTY  = 1;
    localparam int R_BAND = 2;
    localparam int R_NOTL = 3;
    localparam int R_POS  = 4;

    localparam bit SIDE_BUY = 1'b0;

    // ======================================================================
    // Running signed net position (register).  + = long, - = short.
    // ======================================================================
    reg signed [POSW-1:0] pos_q;
    assign pos_o = pos_q;

    // ======================================================================
    // Combinational parallel check cone -- evaluated every cycle from the
    // request and the *current committed* position register.  This is the
    // whole point: no sequencing between checks, they all resolve at once.
    // ======================================================================

    // ---- notional = price * qty (needs PW+QW bits) -----------------------
    // NOTE: for high clock targets you would pipeline this multiply; kept
    // combinational here so the whole gate is a clean single-cycle cone.
    wire [NOTW-1:0] notional = req_price * req_qty;

    // ---- signed order delta and the resulting position -------------------
    // widen qty into the signed position domain before +/-.
    wire signed [POSW-1:0] qty_s     = $signed({1'b0, req_qty});
    wire signed [POSW-1:0] pos_delta = (req_side == SIDE_BUY) ? qty_s : -qty_s;
    // one extra bit of head-room so the add cannot wrap before we range-check
    wire signed [POSW:0]   pos_next_ext = $signed({pos_q[POSW-1], pos_q})
                                        + $signed({pos_delta[POSW-1], pos_delta});
    // absolute value of the prospective position (as unsigned magnitude)
    wire [POSW:0] pos_next_abs = pos_next_ext[POSW]
                               ? (~pos_next_ext + 1'b1)   // negate if negative
                               : pos_next_ext;

    // ---- the five independent checks -------------------------------------
    wire chk_kill = cfg_kill;
    wire chk_qty  = (req_qty == '0) || (req_qty > cfg_max_qty);
    wire chk_band = (req_price < cfg_price_min[req_side]) ||
                    (req_price > cfg_price_max[req_side]);
    wire chk_notl = (notional  > cfg_max_notional);
    wire chk_pos  = (pos_next_abs > {1'b0, cfg_max_pos});

    // ---- assemble reason bitmap and the accept decision ------------------
    wire [4:0] reason_c;
    assign reason_c[R_KILL] = chk_kill;
    assign reason_c[R_QTY ] = chk_qty;
    assign reason_c[R_BAND] = chk_band;
    assign reason_c[R_NOTL] = chk_notl;
    assign reason_c[R_POS ] = chk_pos;

    wire accept_c = req_valid & (reason_c == 5'b0);

    // ======================================================================
    // Register the decision and commit the position on the accepting edge.
    // Latency is exactly one clock, independent of which checks fired.
    // ======================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            resp_valid  <= 1'b0;
            resp_accept <= 1'b0;
            resp_reason <= 5'b0;
            resp_side   <= 1'b0;
            resp_price  <= '0;
            resp_qty    <= '0;
            viol_o      <= 1'b0;
            pos_q       <= '0;
        end else begin
            resp_valid  <= req_valid;
            resp_accept <= accept_c;
            resp_reason <= req_valid ? reason_c : 5'b0;
            resp_side   <= req_side;
            resp_price  <= req_price;
            resp_qty    <= req_qty;
            viol_o      <= req_valid & ~accept_c;   // 1-cycle reject pulse

            // commit the position ONLY when the order is accepted
            if (accept_c)
                pos_q <= pos_next_ext[POSW-1:0];
        end
    end

`ifdef FORMAL
    // small always-true sanity checks (ignored by plain sim)
    always @(posedge clk) if (!rst) begin
        // accept implies no reason bits
        assert (!resp_accept || (resp_reason == 5'b0));
    end
`endif

endmodule

`default_nettype wire
