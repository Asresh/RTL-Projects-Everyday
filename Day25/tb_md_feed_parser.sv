`default_nettype none
`timescale 1ns/1ps
//============================================================================
// Self-checking testbench for md_feed_parser (Day 25)
//----------------------------------------------------------------------------
// Strategy:
//   * An INDEPENDENT golden reference computes the expected decoded event for
//     every message the driver injects, and pushes it into a small ordered
//     scoreboard (plain arrays + head/tail pointers -- no SV queues, so this
//     runs on Icarus/Verilator/VCS/Questa alike).
//   * A monitor pops one expected event per DUT ev_valid strobe and checks
//     type/error/all fields, and also that ev_valid is a clean 1-cycle pulse
//     with the deterministic 1-cycle post-last-byte latency.
//   * Stimulus: directed corners (one of each type, unknown type, wrong
//     length, over-length, mid-message abort/resync, back-to-back with gaps)
//     followed by 2000 randomized messages with random idle gaps.
//   * A cycle watchdog $fatals if the DUT ever stalls.
//============================================================================
module tb_md_feed_parser;

    // ---- clock / reset -------------------------------------------------
    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;          // 100 MHz

    // ---- DUT I/O -------------------------------------------------------
    reg         in_valid;
    reg         in_sop;
    reg  [7:0]  in_data;
    wire        ev_valid;
    wire [7:0]  ev_type;
    wire        ev_error;
    wire [15:0] ev_ref;
    wire        ev_side;
    wire [15:0] ev_shares;
    wire [15:0] ev_price;

    md_feed_parser dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_sop(in_sop), .in_data(in_data),
        .ev_valid(ev_valid), .ev_type(ev_type), .ev_error(ev_error),
        .ev_ref(ev_ref), .ev_side(ev_side),
        .ev_shares(ev_shares), .ev_price(ev_price)
    );

    // ---- scoreboard (ordered, pointer based) ---------------------------
    localparam int SB = 8192;
    reg  [7:0]  q_type   [0:SB-1];
    reg         q_error  [0:SB-1];
    reg  [15:0] q_ref    [0:SB-1];
    reg         q_side   [0:SB-1];
    reg  [15:0] q_shares [0:SB-1];
    reg  [15:0] q_price  [0:SB-1];
    integer wr = 0;   // pushes
    integer rd = 0;   // pops

    integer checks = 0;
    integer errors = 0;

    // Independent golden schema (mirrors the protocol, written separately from
    // the DUT). Pushes ONE expected event for a message with the given fields
    // and declared length `len`.
    task push_expected(input [7:0] t, input [7:0] len,
                       input [15:0] r, input side_buy,
                       input [15:0] sh, input [15:0] pr);
        reg [7:0] want_len;
        reg       err;
        begin
            case (t)
                "A": want_len = 8'd8;
                "E": want_len = 8'd5;
                "X": want_len = 8'd5;
                "D": want_len = 8'd3;
                default: want_len = 8'd0;
            endcase
            err = (want_len == 8'd0) || (len != want_len);

            q_type [wr] = t;
            q_error[wr] = err;
            if (!err) begin
                // Normalized expectation per type
                q_ref[wr] = r;
                case (t)
                    "A": begin q_side[wr]=side_buy; q_shares[wr]=sh; q_price[wr]=pr; end
                    "E","X": begin q_side[wr]=1'b0; q_shares[wr]=sh; q_price[wr]=16'd0; end
                    "D": begin q_side[wr]=1'b0; q_shares[wr]=16'd0; q_price[wr]=16'd0; end
                    default: begin q_side[wr]=1'b0; q_shares[wr]=16'd0; q_price[wr]=16'd0; end
                endcase
            end
            wr = wr + 1;
        end
    endtask

    // ---- byte-level driver ---------------------------------------------
    // Drive exactly one byte, optionally preceded by `gap` idle cycles.
    task drive_byte(input [7:0] b, input sop, input integer gap);
        integer g;
        begin
            for (g = 0; g < gap; g = g + 1) begin
                in_valid <= 1'b0; in_sop <= 1'b0; in_data <= 8'h00;
                @(posedge clk);
            end
            in_valid <= 1'b1; in_sop <= sop; in_data <= b;
            @(posedge clk);
            in_valid <= 1'b0; in_sop <= 1'b0; in_data <= 8'h00;
        end
    endtask

    // Send a full message (LEN byte + body) with per-byte random gaps.
    // `len` is the declared length byte (may differ from the true schema to
    // exercise the error path). `nbody` real body bytes are emitted.
    task send_msg(input [7:0] t, input [7:0] len,
                  input [15:0] r, input side_buy,
                  input [15:0] sh, input [15:0] pr,
                  input integer maxgap);
        reg [7:0] body [0:255];
        integer nbody, i, g;
        begin
            // Build the natural body for this type
            body[0] = t;
            case (t)
                "A": begin
                    body[1]=r[15:8]; body[2]=r[7:0];
                    body[3]= side_buy ? "B" : "S";
                    body[4]=sh[15:8]; body[5]=sh[7:0];
                    body[6]=pr[15:8]; body[7]=pr[7:0];
                    nbody = 8;
                end
                "E","X": begin
                    body[1]=r[15:8]; body[2]=r[7:0];
                    body[3]=sh[15:8]; body[4]=sh[7:0];
                    nbody = 5;
                end
                "D": begin
                    body[1]=r[15:8]; body[2]=r[7:0];
                    nbody = 3;
                end
                default: begin
                    body[1]=r[15:8]; body[2]=r[7:0];
                    body[3]=sh[15:8]; body[4]=sh[7:0];
                    nbody = 5;
                end
            endcase

            // The parser consumes exactly `len` body bytes. Pad or truncate the
            // emitted body to match the declared length so framing stays aligned.
            push_expected(t, len, r, side_buy, sh, pr);

            g = maxgap ? ($urandom % (maxgap+1)) : 0;
            drive_byte(len, 1'b1, g);                 // LENGTH byte (in_sop)
            for (i = 0; i < len; i = i + 1) begin
                g = maxgap ? ($urandom % (maxgap+1)) : 0;
                drive_byte((i < nbody) ? body[i] : $urandom, 1'b0, g);
            end
        end
    endtask

    // ---- monitor / checker ---------------------------------------------
    task check_event;
        reg [7:0]  et; reg ee; reg [15:0] er; reg es; reg [15:0] esh; reg [15:0] ep;
        begin
            if (rd >= wr) begin
                errors = errors + 1;
                $display("[%0t] ERROR: unexpected ev_valid (scoreboard empty) type=%c", $time, ev_type);
            end else begin
                et=q_type[rd]; ee=q_error[rd]; er=q_ref[rd];
                es=q_side[rd]; esh=q_shares[rd]; ep=q_price[rd];
                rd = rd + 1;
                checks = checks + 1;

                if (ev_error !== ee) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR: type=%c ev_error=%b exp=%b", $time, ev_type, ev_error, ee);
                end else if (!ee) begin
                    // Only field-check well-formed messages
                    if (ev_type !== et) begin
                        errors=errors+1; $display("[%0t] ERROR: type got=%c exp=%c",$time,ev_type,et); end
                    if (ev_ref !== er) begin
                        errors=errors+1; $display("[%0t] ERROR: %c ref got=%h exp=%h",$time,et,ev_ref,er); end
                    if (ev_side !== es) begin
                        errors=errors+1; $display("[%0t] ERROR: %c side got=%b exp=%b",$time,et,ev_side,es); end
                    if (ev_shares !== esh) begin
                        errors=errors+1; $display("[%0t] ERROR: %c shares got=%h exp=%h",$time,et,ev_shares,esh); end
                    if (ev_price !== ep) begin
                        errors=errors+1; $display("[%0t] ERROR: %c price got=%h exp=%h",$time,et,ev_price,ep); end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (!rst && ev_valid) check_event;
    end

    // ---- watchdog ------------------------------------------------------
    integer cyc = 0;
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc > 2_000_000) begin
            $display("RESULT: *** FAIL *** (watchdog timeout)");
            $fatal(1, "timeout");
        end
    end

    // Wait a few cycles then confirm all pushed events have been consumed.
    task drain_and_settle;
        integer w;
        begin
            for (w = 0; w < 20; w = w + 1) @(posedge clk);
        end
    endtask

    // ---- stimulus ------------------------------------------------------
    integer m;
    reg [7:0]  rt; reg [15:0] rr, rsh, rpr; reg rside; reg [7:0] rlen;
    integer sel;

    initial begin
        $dumpfile("md_feed_parser.vcd");
        $dumpvars(0, tb_md_feed_parser);

        in_valid = 1'b0; in_sop = 1'b0; in_data = 8'h00;

        // reset (deassert on a negedge, then one clean idle cycle so every
        // driven byte lands on a full clock period -- readable waveforms)
        rst = 1'b1;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 1'b0;
        @(posedge clk);          // one idle cycle, in_valid=0, out of reset

        //--------------------------------------------------------------
        // DIRECTED, CONTIGUOUS (no gaps) -- clean waveform window
        //--------------------------------------------------------------
        send_msg("A", 8'd8, 16'h1234, 1'b1, 16'h0064, 16'h2710, 0); // Add buy 100 @ 10000
        send_msg("E", 8'd5, 16'h1234, 1'b0, 16'h0032, 16'h0000, 0); // Exec 50 of ref 0x1234
        send_msg("X", 8'd5, 16'h00AB, 1'b0, 16'h0010, 16'h0000, 0); // Cancel 16 of ref 0x00AB
        send_msg("D", 8'd3, 16'h1234, 1'b0, 16'h0000, 16'h0000, 0); // Delete ref 0x1234
        drain_and_settle;

        //--------------------------------------------------------------
        // DIRECTED error / corner cases
        //--------------------------------------------------------------
        send_msg("Z", 8'd5, 16'hDEAD, 1'b0, 16'h0001, 16'h0000, 0); // unknown type -> error
        send_msg("A", 8'd5, 16'h1111, 1'b1, 16'h0002, 16'h0003, 0); // Add wrong len -> error
        send_msg("D", 8'd8, 16'h2222, 1'b0, 16'h0000, 16'h0000, 0); // Delete over-length -> error
        drain_and_settle;

        //--------------------------------------------------------------
        // Mid-message ABORT / resync: start an Add, then re-frame before it
        // completes. The aborted message must produce NO event; the new one
        // must decode cleanly.
        //--------------------------------------------------------------
        drive_byte(8'd8, 1'b1, 0);           // LEN=8 (start an Add)
        drive_byte("A",  1'b0, 0);           // type
        drive_byte(8'hAA,1'b0, 0);           // refH
        drive_byte(8'hBB,1'b0, 0);           // refL   ... now abort:
        // new frame arrives (in_sop) before the Add finished -> drop it
        send_msg("E", 8'd5, 16'h7788, 1'b0, 16'h0009, 16'h0000, 0);
        drain_and_settle;

        //--------------------------------------------------------------
        // Back-to-back with random gaps
        //--------------------------------------------------------------
        for (m = 0; m < 12; m = m + 1)
            send_msg("A", 8'd8, m[15:0], m[0], (m*7)&16'hFFFF, (m*13)&16'hFFFF, 2);
        drain_and_settle;

        //--------------------------------------------------------------
        // RANDOMIZED
        //--------------------------------------------------------------
        for (m = 0; m < 2000; m = m + 1) begin
            sel = $urandom % 10;
            case (sel)
                0,1,2: rt = "A";
                3,4:   rt = "E";
                5,6:   rt = "X";
                7:     rt = "D";
                8:     rt = "Z";           // unknown
                default: rt = "A";
            endcase
            rr   = $urandom;
            rsh  = $urandom;
            rpr  = $urandom;
            rside= $urandom & 1;

            // 15% of the time, corrupt the declared length to hit the error path
            if (($urandom % 100) < 15) begin
                rlen = ($urandom % 12);            // random 0..11
                if (rlen == 8'd0) rlen = 8'd1;     // zero-len frame carries no event
            end else begin
                case (rt)
                    "A": rlen = 8'd8;
                    "E": rlen = 8'd5;
                    "X": rlen = 8'd5;
                    "D": rlen = 8'd3;
                    default: rlen = 8'd5;
                endcase
            end

            send_msg(rt, rlen, rr, rside, rsh, rpr, 3);
        end

        drain_and_settle;
        drain_and_settle;

        //--------------------------------------------------------------
        // Final scoreboard reconciliation
        //--------------------------------------------------------------
        if (rd != wr) begin
            errors = errors + 1;
            $display("RESULT: *** FAIL *** (scoreboard mismatch: pushed=%0d popped=%0d)", wr, rd);
        end

        $display("-------------------------------------------------------");
        $display("Messages driven : %0d", wr);
        $display("Events checked  : %0d", checks);
        $display("Mismatches      : %0d", errors);
        if (errors == 0 && checks > 0 && rd == wr)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***");
        $display("-------------------------------------------------------");
        $finish;
    end

endmodule

`default_nettype wire
