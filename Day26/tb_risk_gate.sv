// ===========================================================================
// Day 26 : Self-checking testbench for the Pre-Trade Risk Check Gate
// ---------------------------------------------------------------------------
// An INDEPENDENT golden model re-implements the five risk checks and the
// running signed-position accumulator in plain testbench code, then compares,
// every cycle, against the DUT's registered decision.  Because the gate has a
// deterministic 1-clock latency and accepts one order/clock, the checker is a
// simple 1-deep pipeline: the prediction made for the request driven at cycle
// T is compared against the DUT outputs observed at cycle T+1.
//
// Coverage:
//   * reset behaviour (position cleared, no spurious valid)
//   * each reject reason isolated: KILL, QTY(zero & over), BAND(lo & hi),
//     NOTIONAL, POSITION (long & short overflow)
//   * clean accepts that move the running position both ways
//   * proof that a REJECTED order does NOT move the position
//   * back-to-back one-order/clock bursts (position hazard across the pipe)
//   * bubbles (req_valid = 0)
//   * kill-switch assert / de-assert mid-stream
//   * 4000 randomized orders (random side/price/qty, occasional kill & bubble)
//
// Prints "RESULT: *** PASS ***" only if every check matched.
// ===========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_risk_gate;

    // ---- DUT parameters ---------------------------------------------------
    localparam int PW   = 16;
    localparam int QW   = 16;
    localparam int POSW = 32;
    localparam int NOTW = PW + QW;

    // ---- clock / reset ----------------------------------------------------
    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;          // 100 MHz

    // ---- risk configuration (static during the run unless noted) ----------
    logic                  cfg_kill;
    logic [QW-1:0]         cfg_max_qty;
    logic [NOTW-1:0]       cfg_max_notional;
    logic [POSW-1:0]       cfg_max_pos;
    logic [1:0][PW-1:0]    cfg_price_min;
    logic [1:0][PW-1:0]    cfg_price_max;

    // ---- request / response -----------------------------------------------
    logic                  req_valid, req_side;
    logic [PW-1:0]         req_price;
    logic [QW-1:0]         req_qty;

    logic                  resp_valid, resp_accept;
    logic [4:0]            resp_reason;
    logic                  resp_side;
    logic [PW-1:0]         resp_price;
    logic [QW-1:0]         resp_qty;
    logic signed [POSW-1:0] pos_o;
    logic                  viol_o;

    // ---- reason bit positions (mirror of the DUT) -------------------------
    localparam int R_KILL = 0, R_QTY = 1, R_BAND = 2, R_NOTL = 3, R_POS = 4;
    localparam bit SIDE_BUY = 1'b0, SIDE_SELL = 1'b1;

    // ======================================================================
    // DUT
    // ======================================================================
    risk_gate #(.PW(PW), .QW(QW), .POSW(POSW), .NOTW(NOTW)) dut (
        .clk(clk), .rst(rst),
        .cfg_kill(cfg_kill), .cfg_max_qty(cfg_max_qty),
        .cfg_max_notional(cfg_max_notional), .cfg_max_pos(cfg_max_pos),
        .cfg_price_min(cfg_price_min), .cfg_price_max(cfg_price_max),
        .req_valid(req_valid), .req_side(req_side),
        .req_price(req_price), .req_qty(req_qty),
        .resp_valid(resp_valid), .resp_accept(resp_accept),
        .resp_reason(resp_reason), .resp_side(resp_side),
        .resp_price(resp_price), .resp_qty(resp_qty),
        .pos_o(pos_o), .viol_o(viol_o)
    );

    // ======================================================================
    // Golden model state + bookkeeping
    // ======================================================================
    logic signed [POSW-1:0] gpos;      // golden running position
    integer checks = 0;
    integer errors = 0;

    // kill-switch value to apply on the *next* driven request.  Applied inside
    // step() at the negedge so it is stable across the latching posedge (else
    // the config change would race an in-flight order between model & DUT).
    logic       tb_kill = 1'b0;

    // one-deep pipeline of the expected decision
    logic       have_prev = 1'b0;
    logic       pv_valid, pv_accept;
    logic [4:0] pv_reason;
    logic       pv_side;
    logic [PW-1:0] pv_price;
    logic [QW-1:0] pv_qty;

    // ---- golden decision (pure function of request + current gpos) --------
    task automatic predict(
        input  logic          vld,
        input  logic          side,
        input  logic [PW-1:0] price,
        input  logic [QW-1:0] qty,
        output logic          e_valid,
        output logic          e_accept,
        output logic [4:0]    e_reason,
        output logic signed [POSW-1:0] e_pos_after
    );
        logic [NOTW-1:0]        notl;
        logic signed [POSW:0]   qty_s, delta, pnext;
        logic        [POSW:0]   pabs, maxpos_ext;
        logic ck_kill, ck_qty, ck_band, ck_notl, ck_pos;
        begin
            notl  = price * qty;
            qty_s = $signed({{(POSW+1-QW){1'b0}}, qty});      // positive
            delta = (side == SIDE_BUY) ? qty_s : -qty_s;
            pnext = $signed({gpos[POSW-1], gpos}) + delta;
            pabs  = pnext[POSW] ? (~pnext + 1'b1) : pnext;     // magnitude
            maxpos_ext = {1'b0, cfg_max_pos};

            ck_kill = cfg_kill;
            ck_qty  = (qty == '0) || (qty > cfg_max_qty);
            ck_band = (price < cfg_price_min[side]) || (price > cfg_price_max[side]);
            ck_notl = (notl > cfg_max_notional);
            ck_pos  = (pabs > maxpos_ext);

            e_reason = 5'b0;
            e_reason[R_KILL] = ck_kill;
            e_reason[R_QTY ] = ck_qty;
            e_reason[R_BAND] = ck_band;
            e_reason[R_NOTL] = ck_notl;
            e_reason[R_POS ] = ck_pos;

            e_valid  = vld;
            e_accept = vld & (e_reason == 5'b0);
            // committed position only advances on accept
            e_pos_after = e_accept ? pnext[POSW-1:0] : gpos;
        end
    endtask

    // ---- compare the pending prediction against DUT outputs ---------------
    task automatic check_resp;
        begin
            checks++;
            if (resp_valid !== pv_valid) begin
                errors++; $display("[%0t] ERR resp_valid=%b exp=%b", $time, resp_valid, pv_valid);
            end
            if (pv_valid) begin
                if (resp_accept !== pv_accept) begin
                    errors++; $display("[%0t] ERR accept=%b exp=%b (reason dut=%b exp=%b)",
                                       $time, resp_accept, pv_accept, resp_reason, pv_reason);
                end
                if (resp_reason !== pv_reason) begin
                    errors++; $display("[%0t] ERR reason=%05b exp=%05b", $time, resp_reason, pv_reason);
                end
                if (resp_side !== pv_side || resp_price !== pv_price || resp_qty !== pv_qty) begin
                    errors++; $display("[%0t] ERR echo side/price/qty dut=%b/%0d/%0d exp=%b/%0d/%0d",
                                       $time, resp_side, resp_price, resp_qty, pv_side, pv_price, pv_qty);
                end
                if (viol_o !== (pv_valid & ~pv_accept)) begin
                    errors++; $display("[%0t] ERR viol=%b exp=%b", $time, viol_o, (pv_valid & ~pv_accept));
                end
            end
        end
    endtask

    // ---- drive one order (or a bubble) for exactly one cycle --------------
    task automatic step(input logic vld, input logic side,
                        input logic [PW-1:0] price, input logic [QW-1:0] qty);
        logic e_valid, e_accept; logic [4:0] e_reason;
        logic signed [POSW-1:0] e_pos_after;
        begin
            @(negedge clk);
            // 1) the DUT now shows the decision for the request driven last cycle
            if (have_prev) check_resp();
            // 2) apply this request's kill value (held stable through the posedge)
            cfg_kill = tb_kill;
            // 3) predict this new request against the committed golden position
            predict(vld, side, price, qty, e_valid, e_accept, e_reason, e_pos_after);
            // 3) drive it
            req_valid <= vld; req_side <= side; req_price <= price; req_qty <= qty;
            // 4) latch the prediction + advance the golden position on accept
            pv_valid  = e_valid;  pv_accept = e_accept; pv_reason = e_reason;
            pv_side   = side;     pv_price  = price;     pv_qty    = qty;
            gpos      = e_pos_after;
            have_prev = 1'b1;
        end
    endtask

    // ---- flush the last in-flight prediction ------------------------------
    task automatic flush;
        begin
            @(negedge clk);
            if (have_prev) check_resp();
            req_valid <= 1'b0;
            have_prev = 1'b0;
        end
    endtask

    // ======================================================================
    // Stimulus
    // ======================================================================
    integer i;
    logic        r_vld, r_side;
    logic [PW-1:0] r_price;
    logic [QW-1:0] r_qty;

    initial begin
        $dumpfile("risk_gate.vcd");
        $dumpvars(0, tb_risk_gate);

        // --- configure limits so every reason can be isolated -------------
        cfg_kill         = 1'b0;
        cfg_max_qty      = 16'd500;
        cfg_max_notional = 32'd90000;
        cfg_max_pos      = 32'd1000;
        cfg_price_min[SIDE_BUY]  = 16'd100;  cfg_price_max[SIDE_BUY]  = 16'd200;
        cfg_price_min[SIDE_SELL] = 16'd100;  cfg_price_max[SIDE_SELL] = 16'd200;

        req_valid = 1'b0; req_side = 1'b0; req_price = '0; req_qty = '0;
        gpos = '0;

        // ---- reset -------------------------------------------------------
        rst = 1'b1;
        repeat (4) @(negedge clk);
        if (pos_o !== 0) begin errors++; $display("ERR pos not 0 in reset"); end
        if (resp_valid !== 1'b0) begin errors++; $display("ERR resp_valid in reset"); end
        rst = 1'b0;
        checks++;

        // =================================================================
        // DIRECTED CORNER CASES  (each isolates one reason where possible)
        // =================================================================
        // clean accept BUY  -> pos 0 -> +100
        step(1, SIDE_BUY , 16'd150, 16'd100);
        // clean accept SELL -> pos +100 -> -100 net? +100-200 = -100
        step(1, SIDE_SELL, 16'd150, 16'd200);
        // QTY zero
        step(1, SIDE_BUY , 16'd150, 16'd0);
        // QTY over (600 > 500), price low so notional stays in bounds -> QTY only
        step(1, SIDE_BUY , 16'd100, 16'd600);
        // BAND low  (price 50 < 100)
        step(1, SIDE_BUY , 16'd50 , 16'd100);
        // BAND high (price 250 > 200)
        step(1, SIDE_SELL, 16'd250, 16'd100);
        // NOTIONAL only (200*500=100000 > 90000, qty==max ok, band ok)
        step(1, SIDE_BUY , 16'd200, 16'd500);
        // KILL: assert kill switch, otherwise-clean order -> KILL only
        tb_kill = 1'b1;
        step(1, SIDE_BUY , 16'd150, 16'd100);
        tb_kill = 1'b0;
        // bubble
        step(0, SIDE_BUY , 16'd150, 16'd100);

        // ---- POSITION overflow (long) : drive pos toward +limit ----------
        // current committed gpos is -100 from above; bring it up in +500 steps
        step(1, SIDE_BUY , 16'd100, 16'd500);   // -100 -> +400
        step(1, SIDE_BUY , 16'd100, 16'd500);   // +400 -> +900
        // next +500 would be +1400 > 1000  -> POS reject, position unchanged
        step(1, SIDE_BUY , 16'd100, 16'd500);   // stays +900
        // prove position did NOT move: a +100 now must be accepted (+900->+1000)
        step(1, SIDE_BUY , 16'd100, 16'd100);   // +900 -> +1000 (exactly at limit)
        // one more +1 tips over the limit -> POS reject
        step(1, SIDE_BUY , 16'd100, 16'd1);     // +1001 > 1000 -> reject

        // ---- POSITION overflow (short) -----------------------------------
        step(1, SIDE_SELL, 16'd100, 16'd500);   // +1000 -> +500
        step(1, SIDE_SELL, 16'd100, 16'd500);   // +500  -> 0
        step(1, SIDE_SELL, 16'd100, 16'd500);   // 0     -> -500
        step(1, SIDE_SELL, 16'd100, 16'd500);   // -500  -> -1000
        step(1, SIDE_SELL, 16'd100, 16'd1);     // -1001 -> reject (short overflow)

        // ---- back-to-back accepts (pipeline hazard across the 1-clk gate)-
        // flatten first, then hammer alternating small orders with no bubbles
        step(1, SIDE_BUY , 16'd120, 16'd100);
        step(1, SIDE_BUY , 16'd120, 16'd100);
        step(1, SIDE_SELL, 16'd120, 16'd100);
        step(1, SIDE_SELL, 16'd120, 16'd100);

        // =================================================================
        // RANDOMIZED : 4000 orders, random side/price/qty, occasional kill
        // and bubbles.  Golden model tracks the position random-walk exactly.
        // =================================================================
        for (i = 0; i < 4000; i++) begin
            r_vld   = (({$random} % 100) < 92);          // ~8% bubbles
            r_side  = $random;                            // 0/1
            r_price = {$random} % 301;                    // 0..300 (band is 100..200)
            r_qty   = {$random} % 701;                    // 0..700 (max is 500)
            // occasionally flip the kill switch to exercise it live
            if (({$random} % 100) < 3) tb_kill = ~tb_kill;
            step(r_vld, r_side, r_price, r_qty);
        end

        flush();

        // ---- final position consistency check ----------------------------
        checks++;
        if (pos_o !== gpos) begin
            errors++;
            $display("ERR final pos_o=%0d exp=%0d", pos_o, gpos);
        end

        // ======================================================================
        $display("----------------------------------------------------------");
        $display("Day26 risk_gate : %0d checks, %0d errors", checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $display("----------------------------------------------------------");
        $finish;
    end

    // ---- global timeout ---------------------------------------------------
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
