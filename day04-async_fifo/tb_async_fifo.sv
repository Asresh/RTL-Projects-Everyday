// -----------------------------------------------------------------------------
// Day 4 - tb_async_fifo
// Self-checking testbench for the dual-clock (asynchronous) FIFO.
//
// Two independent, asynchronous clocks drive the write and read ports. A golden
// reference model (an unbounded SystemVerilog queue) tracks the exact order of
// accepted writes; every accepted read is checked against the front of that
// queue, so the scoreboard is fully independent of the DUT internals.
//
// Invariants checked continuously:
//   * DATA INTEGRITY  - each read returns the oldest not-yet-read written word.
//   * NO UNDERFLOW    - the DUT never lets a read fire while it reports empty
//                       (checked implicitly: rempty gates the read scoreboard,
//                        and a read that fires with an empty model is an error).
//   * NO OVERFLOW     - the model never exceeds DEPTH entries (wfull must have
//                       blocked the extra write).
//
// Directed phases exercise the exact full/empty boundaries; a randomized phase
// (run once writer-fast, once reader-fast) exercises the CDC under stress.
// A global timeout backstop and a VCD dump are included.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_async_fifo;

    localparam int DW    = 8;
    localparam int AW    = 4;
    localparam int DEPTH = 1 << AW;

    // ------------------------------------------------------------------ DUT I/O
    logic          wclk = 1'b0, rclk = 1'b0;
    logic          wrst_n, rrst_n;
    logic          wr_en;
    logic [DW-1:0] wdata;
    logic          wfull;
    logic          rd_en;
    logic [DW-1:0] rdata;
    logic          rempty;

    async_fifo #(.DATA_WIDTH(DW), .ADDR_WIDTH(AW)) dut (
        .wclk (wclk),  .wrst_n(wrst_n), .wr_en(wr_en), .wdata(wdata), .wfull (wfull),
        .rclk (rclk),  .rrst_n(rrst_n), .rd_en(rd_en), .rdata(rdata), .rempty(rempty)
    );

    // ---------------------------------------------------- independent clock gens
    // Half-periods are variables so the two domains can be re-skewed per phase.
    real whalf = 5.0;   // write clock half-period (ns)
    real rhalf = 7.0;   // read  clock half-period (ns)
    always begin #(whalf) wclk = ~wclk; end
    always begin #(rhalf) rclk = ~rclk; end

    // ------------------------------------------------------------- golden model
    logic [DW-1:0] model [$];
    int            checks = 0;
    int            errors = 0;

    task automatic flag_error(input string msg);
        errors++;
        $display("[%0t] ERROR: %s", $time, msg);
    endtask

    // Write scoreboard: record every accepted write, in the write clock domain.
    always @(posedge wclk) begin
        if (wrst_n && wr_en && !wfull) begin
            model.push_back(wdata);
            if (model.size() > DEPTH)
                flag_error($sformatf("OVERFLOW: model depth %0d > DEPTH %0d",
                                     model.size(), DEPTH));
        end
    end

    // Read scoreboard: check every accepted read, in the read clock domain.
    // At the posedge, rdata/rempty still reflect the pre-edge state (DUT regs
    // update in the NBA region), so this consumes the correct word.
    always @(posedge rclk) begin
        logic [DW-1:0] exp;
        if (rrst_n && rd_en && !rempty) begin
            if (model.size() == 0) begin
                flag_error("UNDERFLOW: read fired but model is empty");
            end else begin
                exp    = model.pop_front();
                checks++;
                if (rdata !== exp)
                    flag_error($sformatf("DATA MISMATCH: got %02h exp %02h",
                                         rdata, exp));
            end
        end
    end

    // --------------------------------------------------------- stimulus drivers
    // Enables are updated on the *negedge* of their own clock so they are stable
    // at the posedge where both the DUT and the scoreboards sample them.

    task automatic reset_all();
        wr_en = 1'b0; rd_en = 1'b0; wdata = '0;
        wrst_n = 1'b0; rrst_n = 1'b0;
        repeat (4) @(negedge wclk);
        repeat (4) @(negedge rclk);
        wrst_n = 1'b1; rrst_n = 1'b1;
        @(negedge wclk); @(negedge rclk);
        if (!rempty) flag_error("rempty should be high right after reset");
        else         checks++;
        if (wfull)   flag_error("wfull should be low right after reset");
        else         checks++;
        model.delete();
    endtask

    // Directed: write with reads off until the FIFO reports full.
    // Reads are stopped first, then we let the read pointer finish crossing into
    // the write domain (2-flop synchronizer latency) so wfull is evaluated
    // against the settled read pointer and asserts exactly at DEPTH entries.
    task automatic fill_until_full();
        int guard = 0;
        rd_en = 1'b0;
        repeat (5) @(negedge wclk);   // let rptr settle into the write domain
        while (!wfull && guard < 4*DEPTH) begin
            wr_en = 1'b1;
            wdata = $urandom;
            @(negedge wclk);
            guard++;
        end
        wr_en = 1'b0;
        @(negedge wclk);
        if (!wfull)                flag_error("FIFO never asserted wfull");
        else                       checks++;
        if (model.size() != DEPTH) flag_error($sformatf(
            "after fill, model has %0d entries (expected %0d)", model.size(), DEPTH));
        else                       checks++;
    endtask

    // Directed: read with writes off until the FIFO reports empty.
    // Writes are stopped first, then we let the write pointer finish crossing
    // into the read domain (2-flop synchronizer latency) before draining, so a
    // just-written word is visible to the read side and rempty is trustworthy.
    task automatic drain_until_empty();
        int guard = 0;
        wr_en = 1'b0;
        repeat (5) @(negedge rclk);   // let wptr settle into the read domain
        while (!rempty && guard < 4*DEPTH) begin
            rd_en = 1'b1;
            @(negedge rclk);
            guard++;
        end
        rd_en = 1'b0;
        @(negedge rclk);
        if (!rempty)              flag_error("FIFO never asserted rempty");
        else                      checks++;
        if (model.size() != 0)    flag_error($sformatf(
            "after drain, model still has %0d entries", model.size()));
        else                      checks++;
    endtask

    // Randomized: independent random enables on each clock for a while, then
    // stop writing and drain so the scoreboard sees every remaining word.
    task automatic random_traffic(input int wcycles, input int rcycles);
        fork
            begin : WR
                for (int i = 0; i < wcycles; i++) begin
                    @(negedge wclk);
                    wr_en = ($urandom % 100) < 70;   // ~70% write attempts
                    wdata = $urandom;
                end
                wr_en = 1'b0;
            end
            begin : RD
                for (int i = 0; i < rcycles; i++) begin
                    @(negedge rclk);
                    rd_en = ($urandom % 100) < 60;   // ~60% read attempts
                end
            end
        join
        // fully drain whatever is left, checking each word
        drain_until_empty();
    endtask

    // ---------------------------------------------------------------- main test
    initial begin
        $dumpfile("async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        $display("=== Day 4 : async_fifo self-checking testbench ===");

        // Phase 1 - reset behaviour
        reset_all();

        // Phase 2 - directed fill to full, then drain to empty (exact boundaries)
        fill_until_full();
        drain_until_empty();

        // Phase 3 - random traffic, writer faster than reader (stresses FULL)
        whalf = 3.0; rhalf = 8.0;
        random_traffic(1500, 1500);

        // Phase 4 - random traffic, reader faster than writer (stresses EMPTY)
        whalf = 9.0; rhalf = 3.0;
        random_traffic(1500, 1500);

        // Phase 5 - matched clocks, back-to-back one more time for good measure
        whalf = 5.0; rhalf = 5.0;
        fill_until_full();
        random_traffic(800, 1200);

        $display("-----------------------------------------------");
        $display("Checks performed : %0d", checks);
        $display("Errors           : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $finish;
    end

    // ------------------------------------------------------------------- timeout
    initial begin
        #2_000_000;   // 2 ms of simulated time
        $display("Checks performed : %0d", checks);
        $display("Errors           : %0d (TIMEOUT)", errors + 1);
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
