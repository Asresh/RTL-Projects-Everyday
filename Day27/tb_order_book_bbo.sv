// ============================================================================
// Day 27 : Self-checking testbench for the L2 Order Book + BBO engine.
// ----------------------------------------------------------------------------
// Independent golden model:
//   - a plain SV unpacked array per side (bid_g[], ask_g[]) holds the aggregate
//     resting qty per level, updated with the SAME saturating add/sub rule;
//   - after each applied event the golden BBO is computed by a linear scan
//     (highest occupied bid level, lowest occupied ask level) — a totally
//     different implementation from the DUT's registered priority encoder;
//   - because the DUT registers its answer, expected BBO is pushed through a
//     1-deep pipeline and checked one clock later against the DUT outputs.
//
// Stimulus: directed corners (empty, single levels, build/tear-down, crossed
// market, saturating over/underflow, back-to-back 1-event/clock burst) then
// thousands of randomized events. Timeout watchdog + VCD dump. Prints
// "RESULT: *** PASS ***" only if every cycle matched.
// ============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_order_book_bbo;

    localparam int LEVELS = 16;
    localparam int QW     = 16;
    localparam int LVLW   = $clog2(LEVELS);

    // ---- DUT I/O -----------------------------------------------------------
    logic                clk, rst;
    logic                upd_valid, upd_side, upd_op;
    logic [LVLW-1:0]     upd_level;
    logic [QW-1:0]       upd_qty;

    logic                book_event;
    logic                bid_valid;  logic [LVLW-1:0] bid_level;  logic [QW-1:0] bid_qty;
    logic                ask_valid;  logic [LVLW-1:0] ask_level;  logic [QW-1:0] ask_qty;
    logic                both_valid; logic [LVLW:0]   spread;     logic          crossed;

    order_book_bbo #(.LEVELS(LEVELS), .QW(QW)) dut (
        .clk(clk), .rst(rst),
        .upd_valid(upd_valid), .upd_side(upd_side), .upd_op(upd_op),
        .upd_level(upd_level), .upd_qty(upd_qty),
        .book_event(book_event),
        .bid_valid(bid_valid), .bid_level(bid_level), .bid_qty(bid_qty),
        .ask_valid(ask_valid), .ask_level(ask_level), .ask_qty(ask_qty),
        .both_valid(both_valid), .spread(spread), .crossed(crossed)
    );

    // ---- clock -------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- golden book state -------------------------------------------------
    integer bid_g [0:LEVELS-1];
    integer ask_g [0:LEVELS-1];
    localparam integer QMAX = (1 << QW) - 1;

    // expected-BBO 1-deep pipeline (DUT registers its result)
    logic            e_valid_bid, e_valid_ask, e_both, e_crossed, e_event;
    integer          e_bid_lvl, e_bid_qty, e_ask_lvl, e_ask_qty, e_spread;

    integer checks = 0;
    integer errors = 0;

    // saturating apply into the golden array
    function automatic integer g_apply(input integer cur, input logic op, input integer d);
        integer r;
        begin
            if (op == 1'b0) begin r = cur + d; if (r > QMAX) r = QMAX; end
            else            begin r = cur - d; if (r < 0)    r = 0;    end
            g_apply = r;
        end
    endfunction

    // recompute golden BBO by linear scan (independent of the DUT encoder)
    task automatic g_bbo(output logic vb, output integer bl, output integer bq,
                         output logic va, output integer al, output integer aq);
        integer m;
        begin
            vb = 1'b0; bl = 0; bq = 0;
            for (m = 0; m < LEVELS; m = m + 1)
                if (bid_g[m] != 0) begin vb = 1'b1; bl = m; bq = bid_g[m]; end // highest
            va = 1'b0; al = 0; aq = 0;
            for (m = LEVELS-1; m >= 0; m = m - 1)
                if (ask_g[m] != 0) begin va = 1'b1; al = m; aq = ask_g[m]; end // lowest
        end
    endtask

    // Apply one event on this posedge: update golden book, latch expected BBO
    // into the pipeline, and drive the DUT. Then on the NEXT posedge compare.
    task automatic do_event(input logic v, input logic side, input logic op,
                            input integer lvl, input integer qty);
        logic vb, va; integer bl, bq, al, aq;
        begin
            // drive DUT inputs for this cycle
            upd_valid = v; upd_side = side; upd_op = op;
            upd_level = lvl[LVLW-1:0]; upd_qty = qty[QW-1:0];

            // update golden model to reflect the same event. Mask the delta to
            // the port width first — the DUT only ever sees qty[QW-1:0].
            if (v) begin
                if (side == 1'b0) bid_g[lvl] = g_apply(bid_g[lvl], op, qty & QMAX);
                else              ask_g[lvl] = g_apply(ask_g[lvl], op, qty & QMAX);
            end
            // compute expected post-event BBO
            g_bbo(vb, bl, bq, va, al, aq);
            e_event     = v;
            e_valid_bid = vb; e_bid_lvl = bl; e_bid_qty = bq;
            e_valid_ask = va; e_ask_lvl = al; e_ask_qty = aq;
            e_both      = vb & va;
            e_spread    = al - bl;
            e_crossed   = (vb & va) && (bl >= al);

            @(posedge clk);            // event is registered here
            #1;                        // let DUT outputs settle after the edge
            check_outputs();
        end
    endtask

    task automatic check_outputs;
        begin
            checks = checks + 1;
            if (book_event !== e_event) begin
                errors=errors+1; $display("[%0t] FAIL book_event: got %b exp %b", $time, book_event, e_event);
            end
            if (bid_valid !== e_valid_bid) begin
                errors=errors+1; $display("[%0t] FAIL bid_valid: got %b exp %b", $time, bid_valid, e_valid_bid);
            end
            if (e_valid_bid && (bid_level !== e_bid_lvl[LVLW-1:0] || bid_qty !== e_bid_qty[QW-1:0])) begin
                errors=errors+1; $display("[%0t] FAIL best bid: got lvl%0d q%0d exp lvl%0d q%0d",
                    $time, bid_level, bid_qty, e_bid_lvl, e_bid_qty);
            end
            if (ask_valid !== e_valid_ask) begin
                errors=errors+1; $display("[%0t] FAIL ask_valid: got %b exp %b", $time, ask_valid, e_valid_ask);
            end
            if (e_valid_ask && (ask_level !== e_ask_lvl[LVLW-1:0] || ask_qty !== e_ask_qty[QW-1:0])) begin
                errors=errors+1; $display("[%0t] FAIL best ask: got lvl%0d q%0d exp lvl%0d q%0d",
                    $time, ask_level, ask_qty, e_ask_lvl, e_ask_qty);
            end
            if (both_valid !== e_both) begin
                errors=errors+1; $display("[%0t] FAIL both_valid: got %b exp %b", $time, both_valid, e_both);
            end
            if (crossed !== e_crossed) begin
                errors=errors+1; $display("[%0t] FAIL crossed: got %b exp %b", $time, crossed, e_crossed);
            end
            if (e_both && (spread !== e_spread[LVLW:0])) begin
                errors=errors+1; $display("[%0t] FAIL spread: got %0d exp %0d", $time, spread, e_spread);
            end
        end
    endtask

    // idle cycle: no event, still check outputs hold
    task automatic idle; begin do_event(1'b0, 1'b0, 1'b0, 0, 0); end endtask

    integer r, side_r, op_r, lvl_r, qty_r, n;

    initial begin
        $dumpfile("order_book_bbo.vcd");
        $dumpvars(0, tb_order_book_bbo);

        // init
        upd_valid=0; upd_side=0; upd_op=0; upd_level=0; upd_qty=0;
        for (n=0;n<LEVELS;n=n+1) begin bid_g[n]=0; ask_g[n]=0; end

        // ---- reset ---------------------------------------------------------
        rst = 1'b1;
        repeat (3) @(posedge clk);
        #1;
        if (bid_valid||ask_valid||both_valid||crossed) begin
            errors=errors+1; $display("[%0t] FAIL: BBO not clear after reset", $time);
        end
        rst = 1'b0;
        @(posedge clk);

        // ---- directed: empty book -> no BBO --------------------------------
        idle();

        // ---- directed: add a single bid at level 5 -------------------------
        do_event(1'b1, 1'b0, 1'b0, 5, 100);   // BID add
        // ---- add a better bid at level 8 (new best) ------------------------
        do_event(1'b1, 1'b0, 1'b0, 8, 40);
        // ---- add a worse bid at level 2 (best unchanged) -------------------
        do_event(1'b1, 1'b0, 1'b0, 2, 999);
        // ---- add asks: level 12 then better (lower) level 10 ---------------
        do_event(1'b1, 1'b1, 1'b0, 12, 70);   // ASK add
        do_event(1'b1, 1'b1, 1'b0, 10, 55);   // new best ask
        idle();

        // ---- remove all size at best bid (8) -> best falls back to 5 -------
        do_event(1'b1, 1'b0, 1'b1, 8, 40);    // BID remove exactly to 0
        idle();

        // ---- saturating underflow: remove more than resting at level 2 -----
        do_event(1'b1, 1'b0, 1'b1, 2, 100000);// clamps to 0, level 2 gone
        idle();

        // ---- saturating overflow: two big (in-range) adds clamp to QMAX ----
        do_event(1'b1, 1'b1, 1'b0, 10, 60000);// ask@10 -> 60055
        do_event(1'b1, 1'b1, 1'b0, 10, 60000);// -> would be 120055, clamps QMAX
        #1;
        if (ask_qty !== QMAX[QW-1:0]) begin
            errors=errors+1; $display("[%0t] FAIL: ask qty did not saturate (got %0d)", $time, ask_qty);
        end
        idle();

        // ---- crossed market: push a bid up to level 11 (>= best ask 10) ----
        do_event(1'b1, 1'b0, 1'b0, 11, 25);
        #1;
        if (!crossed) begin
            errors=errors+1; $display("[%0t] FAIL: crossed market not flagged", $time);
        end
        idle();

        // ---- tear the whole book down back to empty ------------------------
        for (n=0;n<LEVELS;n=n+1) begin
            if (bid_g[n] != 0) do_event(1'b1,1'b0,1'b1,n,bid_g[n]);
            if (ask_g[n] != 0) do_event(1'b1,1'b1,1'b1,n,ask_g[n]);
        end
        idle();
        if (bid_valid||ask_valid||both_valid) begin
            errors=errors+1; $display("[%0t] FAIL: book not empty after tear-down", $time);
        end

        // ---- back-to-back 1-event/clock burst (no idle gaps) ---------------
        do_event(1'b1,1'b0,1'b0, 3, 10);
        do_event(1'b1,1'b0,1'b0, 7, 20);   // new best bid same-cycle-adjacent
        do_event(1'b1,1'b1,1'b0, 9, 30);
        do_event(1'b1,1'b1,1'b0, 8, 15);   // new best ask, back-to-back
        do_event(1'b1,1'b0,1'b1, 7, 20);   // drop best bid same burst
        idle();

        // ---- randomized soak -----------------------------------------------
        for (r = 0; r < 5000; r = r + 1) begin
            if (($random % 5) == 0) begin
                idle();                         // ~20% idle cycles
            end else begin
                side_r = $random & 1;
                op_r   = ($random % 3 == 0) ? 1 : 0;   // bias toward adds
                lvl_r  = $random % LEVELS; if (lvl_r < 0) lvl_r = -lvl_r;
                qty_r  = $random % 3000;   if (qty_r < 0) qty_r = -qty_r;
                do_event(1'b1, side_r[0], op_r[0], lvl_r, qty_r);
            end
        end

        // ---- report --------------------------------------------------------
        $display("--------------------------------------------------------");
        $display("Day27 Order-Book BBO engine: %0d checks, %0d errors", checks, errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

    // ---- watchdog ----------------------------------------------------------
    initial begin
        #2000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
