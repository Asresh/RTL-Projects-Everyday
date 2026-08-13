// =============================================================================
// Day 31 : tb_strat_trigger  -- self-checking testbench
// -----------------------------------------------------------------------------
// Independent golden model of the marketable-order trigger engine. The model is
// a plain shadow of the rule table plus scalar cooldown / inflight counters. It
// reproduces the DUT's next-state rules exactly:
//   * marketable[i] = arm & bbo_valid & (BUY: ask_ok & ask<=lim
//                                        SELL: bid_ok & bid>=lim)
//   * fire when any marketable AND cooldown==0 AND inflight<MAX  (lowest idx)
//   * fire clears arm[winner] (one-shot); config write wins over arm-clear
//   * cooldown reloads on fire (= cooldown_i), else counts down
//   * inflight += fire, -= ack (ignoring stray ack when 0)
// Because the DUT registers its outputs, the model computes the *expected*
// decision from the pre-clock state and we compare it to the DUT outputs one
// cycle later. Directed corners + randomized soak; prints RESULT: *** PASS ***.
// =============================================================================

`default_nettype none
`timescale 1ns/1ps

module tb_strat_trigger;

    // ---- parameters under test --------------------------------------------
    localparam int N            = 8;
    localparam int PX_W         = 32;
    localparam int QW           = 16;
    localparam int TOKW         = 32;
    localparam int COOLDOWN_W   = 8;
    localparam int MAX_INFLIGHT = 4;
    localparam int IDXW = (N > 1) ? $clog2(N) : 1;
    localparam int CNTW = $clog2(N + 1);
    localparam int IFW  = $clog2(MAX_INFLIGHT + 1);

    // ---- DUT I/O -----------------------------------------------------------
    reg                    clk, rst;
    reg                    bbo_valid_i;
    reg  [PX_W-1:0]        best_bid_i, best_ask_i;
    reg                    bid_ok_i, ask_ok_i;
    reg                    cfg_we_i;
    reg  [IDXW-1:0]        cfg_idx_i;
    reg                    cfg_arm_i, cfg_side_i;
    reg  [PX_W-1:0]        cfg_px_i;
    reg  [QW-1:0]          cfg_qty_i;
    reg  [TOKW-1:0]        cfg_token_i;
    reg                    ack_i;
    reg  [COOLDOWN_W-1:0]  cooldown_i;

    wire                   fire_o;
    wire [IDXW-1:0]        fire_idx_o;
    wire                   order_side_o;
    wire [PX_W-1:0]        order_px_o;
    wire [QW-1:0]          order_qty_o;
    wire [TOKW-1:0]        order_token_o;
    wire                   blocked_o;
    wire [CNTW-1:0]        armed_cnt_o;
    wire [IFW-1:0]         inflight_o;
    wire                   cooldown_active_o;

    strat_trigger #(
        .N(N), .PX_W(PX_W), .QW(QW), .TOKW(TOKW),
        .COOLDOWN_W(COOLDOWN_W), .MAX_INFLIGHT(MAX_INFLIGHT)
    ) dut (
        .clk(clk), .rst(rst),
        .bbo_valid_i(bbo_valid_i),
        .best_bid_i(best_bid_i), .bid_ok_i(bid_ok_i),
        .best_ask_i(best_ask_i), .ask_ok_i(ask_ok_i),
        .cfg_we_i(cfg_we_i), .cfg_idx_i(cfg_idx_i), .cfg_arm_i(cfg_arm_i),
        .cfg_side_i(cfg_side_i), .cfg_px_i(cfg_px_i), .cfg_qty_i(cfg_qty_i),
        .cfg_token_i(cfg_token_i),
        .ack_i(ack_i), .cooldown_i(cooldown_i),
        .fire_o(fire_o), .fire_idx_o(fire_idx_o),
        .order_side_o(order_side_o), .order_px_o(order_px_o),
        .order_qty_o(order_qty_o), .order_token_o(order_token_o),
        .blocked_o(blocked_o), .armed_cnt_o(armed_cnt_o),
        .inflight_o(inflight_o), .cooldown_active_o(cooldown_active_o)
    );

    // ---- clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- golden shadow state ----------------------------------------------
    logic              g_arm   [N];
    logic              g_side  [N];
    logic [PX_W-1:0]   g_px    [N];
    logic [QW-1:0]     g_qty   [N];
    logic [TOKW-1:0]   g_token [N];
    logic [COOLDOWN_W-1:0] g_cool;
    logic [IFW-1:0]    g_inflight;

    // expected registered outputs (computed pre-clock, checked post-clock)
    logic              e_fire;
    logic [IDXW-1:0]   e_idx;
    logic              e_side;
    logic [PX_W-1:0]   e_px;
    logic [QW-1:0]     e_qty;
    logic [TOKW-1:0]   e_token;
    logic              e_blocked;
    logic [CNTW-1:0]   e_armed;
    logic [IFW-1:0]    e_inflight;
    logic              e_cool_active;

    integer checks = 0;
    integer errors = 0;
    logic   sample_valid = 1'b0; // becomes 1 once first expectation is armed

    // ---- helpers -----------------------------------------------------------
    task reset_all;
        integer i;
        begin
            rst = 1'b1;
            bbo_valid_i = 0; best_bid_i = 0; best_ask_i = 0;
            bid_ok_i = 0; ask_ok_i = 0;
            cfg_we_i = 0; cfg_idx_i = 0; cfg_arm_i = 0; cfg_side_i = 0;
            cfg_px_i = 0; cfg_qty_i = 0; cfg_token_i = 0;
            ack_i = 0; cooldown_i = 0;
            for (i = 0; i < N; i++) begin
                g_arm[i]=0; g_side[i]=0; g_px[i]=0; g_qty[i]=0; g_token[i]=0;
            end
            g_cool = 0; g_inflight = 0;
            sample_valid = 1'b0;
            @(posedge clk); #1;
            rst = 1'b0;
        end
    endtask

    // Compute the golden expected outputs from the CURRENT (pre-clock) inputs
    // and shadow state. Mirrors the DUT combinational cone exactly.
    task compute_expected;
        integer i;
        logic [N-1:0] mkt;
        logic         buy_hit, sell_hit;
        logic         any_mkt, cool_active, inflight_ok, do_fire;
        logic [IDXW-1:0] widx;
        logic [CNTW-1:0] acnt;
        begin
            mkt = '0;
            for (i = 0; i < N; i++) begin
                buy_hit  = ask_ok_i && (best_ask_i <= g_px[i]);
                sell_hit = bid_ok_i && (best_bid_i >= g_px[i]);
                mkt[i]   = bbo_valid_i && g_arm[i] &&
                           ((g_side[i]==1'b0) ? buy_hit : sell_hit);
            end
            any_mkt     = |mkt;
            cool_active = (g_cool != 0);
            inflight_ok = (g_inflight < MAX_INFLIGHT[IFW-1:0]);
            do_fire     = any_mkt && !cool_active && inflight_ok;

            widx = '0;
            for (i = N-1; i >= 0; i--) if (mkt[i]) widx = i[IDXW-1:0];

            acnt = '0;
            for (i = 0; i < N; i++) if (g_arm[i]) acnt = acnt + 1'b1;

            e_fire     = do_fire;
            e_idx      = widx;
            e_side     = g_side[widx];
            e_px       = g_px[widx];
            e_qty      = g_qty[widx];
            e_token    = g_token[widx];
            e_blocked  = any_mkt && (cool_active || !inflight_ok);
            e_armed    = acnt;

            // next-state inflight
            begin
                logic inc, dec;
                inc = do_fire;
                dec = ack_i && (g_inflight != 0);
                e_inflight = g_inflight + (inc ? 1'b1 : 1'b0)
                                        - (dec ? 1'b1 : 1'b0);
            end

            // next-state cooldown -> cooldown_active_o reflects NEXT value
            if (do_fire)
                e_cool_active = (cooldown_i != 0);
            else
                e_cool_active = (g_cool > 1);

            // ---- advance the golden shadow state (next-state commit) -------
            if (do_fire) g_arm[widx] = 1'b0;      // one-shot
            if (cfg_we_i) begin                    // config overrides arm-clear
                g_arm[cfg_idx_i]   = cfg_arm_i;
                g_side[cfg_idx_i]  = cfg_side_i;
                g_px[cfg_idx_i]    = cfg_px_i;
                g_qty[cfg_idx_i]   = cfg_qty_i;
                g_token[cfg_idx_i] = cfg_token_i;
            end
            if (do_fire)             g_cool = cooldown_i;
            else if (g_cool != 0)    g_cool = g_cool - 1'b1;
            g_inflight = e_inflight;
        end
    endtask

    // Check DUT registered outputs against the expectation captured last cycle.
    task check_outputs;
        begin
            if (!sample_valid) return;
            checks = checks + 1;
            if (fire_o !== e_fire) begin
                errors=errors+1;
                $display("  [%0t] FIRE mismatch exp=%0b got=%0b", $time, e_fire, fire_o);
            end
            if (e_fire) begin
                if (fire_idx_o    !== e_idx)   begin errors=errors+1; $display("  [%0t] IDX  exp=%0d got=%0d", $time, e_idx, fire_idx_o); end
                if (order_side_o  !== e_side)  begin errors=errors+1; $display("  [%0t] SIDE exp=%0b got=%0b", $time, e_side, order_side_o); end
                if (order_px_o    !== e_px)    begin errors=errors+1; $display("  [%0t] PX   exp=%0d got=%0d", $time, e_px, order_px_o); end
                if (order_qty_o   !== e_qty)   begin errors=errors+1; $display("  [%0t] QTY  exp=%0d got=%0d", $time, e_qty, order_qty_o); end
                if (order_token_o !== e_token) begin errors=errors+1; $display("  [%0t] TOK  exp=%h got=%h", $time, e_token, order_token_o); end
            end
            if (blocked_o         !== e_blocked)     begin errors=errors+1; $display("  [%0t] BLOCK exp=%0b got=%0b", $time, e_blocked, blocked_o); end
            if (armed_cnt_o       !== e_armed)       begin errors=errors+1; $display("  [%0t] ARMED exp=%0d got=%0d", $time, e_armed, armed_cnt_o); end
            if (inflight_o        !== e_inflight)    begin errors=errors+1; $display("  [%0t] INFL  exp=%0d got=%0d", $time, e_inflight, inflight_o); end
            if (cooldown_active_o !== e_cool_active) begin errors=errors+1; $display("  [%0t] COOL  exp=%0b got=%0b", $time, e_cool_active, cooldown_active_o); end
        end
    endtask

    // Drive one cycle: sample inputs (already set by caller), compute expected,
    // advance clock, then compare. Inputs must be set before calling.
    task step;
        begin
            compute_expected();      // uses current inputs + pre-clock state
            @(posedge clk);          // DUT latches; outputs update
            #1;                      // settle
            check_outputs();         // compare regs against expectation
            sample_valid = 1'b1;
        end
    endtask

    // convenience: write/arm a rule (no BBO activity this cycle)
    task cfg_rule(input [IDXW-1:0] idx, input arm, input side,
                  input [PX_W-1:0] px, input [QW-1:0] qty,
                  input [TOKW-1:0] tok);
        begin
            bbo_valid_i=0; ack_i=0;
            cfg_we_i=1; cfg_idx_i=idx; cfg_arm_i=arm; cfg_side_i=side;
            cfg_px_i=px; cfg_qty_i=qty; cfg_token_i=tok;
            step();
            cfg_we_i=0;
        end
    endtask

    // convenience: present a BBO tick (no config)
    task tick(input [PX_W-1:0] bid, input bok,
              input [PX_W-1:0] ask, input aok, input do_ack);
        begin
            cfg_we_i=0;
            bbo_valid_i=1; best_bid_i=bid; bid_ok_i=bok;
            best_ask_i=ask; ask_ok_i=aok; ack_i=do_ack;
            step();
            bbo_valid_i=0; ack_i=0;
        end
    endtask

    // ---- stimulus ----------------------------------------------------------
    integer r, k;
    reg [PX_W-1:0] rb, ra;
    reg            rbok, raok, rack, rwe, rarm, rside, rbbo;
    reg [IDXW-1:0] ridx;

    initial begin
        $dumpfile("strat_trigger.vcd");
        $dumpvars(0, tb_strat_trigger);

        reset_all();

        // === Directed 1: BUY rule fires when ask crosses limit =============
        // Rule0: BUY qty=100 lim=1000 token=0xAAAA
        cfg_rule(0, 1'b1, 1'b0, 32'd1000, 16'd100, 32'hAAAA);
        cooldown_i = 0;
        tick(32'd990, 1'b1, 32'd1005, 1'b1, 1'b0); // ask 1005 > 1000 -> no fire
        tick(32'd995, 1'b1, 32'd1000, 1'b1, 1'b0); // ask==lim -> FIRE
        // one-shot: rule now disarmed; even a better ask must NOT refire
        tick(32'd995, 1'b1, 32'd900,  1'b1, 1'b0); // no fire (disarmed)

        // === Directed 2: SELL rule fires when bid rises to limit ==========
        cfg_rule(1, 1'b1, 1'b1, 32'd2000, 16'd50, 32'hBBBB);
        tick(32'd1999, 1'b1, 32'd2100, 1'b1, 1'b0); // bid < lim -> no fire
        tick(32'd2000, 1'b1, 32'd2100, 1'b1, 1'b0); // bid==lim -> FIRE

        // === Directed 3: cooldown mutes fires =============================
        cooldown_i = 8'd3;
        cfg_rule(2, 1'b1, 1'b0, 32'd500, 16'd10, 32'hC0DE);
        tick(32'd400, 1'b1, 32'd500, 1'b1, 1'b0); // FIRE, loads cooldown=3
        // rule2 disarmed by one-shot; arm a fresh rule3 and confirm it is muted
        cfg_rule(3, 1'b1, 1'b0, 32'd500, 16'd10, 32'hD00D);
        tick(32'd400, 1'b1, 32'd500, 1'b1, 1'b0); // marketable but BLOCKED
        tick(32'd400, 1'b1, 32'd500, 1'b1, 1'b0); // still cooling -> BLOCKED
        tick(32'd400, 1'b1, 32'd500, 1'b1, 1'b0); // cooldown expiring -> BLOCKED
        tick(32'd400, 1'b1, 32'd500, 1'b1, 1'b0); // now free -> FIRE
        cooldown_i = 0;

        // === Directed 4: inflight cap blocks fires ========================
        // fill inflight to MAX_INFLIGHT with rules, then confirm the next is blocked
        for (k = 0; k < N; k++)
            cfg_rule(k[IDXW-1:0], 1'b1, 1'b0, 32'd100, 16'd1,
                     32'h1000 + k);
        // fire MAX_INFLIGHT times (each fire disarms one rule), no acks
        for (k = 0; k < MAX_INFLIGHT; k++)
            tick(32'd0, 1'b0, 32'd100, 1'b1, 1'b0); // ask<=100 -> fire
        // now inflight==MAX; still-armed rules are marketable but BLOCKED
        tick(32'd0, 1'b0, 32'd100, 1'b1, 1'b0);     // BLOCKED (inflight cap)
        // retire two orders via ack, without a new BBO
        bbo_valid_i=0; ack_i=1; step(); ack_i=0;    // inflight--
        // next tick may fire again
        tick(32'd0, 1'b0, 32'd100, 1'b1, 1'b0);     // FIRE (room now)

        // === Directed 5: priority (lowest index wins) among many mkt ======
        reset_all();
        cfg_rule(5, 1'b1, 1'b0, 32'd100, 16'd7, 32'h5555);
        cfg_rule(2, 1'b1, 1'b0, 32'd100, 16'd8, 32'h2222); // lower idx
        cfg_rule(6, 1'b1, 1'b0, 32'd100, 16'd9, 32'h6666);
        cooldown_i = 0;
        tick(32'd0, 1'b0, 32'd90, 1'b1, 1'b0); // all marketable -> idx2 wins

        // === Directed 6: disarm via config, ok flags gate ================
        reset_all();
        cfg_rule(0, 1'b1, 1'b0, 32'd100, 16'd1, 32'hFEED);
        tick(32'd0, 1'b0, 32'd50, 1'b0, 1'b0); // ask_ok=0 -> not marketable
        cfg_rule(0, 1'b0, 1'b0, 32'd100, 16'd1, 32'hFEED); // disarm
        tick(32'd0, 1'b0, 32'd50, 1'b1, 1'b0); // disarmed -> no fire

        // === Randomized soak =============================================
        reset_all();
        cooldown_i = 8'd2;
        for (r = 0; r < 4000; r++) begin
            rwe   = ($random % 3 == 0);
            ridx  = $random;
            rarm  = $random;
            rside = $random;
            rbbo  = ($random % 2);
            rack  = ($random % 4 == 0);
            rb    = $random & 32'h0000_0FFF;
            ra    = $random & 32'h0000_0FFF;
            rbok  = $random;
            raok  = $random;
            if ((r % 500) == 0) cooldown_i = ($random & 8'h07);

            cfg_we_i   = rwe;
            cfg_idx_i  = ridx;
            cfg_arm_i  = rarm;
            cfg_side_i = rside;
            cfg_px_i   = ($random & 32'h0000_0FFF);
            cfg_qty_i  = $random;
            cfg_token_i= $random;
            bbo_valid_i= rbbo;
            best_bid_i = rb; bid_ok_i = rbok;
            best_ask_i = ra; ask_ok_i = raok;
            ack_i      = rack;
            step();
            cfg_we_i=0; bbo_valid_i=0; ack_i=0;
        end

        // ---- verdict -------------------------------------------------------
        $display("");
        $display("Day31 strat_trigger : %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d mismatches)", errors);
        $finish;
    end

    // ---- global timeout ----------------------------------------------------
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
