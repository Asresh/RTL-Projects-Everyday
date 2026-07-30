// ===========================================================================
// tb_smem_xbar.sv  --  self-checking testbench for the SIMT shared-memory
//                      bank-conflict resolution crossbar
// ---------------------------------------------------------------------------
// Golden reference model (pure software, computed in the TB):
//   * expected data   : mem_ref[addr] for every active lane.
//   * expected phases : for the active lanes, group by bank; within a bank
//                       count the number of DISTINCT addresses; the result is
//                       the maximum of those counts across banks.  Same-address
//                       lanes in a bank collapse to one (hardware broadcast).
//
// Stimulus: directed corner cases (conflict-free, full N-way conflict,
// full broadcast, mixed broadcast+conflict, partial mask, empty mask) followed
// by many randomized warps.  A watchdog aborts the sim if it ever hangs.
// A VCD is dumped so docs/render_waveform.py can plot a real captured trace.
//
// All per-lane vectors are passed as FLAT packed buses (lane 0 = LSBs); Icarus
// does not accept unpacked-array subroutine ports.
// ===========================================================================
`timescale 1ns/1ps

module tb_smem_xbar;

    localparam int LANES      = 8;
    localparam int BANKS      = 8;
    localparam int BANK_DEPTH = 32;
    localparam int DATA_W     = 16;
    localparam int ADDR_W     = $clog2(BANKS * BANK_DEPTH);
    localparam int WORDS      = BANKS * BANK_DEPTH;
    localparam int PHW        = $clog2(LANES + 1);
    localparam int BSEL       = $clog2(BANKS);

    // ---- DUT I/O ------------------------------------------------------------
    logic                    clk, rst_n;
    logic                    we;
    logic [ADDR_W-1:0]       waddr;
    logic [DATA_W-1:0]       wdata;
    logic                    req_valid;
    logic [LANES-1:0]        req_mask;
    logic [LANES*ADDR_W-1:0] req_addr;
    logic                    busy, resp_valid;
    logic [LANES-1:0]        resp_mask;
    logic [LANES*DATA_W-1:0] resp_data;
    logic [PHW-1:0]          resp_phases;

    smem_xbar #(
        .LANES(LANES), .BANKS(BANKS), .BANK_DEPTH(BANK_DEPTH), .DATA_W(DATA_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .we(we), .waddr(waddr), .wdata(wdata),
        .req_valid(req_valid), .req_mask(req_mask), .req_addr(req_addr),
        .busy(busy), .resp_valid(resp_valid), .resp_mask(resp_mask),
        .resp_data(resp_data), .resp_phases(resp_phases)
    );

    // ---- clock --------------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;                     // 100 MHz, 10 ns period

    // ---- golden memory image ------------------------------------------------
    logic [DATA_W-1:0] mem_ref [0:WORDS-1];

    // ---- scoreboard counters ------------------------------------------------
    integer errors = 0;
    integer checks = 0;

    // ---- helpers ------------------------------------------------------------
    task automatic do_write(input int aa, input logic [DATA_W-1:0] d);
        begin
            @(negedge clk);
            we    = 1'b1;
            waddr = aa[ADDR_W-1:0];
            wdata = d;
            mem_ref[aa] = d;
            @(negedge clk);
            we = 1'b0;
        end
    endtask

    // reference phase count for a warp (packed address bus + mask)
    function automatic int golden_phases(input logic [LANES-1:0] mask,
                                          input logic [LANES*ADDR_W-1:0] addr);
        int cnt [0:BANKS-1];
        logic [ADDR_W-1:0] seen [0:BANKS-1][0:LANES-1];
        logic [ADDR_W-1:0] ai;
        int b, i, k, maxp;
        logic dup;
        for (b = 0; b < BANKS; b++) cnt[b] = 0;
        for (i = 0; i < LANES; i++) begin
            if (mask[i]) begin
                ai  = addr[i*ADDR_W +: ADDR_W];
                b   = ai[BSEL-1:0];
                dup = 1'b0;
                for (k = 0; k < cnt[b]; k++)
                    if (seen[b][k] == ai) dup = 1'b1;
                if (!dup) begin
                    seen[b][cnt[b]] = ai;
                    cnt[b]          = cnt[b] + 1;
                end
            end
        end
        maxp = 0;
        for (b = 0; b < BANKS; b++)
            if (cnt[b] > maxp) maxp = cnt[b];
        return maxp;
    endfunction

    // launch a warp gather and check the result against the golden model
    task automatic run_warp(input string name,
                            input logic [LANES-1:0] mask,
                            input logic [LANES*ADDR_W-1:0] addr);
        int exp_phases, i, guard;
        logic [ADDR_W-1:0] ai;
        logic [DATA_W-1:0] got;
        begin
            // wait until the DUT is idle, then present the request for 1 cycle
            @(negedge clk);
            while (busy) @(negedge clk);
            req_valid = 1'b1;
            req_mask  = mask;
            req_addr  = addr;
            @(negedge clk);
            req_valid = 1'b0;

            // wait for the result strobe, with a bounded per-warp timeout
            guard = 0;
            while (!resp_valid && guard < (4*LANES + 20)) begin
                @(negedge clk);
                guard = guard + 1;
            end
            if (!resp_valid) begin
                errors = errors + 1;
                $display("  [%0t] ERROR (%s): timeout waiting for resp_valid",
                         $time, name);
            end

            exp_phases = golden_phases(mask, addr);

            // check phase count
            checks = checks + 1;
            if (resp_phases !== exp_phases[PHW-1:0]) begin
                errors = errors + 1;
                $display("  [%0t] ERROR (%s): phases got=%0d exp=%0d",
                         $time, name, resp_phases, exp_phases);
            end
            // check served mask
            checks = checks + 1;
            if (resp_mask !== mask) begin
                errors = errors + 1;
                $display("  [%0t] ERROR (%s): resp_mask got=%b exp=%b",
                         $time, name, resp_mask, mask);
            end
            // check every active lane's data
            for (i = 0; i < LANES; i++) begin
                if (mask[i]) begin
                    checks = checks + 1;
                    ai  = addr[i*ADDR_W +: ADDR_W];
                    got = resp_data[i*DATA_W +: DATA_W];
                    if (got !== mem_ref[ai]) begin
                        errors = errors + 1;
                        $display("  [%0t] ERROR (%s): lane %0d addr %0d got=%h exp=%h",
                                 $time, name, i, ai, got, mem_ref[ai]);
                    end
                end
            end
            $display("  [%0t] %-22s mask=%b phases=%0d (exp %0d)",
                     $time, name, mask, resp_phases, exp_phases);
        end
    endtask

    // set one lane's address field in the packed request bus
    task automatic set_lane(inout logic [LANES*ADDR_W-1:0] bus,
                            input int lane, input int val);
        bus[lane*ADDR_W +: ADDR_W] = val[ADDR_W-1:0];
    endtask

    // ---- stimulus -----------------------------------------------------------
    logic [LANES*ADDR_W-1:0] a;
    integer t, i, w;
    int seed = 32'hC0FFEE16;
    logic [LANES-1:0] m;

    initial begin
        $dumpfile("smem_xbar.vcd");
        $dumpvars(0, tb_smem_xbar);

        // init
        we = 0; waddr = 0; wdata = 0;
        req_valid = 0; req_mask = 0; req_addr = 0;
        rst_n = 0;
        repeat (3) @(negedge clk);
        rst_n = 1;
        @(negedge clk);

        // preload the scratchpad: mem[addr] = addr*7 + 0xA5 (mod 2^DATA_W)
        for (t = 0; t < WORDS; t++)
            do_write(t, (t*7 + 16'hA5) & {DATA_W{1'b1}});

        $display("\n--- directed cases ---");

        // 1) conflict-free: lane i -> bank i, distinct rows  => 1 phase
        for (i = 0; i < LANES; i++) set_lane(a, i, i + i*BANKS);   // bank=i, row=i
        run_warp("conflict-free", {LANES{1'b1}}, a);

        // 2) full N-way conflict: every lane -> bank 0, distinct rows => LANES phases
        for (i = 0; i < LANES; i++) set_lane(a, i, i*BANKS);       // bank=0, row=i
        run_warp("8-way conflict", {LANES{1'b1}}, a);

        // 3) full broadcast: every lane -> the SAME address       => 1 phase
        for (i = 0; i < LANES; i++) set_lane(a, i, 5*BANKS + 3);   // bank=3, row=5
        run_warp("full broadcast", {LANES{1'b1}}, a);

        // 4) mixed: bank 2 hit by 4 lanes at 2 distinct addrs (2-way),
        //    the other 4 lanes conflict-free                      => 2 phases
        set_lane(a, 0, 2);            set_lane(a, 1, 2);            // bank2 row0 (bcast pair)
        set_lane(a, 2, 2 + 2*BANKS);  set_lane(a, 3, 2 + 2*BANKS); // bank2 row2 (bcast pair)
        set_lane(a, 4, 4); set_lane(a, 5, 5);                      // banks 4,5
        set_lane(a, 6, 6); set_lane(a, 7, 7);                      // banks 6,7
        run_warp("mixed bcast+conflict", {LANES{1'b1}}, a);

        // 5) partial mask: only lanes 0,2,4,6 active, all -> bank 1, distinct rows
        for (i = 0; i < LANES; i++) set_lane(a, i, 1 + i*BANKS);   // bank=1
        run_warp("partial mask", 8'b01010101, a);

        // 6) empty mask: no active lanes                          => 0 phases
        for (i = 0; i < LANES; i++) set_lane(a, i, i);
        run_warp("empty mask", 8'b0, a);

        $display("\n--- randomized warps ---");
        for (w = 0; w < 200; w++) begin
            m = $random(seed);
            for (i = 0; i < LANES; i++)
                set_lane(a, i, $unsigned($random(seed)) % WORDS);
            run_warp($sformatf("rand[%0d]", w), m, a);
        end

        $display("\n=====================================================");
        $display(" checks run : %0d", checks);
        $display(" errors     : %0d", errors);
        if (errors == 0)
            $display(" RESULT: *** PASS ***");
        else
            $display(" RESULT: *** FAIL ***");
        $display("=====================================================\n");
        $finish;
    end

    // ---- global watchdog ----------------------------------------------------
    initial begin
        #2_000_000;                    // 2 ms hard ceiling
        $display(" RESULT: *** FAIL *** (global watchdog timeout)");
        $finish;
    end

endmodule
