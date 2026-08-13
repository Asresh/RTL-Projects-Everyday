// =============================================================================
// Day 31 : Tick-to-Trade Marketable-Order Trigger Engine  (strat_trigger)
// -----------------------------------------------------------------------------
// The TRADE DECISION node of the HFT tick-to-trade path. It sits between
// Day 27's L2 book / BBO engine (which produces best-bid / best-offer every
// tick) and Day 26's pre-trade risk gate (which vets the child order before
// egress on Day 29). Given a small table of *resting strategy rules*, it
// continuously evaluates them against the live BBO and, the very cycle a rule
// becomes marketable, emits exactly one child order.
//
// A rule i is { arm, side, lim_px, qty, token }:
//   BUY  rule (side=0) is marketable when  ask_ok & best_ask <= lim_px
//   SELL rule (side=1) is marketable when  bid_ok & best_bid >= lim_px
//
// WHY THIS IS AN ULTRA-LOW-LATENCY (ULL) DESIGN
// ---------------------------------------------
//   * DETERMINISTIC, OCCUPANCY-INDEPENDENT LATENCY  (worst-case == typical).
//     The whole decision -- N parallel marketable compares -> priority encoder
//     -> throttle gate -> order fields -- is ONE combinational cone evaluated on
//     the current registered state and captured into registered outputs. The
//     BBO-tick -> order-fire latency is exactly 1 clock whether 1 rule or all N
//     rules are armed. The priority-encoder depth is fixed by N, not by how
//     many rules happen to match. In HFT the *variance* of tick-to-trade is
//     what loses races; a fixed 1-clock hop removes it.
//   * NO SOFTWARE IN THE LOOP. The book, the strategy compare, and the fire all
//     live in fabric -- no CPU, no interrupt, no cache/DMA jitter.
//   * ONE-SHOT ARM-CLEAR. Firing clears arm[winner], so a rule fires exactly
//     once per arm. This kills the classic "marketable price persists for many
//     cycles -> a flood of duplicate orders" bug in hardware, deterministically.
//   * COOLDOWN throttle (runtime `cooldown_i`): a fixed post-fire quiet window,
//     a hardware rate-limit that bounds message rate to the exchange.
//   * MAX-INFLIGHT throttle: at most MAX_INFLIGHT orders may be outstanding
//     (awaiting `ack_i` fill/reject from downstream). This bounds capital and
//     message-credit at risk with a single popcount-free counter compare.
//   * At most ONE fire per clock; a single-cycle config port loads/arms rules
//     without disturbing the datapath.
//
// Latch-free, `default_nettype none`, fully parameterized. Synchronous
// active-high reset. Independent golden-model scoreboard TB in tb_strat_trigger.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module strat_trigger #(
    parameter int N          = 8,   // number of resting strategy rules
    parameter int PX_W       = 32,  // price width (bits)
    parameter int QW         = 16,  // order quantity width
    parameter int TOKW       = 32,  // client order-token width
    parameter int COOLDOWN_W = 8,   // width of the runtime cooldown counter
    parameter int MAX_INFLIGHT = 4, // max simultaneously-outstanding orders
    // ---- derived widths (do NOT override) ----
    parameter int IDXW = (N > 1) ? $clog2(N) : 1, // rule index
    parameter int CNTW = $clog2(N + 1),           // 0..N armed
    parameter int IFW  = $clog2(MAX_INFLIGHT + 1) // 0..MAX_INFLIGHT
) (
    input  wire                    clk,
    input  wire                    rst,       // synchronous, active-high

    // ---- market-data / BBO tick (from Day 27 book engine) -----------------
    input  wire                    bbo_valid_i, // 1 = a fresh BBO this cycle
    input  wire [PX_W-1:0]         best_bid_i,
    input  wire                    bid_ok_i,    // best_bid_i carries a real bid
    input  wire [PX_W-1:0]         best_ask_i,
    input  wire                    ask_ok_i,    // best_ask_i carries a real ask

    // ---- single-cycle rule configuration port -----------------------------
    input  wire                    cfg_we_i,    // write-enable for one rule
    input  wire [IDXW-1:0]         cfg_idx_i,   // which rule slot
    input  wire                    cfg_arm_i,   // 1 = arm/enable, 0 = disarm
    input  wire                    cfg_side_i,  // 0 = BUY, 1 = SELL
    input  wire [PX_W-1:0]         cfg_px_i,    // limit price
    input  wire [QW-1:0]           cfg_qty_i,   // order size
    input  wire [TOKW-1:0]         cfg_token_i, // client token

    // ---- downstream retire (fill/reject) ----------------------------------
    input  wire                    ack_i,       // one outstanding order retired

    // ---- runtime throttle control -----------------------------------------
    input  wire [COOLDOWN_W-1:0]   cooldown_i,  // cycles to mute after a fire

    // ---- child-order egress (registered => deterministic 1-clk latency) ----
    output reg                     fire_o,      // 1-cycle order-emit strobe
    output reg  [IDXW-1:0]         fire_idx_o,  // which rule fired
    output reg                     order_side_o,
    output reg  [PX_W-1:0]         order_px_o,  // limit price sent (rule lim_px)
    output reg  [QW-1:0]           order_qty_o,
    output reg  [TOKW-1:0]         order_token_o,

    // ---- status ------------------------------------------------------------
    output reg                     blocked_o,   // marketable but throttled
    output reg  [CNTW-1:0]         armed_cnt_o, // # currently-armed rules
    output reg  [IFW-1:0]          inflight_o,  // # outstanding orders
    output reg                     cooldown_active_o
);
    localparam logic SIDE_BUY  = 1'b0;
    localparam logic SIDE_SELL = 1'b1;

    // ---- rule table (registered state) ------------------------------------
    reg                arm_q   [N];
    reg                side_q  [N];
    reg [PX_W-1:0]     px_q    [N];
    reg [QW-1:0]       qty_q   [N];
    reg [TOKW-1:0]     token_q [N];

    reg [COOLDOWN_W-1:0] cooldown_cnt_q;  // >0 => muted
    reg [IFW-1:0]        inflight_q;      // outstanding orders

    // ---- combinational decision cone --------------------------------------
    // marketable[i] : rule i wants to trade against the current BBO this tick.
    logic [N-1:0] marketable;
    always_comb begin
        for (int i = 0; i < N; i++) begin
            logic buy_hit, sell_hit;
            buy_hit  = ask_ok_i && (best_ask_i <= px_q[i]);
            sell_hit = bid_ok_i && (best_bid_i >= px_q[i]);
            marketable[i] = bbo_valid_i && arm_q[i] &&
                            ((side_q[i] == SIDE_BUY) ? buy_hit : sell_hit);
        end
    end

    wire any_mkt      = |marketable;
    wire cool_active  = (cooldown_cnt_q != {COOLDOWN_W{1'b0}});
    wire inflight_ok  = (inflight_q < MAX_INFLIGHT[IFW-1:0]);

    // gate: may we actually send an order this cycle?
    wire can_fire     = any_mkt && !cool_active && inflight_ok;
    // marketable this cycle but held back by a throttle
    wire blocked_now  = any_mkt && (cool_active || !inflight_ok);

    // priority encoder : lowest-index marketable rule wins
    logic [IDXW-1:0] win_idx;
    always_comb begin
        win_idx = '0;
        for (int i = N - 1; i >= 0; i--)
            if (marketable[i]) win_idx = IDXW'(i);
    end

    wire do_fire = can_fire; // exactly one order when can_fire is asserted

    // ---- armed-count popcount (combinational, for status) -----------------
    logic [CNTW-1:0] armed_cnt_c;
    always_comb begin
        armed_cnt_c = '0;
        for (int i = 0; i < N; i++)
            if (arm_q[i]) armed_cnt_c = armed_cnt_c + CNTW'(1);
    end

    // ---- inflight next-state (fire increments, ack retires) ---------------
    // A stray ack with nothing outstanding is ignored (no underflow).
    wire inc_inflight = do_fire;
    wire dec_inflight = ack_i && (inflight_q != {IFW{1'b0}});
    logic [IFW-1:0] inflight_n;
    always_comb begin
        inflight_n = inflight_q;
        case ({inc_inflight, dec_inflight})
            2'b10: inflight_n = inflight_q + IFW'(1);
            2'b01: inflight_n = inflight_q - IFW'(1);
            default: inflight_n = inflight_q; // 00 hold, 11 net-zero
        endcase
    end

    // =======================================================================
    // Sequential update
    // =======================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N; i++) begin
                arm_q[i]   <= 1'b0;
                side_q[i]  <= 1'b0;
                px_q[i]    <= '0;
                qty_q[i]   <= '0;
                token_q[i] <= '0;
            end
            cooldown_cnt_q    <= '0;
            inflight_q        <= '0;
            fire_o            <= 1'b0;
            fire_idx_o        <= '0;
            order_side_o      <= 1'b0;
            order_px_o        <= '0;
            order_qty_o       <= '0;
            order_token_o     <= '0;
            blocked_o         <= 1'b0;
            armed_cnt_o       <= '0;
            inflight_o        <= '0;
            cooldown_active_o <= 1'b0;
        end else begin
            // ---- one-shot arm-clear on fire -------------------------------
            if (do_fire)
                arm_q[win_idx] <= 1'b0;

            // ---- config write (newest instruction wins over arm-clear) ----
            if (cfg_we_i) begin
                arm_q[cfg_idx_i]   <= cfg_arm_i;
                side_q[cfg_idx_i]  <= cfg_side_i;
                px_q[cfg_idx_i]    <= cfg_px_i;
                qty_q[cfg_idx_i]   <= cfg_qty_i;
                token_q[cfg_idx_i] <= cfg_token_i;
            end

            // ---- cooldown counter -----------------------------------------
            if (do_fire)
                cooldown_cnt_q <= cooldown_i;             // (re)load on fire
            else if (cool_active)
                cooldown_cnt_q <= cooldown_cnt_q - COOLDOWN_W'(1);

            // ---- inflight counter -----------------------------------------
            inflight_q <= inflight_n;

            // ---- registered order egress ----------------------------------
            fire_o        <= do_fire;
            fire_idx_o    <= win_idx;
            order_side_o  <= side_q[win_idx];
            order_px_o    <= px_q[win_idx];
            order_qty_o   <= qty_q[win_idx];
            order_token_o <= token_q[win_idx];

            // ---- registered status ----------------------------------------
            blocked_o         <= blocked_now;
            armed_cnt_o       <= armed_cnt_c;
            inflight_o        <= inflight_n;
            cooldown_active_o <= (do_fire) ? (cooldown_i != {COOLDOWN_W{1'b0}})
                                           : (cooldown_cnt_q > COOLDOWN_W'(1));
        end
    end

`ifdef FORMAL
    // sanity: inflight never exceeds the cap, cooldown gates fire
    always @(posedge clk) if (!rst) begin
        assert (inflight_q <= MAX_INFLIGHT[IFW-1:0]);
        if (cool_active) assert (!do_fire);
    end
`endif

endmodule

`default_nettype wire
