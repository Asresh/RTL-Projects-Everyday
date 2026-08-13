// ---------------------------------------------------------------------------
// Day 39 : self-checking testbench for l1_dcache_4way
//
// Verification strategy
// ---------------------
//  * A behavioural burst MAIN MEMORY model with randomised latency and
//    randomised write backpressure sits on the cache's memory port. It is the
//    only place data physically lives.
//  * An independent GOLDEN ARCHITECTURAL MEMORY (`gold[]`) is updated on every
//    CPU store with the same byte enables. Every CPU load is compared against
//    it, so the cache must behave exactly like a flat memory no matter how the
//    lines migrate, get merged, evicted or written back.
//  * `mem[]` starts as an exact copy of `gold[]`; after a full flush the two
//    must be identical again over the WHOLE memory -- that check is what
//    actually proves the dirty-bit tracking and the writeback path.
//
// Directed tests
//   T1  cold read sweep            : every access misses, data must be right
//   T2  re-read the same lines     : every access hits, ZERO memory traffic
//   T3  back-to-back streaming hits: cpu_ack every cycle (1 req/clk)
//   T4  byte-enable store merging  : partial writes + read back
//   T5  write-allocate on store miss
//   T6  true-LRU victim selection  : observed writeback address must be the
//                                    least-recently-USED line, which is a
//                                    different way than FIFO/round-robin picks
//   T7  clean flush                : mem[] == gold[] everywhere
//   T8  randomised soak            : 600 random loads/stores over a window 2x
//                                    the cache size (constant thrashing), then
//                                    a final flush + whole-memory compare
// ---------------------------------------------------------------------------

`timescale 1ns/1ps
`default_nettype none

module tb_l1_dcache_4way;

    // ---------------- geometry (must match the DUT instance) ----------------
    localparam int ADDR_W = 32;
    localparam int DATA_W = 32;
    localparam int WAYS   = 4;
    localparam int SETS   = 64;
    localparam int WPL    = 4;                       // words per line

    localparam int BE_W       = DATA_W/8;
    localparam int LINE_BYTES = WPL*BE_W;            // 16
    localparam int SET_STRIDE = SETS*LINE_BYTES;     // 1024 -> conflict stride
    localparam int CACHE_BYTES= WAYS*SET_STRIDE;     // 4096
    localparam int MEM_WORDS  = 4096;                // 16 KB of main memory
    localparam int SOAK_BYTES = 2*CACHE_BYTES;       // random-window size

    // ---------------- clock / reset ----------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;                            // 100 MHz

    // ---------------- DUT wiring ------------------------------------------
    logic                cpu_req, cpu_we;
    logic [ADDR_W-1:0]   cpu_addr;
    logic [DATA_W-1:0]   cpu_wdata;
    logic [BE_W-1:0]     cpu_be;
    wire  [DATA_W-1:0]   cpu_rdata;
    wire                 cpu_ack;

    logic                flush_req;
    wire                 flush_busy, flush_done;

    wire                 mem_rd_req, mem_wr_req;
    wire  [ADDR_W-1:0]   mem_addr;
    wire  [DATA_W-1:0]   mem_wdata;
    wire                 mem_wvalid;
    logic                mem_wready;
    logic [DATA_W-1:0]   mem_rdata;
    logic                mem_rvalid;

    wire                 ev_hit, ev_miss, ev_wb;

    l1_dcache_4way #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W),
        .WAYS(WAYS), .SETS(SETS), .WORDS_PER_LINE(WPL)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cpu_req(cpu_req), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
        .cpu_wdata(cpu_wdata), .cpu_be(cpu_be),
        .cpu_rdata(cpu_rdata), .cpu_ack(cpu_ack),
        .flush_req(flush_req), .flush_busy(flush_busy), .flush_done(flush_done),
        .mem_rd_req(mem_rd_req), .mem_wr_req(mem_wr_req), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wvalid(mem_wvalid), .mem_wready(mem_wready),
        .mem_rdata(mem_rdata), .mem_rvalid(mem_rvalid),
        .ev_hit(ev_hit), .ev_miss(ev_miss), .ev_wb(ev_wb)
    );

    // ---------------- memories --------------------------------------------
    logic [DATA_W-1:0] mem  [0:MEM_WORDS-1];   // physical main memory
    logic [DATA_W-1:0] gold [0:MEM_WORDS-1];   // golden architectural state

    // ---------------- scoreboard counters ---------------------------------
    integer checks  = 0;
    integer errors  = 0;
    integer n_hit   = 0;
    integer n_miss  = 0;
    integer n_wb    = 0;
    integer n_rdbst = 0;
    integer n_wrbst = 0;
    logic [ADDR_W-1:0] last_wb_addr = '0;

    always @(posedge clk) begin
        if (ev_hit)     n_hit   <= n_hit + 1;
        if (ev_miss)    n_miss  <= n_miss + 1;
        if (ev_wb)      n_wb    <= n_wb + 1;
        if (mem_rd_req) n_rdbst <= n_rdbst + 1;
        if (mem_wr_req) begin
            n_wrbst      <= n_wrbst + 1;
            last_wb_addr <= mem_addr;            // observe the evicted line
        end
    end

    task automatic fail(input string what);
        begin
            errors = errors + 1;
            $display("  [FAIL] %s   (t=%0t)", what, $time);
        end
    endtask

    task automatic expect_eq(input [DATA_W-1:0] got,
                             input [DATA_W-1:0] exp,
                             input string       what);
        begin
            checks = checks + 1;
            if (got !== exp)
                fail($sformatf("%s : got %08h expected %08h", what, got, exp));
        end
    endtask

    // ======================================================================
    // behavioural burst main memory
    // ======================================================================
    // read burst: WPL beats, word 0 first, random start latency + random gaps
    integer rd_base, rd_lat, rb;
    initial begin
        mem_rvalid = 1'b0;
        mem_rdata  = '0;
        forever begin
            @(posedge clk);
            if (mem_rd_req) begin
                rd_base = mem_addr >> $clog2(BE_W);
                rd_lat  = $urandom_range(0, 3);
                repeat (rd_lat) @(posedge clk);
                for (rb = 0; rb < WPL; rb = rb + 1) begin
                    if ($urandom_range(0, 3) == 0) begin   // bubble between beats
                        mem_rvalid <= 1'b0;
                        @(posedge clk);
                    end
                    mem_rvalid <= 1'b1;
                    mem_rdata  <= mem[rd_base + rb];
                    @(posedge clk);
                end
                mem_rvalid <= 1'b0;
            end
        end
    end

    // write burst: accept WPL beats with random backpressure on mem_wready
    integer wr_base;
    logic [$clog2(WPL):0] wr_beat;
    always @(posedge clk) begin
        if (mem_wr_req) begin
            wr_base <= mem_addr >> $clog2(BE_W);
            wr_beat <= '0;
        end else if (mem_wvalid && mem_wready) begin
            mem[wr_base + wr_beat] <= mem_wdata;
            wr_beat                <= wr_beat + 1'b1;
        end
    end
    always @(posedge clk) mem_wready <= ($urandom_range(0, 3) != 0);

    // ======================================================================
    // CPU bus-functional model
    // ======================================================================
    task automatic bus_idle;
        begin
            cpu_req   <= 1'b0;
            cpu_we    <= 1'b0;
            cpu_be    <= '0;
            cpu_addr  <= '0;
            cpu_wdata <= '0;
        end
    endtask

    // load: drive the request, wait for ack, self-check against gold[]
    task automatic ld(input [ADDR_W-1:0] a);
        begin
            cpu_addr  <= a;
            cpu_wdata <= '0;
            cpu_be    <= '0;
            cpu_we    <= 1'b0;
            cpu_req   <= 1'b1;
            @(posedge clk);
            while (!cpu_ack) @(posedge clk);
            expect_eq(cpu_rdata, gold[a >> $clog2(BE_W)],
                      $sformatf("load @%08h", a));
            cpu_req <= 1'b0;
        end
    endtask

    // store with byte enables: update gold[] the same way
    task automatic st(input [ADDR_W-1:0] a,
                      input [DATA_W-1:0] d,
                      input [BE_W-1:0]   be);
        integer b;
        begin
            cpu_addr  <= a;
            cpu_wdata <= d;
            cpu_be    <= be;
            cpu_we    <= 1'b1;
            cpu_req   <= 1'b1;
            @(posedge clk);
            while (!cpu_ack) @(posedge clk);
            cpu_req <= 1'b0;
            cpu_we  <= 1'b0;
            for (b = 0; b < BE_W; b = b + 1)
                if (be[b]) gold[a >> $clog2(BE_W)][b*8 +: 8] = d[b*8 +: 8];
        end
    endtask

    // ======================================================================
    // helpers
    // ======================================================================
    // address of line `t` (tag number) in set `i`
    function automatic [ADDR_W-1:0] conflict_addr(input integer t, input integer i);
        conflict_addr = t*SET_STRIDE + i*LINE_BYTES;
    endfunction

    task automatic do_flush;
        begin
            flush_req <= 1'b1;
            @(posedge clk);
            flush_req <= 1'b0;
            while (!flush_done) @(posedge clk);
            @(posedge clk);
        end
    endtask

    task automatic compare_memory(input string tag);
        integer i, bad;
        begin
            bad = 0;
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                checks = checks + 1;
                if (mem[i] !== gold[i]) begin
                    bad = bad + 1;
                    if (bad <= 6)
                        fail($sformatf("%s: mem[%0d]=%08h gold=%08h",
                                       tag, i, mem[i], gold[i]));
                end
            end
            if (bad > 6) errors = errors + 1;
            if (bad == 0)
                $display("  %-34s all %0d memory words match golden state", tag, MEM_WORDS);
        end
    endtask

    // ======================================================================
    // stimulus
    // ======================================================================
    integer i, k, t, w;
    integer m0, h0, r0, seed_i;
    logic [DATA_W-1:0] rd;
    logic [ADDR_W-1:0] a, a0, a1, a2, a3, a4, a5;
    logic [ADDR_W-1:0] exp_vic;

    initial begin
        $dumpfile("l1_dcache_4way.vcd");
        $dumpvars(1, dut);

        // deterministic random memory image, mirrored into the golden model
        seed_i = 32'h0DCA_0039;
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            mem[i]  = $random(seed_i);
            gold[i] = mem[i];
        end

        bus_idle();
        flush_req = 1'b0;
        rst_n     = 1'b0;
        repeat (4) @(posedge clk);
        rst_n     = 1'b1;
        @(posedge clk);

        $display("========================================================");
        $display("Day 39  4-way set-associative write-back L1 data cache");
        $display("  %0d sets x %0d ways x %0d B lines = %0d B cache",
                 SETS, WAYS, LINE_BYTES, CACHE_BYTES);
        $display("========================================================");

        // -------------------------------------------------------------- T1
        // cold sweep: 8 different lines, every FIRST word access must miss
        m0 = n_miss;
        for (k = 0; k < 8; k = k + 1)
            for (w = 0; w < WPL; w = w + 1)
                ld(k*LINE_BYTES + w*BE_W);
        checks = checks + 1;
        if ((n_miss - m0) != 8)
            fail($sformatf("T1 cold sweep: expected 8 misses, saw %0d", n_miss-m0));
        else
            $display("  T1 cold read sweep                 8 compulsory misses, 32 words verified");

        // -------------------------------------------------------------- T2
        // the same 8 lines are now resident: all hits, and NO memory traffic
        h0 = n_hit; m0 = n_miss; r0 = n_rdbst + n_wrbst;
        for (k = 0; k < 8; k = k + 1)
            for (w = 0; w < WPL; w = w + 1)
                ld(k*LINE_BYTES + w*BE_W);
        checks = checks + 2;
        if ((n_hit - h0) != 32 || (n_miss - m0) != 0)
            fail($sformatf("T2 warm sweep: %0d hits / %0d misses (want 32/0)",
                           n_hit-h0, n_miss-m0));
        if ((n_rdbst + n_wrbst - r0) != 0)
            fail("T2 warm sweep generated memory traffic on a pure hit stream");
        $display("  T2 warm re-read                    32/32 hits, zero memory bursts");

        // -------------------------------------------------------------- T3
        // back-to-back streaming: cpu_req stays high, a new address every
        // cycle, and a hit must be acknowledged in that very same cycle.
        cpu_we   <= 1'b0;
        cpu_be   <= '0;
        cpu_req  <= 1'b1;
        cpu_addr <= 32'h0;
        @(posedge clk);
        for (i = 0; i < 16; i = i + 1) begin
            checks = checks + 1;
            if (!cpu_ack)
                fail($sformatf("T3 streaming hit %0d was not acked in-cycle", i));
            expect_eq(cpu_rdata, gold[i], $sformatf("T3 streamed word %0d", i));
            cpu_addr <= (i+1)*BE_W;
            @(posedge clk);
        end
        cpu_req <= 1'b0;
        @(posedge clk);
        $display("  T3 back-to-back hit stream         16 words in 16 cycles (1 req/clk)");

        // -------------------------------------------------------------- T4
        // byte-enable merging into a resident (hit) line
        st(32'h0000_0010, 32'hDEAD_BEEF, 4'b0011);   // low half only
        st(32'h0000_0010, 32'h1234_5678, 4'b1000);   // top byte only
        st(32'h0000_0014, 32'hA5A5_5A5A, 4'b1111);   // whole word
        st(32'h0000_0017, 32'h0000_0099, 4'b0001);   // unaligned byte address
        for (w = 0; w < WPL; w = w + 1) ld(32'h0000_0010 + w*BE_W);
        $display("  T4 byte-enable store merging       partial writes read back OK");

        // -------------------------------------------------------------- T5
        // write-allocate: store to a line that is NOT resident
        m0 = n_miss;
        st(32'h0000_2000, 32'hCAFE_F00D, 4'b1111);
        checks = checks + 1;
        if ((n_miss - m0) != 1) fail("T5 store miss did not register as a miss");
        ld(32'h0000_2000);                     // merged store must be visible
        ld(32'h0000_2004);                     // rest of the line came from memory
        $display("  T5 write-allocate store miss       line refilled + store merged");

        // -------------------------------------------------------------- T6
        // true-LRU victim selection, on an untouched set (index 33).
        // Fill all 4 ways with DIRTY lines so an eviction is observable as a
        // writeback burst, then re-touch the OLDEST way. A FIFO/round-robin
        // policy would still evict that re-touched line; true LRU must not.
        a0 = conflict_addr(0, 33);
        a1 = conflict_addr(1, 33);
        a2 = conflict_addr(2, 33);
        a3 = conflict_addr(3, 33);
        a4 = conflict_addr(4, 33);
        a5 = conflict_addr(5, 33);

        st(a0, 32'h1111_1111, 4'b1111);        // way fills, all dirty
        st(a1, 32'h2222_2222, 4'b1111);
        st(a2, 32'h3333_3333, 4'b1111);
        st(a3, 32'h4444_4444, 4'b1111);

        ld(a0);                                // a0: LRU -> MRU. LRU is now a1
        n_wrbst = n_wrbst;                     // (no traffic expected on a hit)
        ld(a4);                                // forces one eviction
        checks = checks + 1;
        if (last_wb_addr !== a1)
            fail($sformatf("T6 LRU victim: evicted %08h, true-LRU line was %08h",
                           last_wb_addr, a1));
        else
            $display("  T6 true-LRU victim #1              evicted %08h (LRU), not %08h (FIFO)", a1, a0);

        // ranks now: a4=MRU, a0, a3, a2=LRU  -> touch a3, LRU stays a2
        ld(a3);
        ld(a5);
        checks = checks + 1;
        if (last_wb_addr !== a2)
            fail($sformatf("T6 LRU victim #2: evicted %08h, expected %08h",
                           last_wb_addr, a2));
        else
            $display("  T6 true-LRU victim #2              evicted %08h (LRU)", a2);

        // the evicted-and-modified lines must still read back correctly
        ld(a0); ld(a1); ld(a2); ld(a3);

        // -------------------------------------------------------------- T7
        do_flush();
        compare_memory("T7 clean flush");
        // a clean flush keeps lines valid: this must still hit, not miss
        m0 = n_miss;
        ld(32'h0000_0010);
        checks = checks + 1;
        if ((n_miss - m0) != 0)
            fail("T7 clean flush invalidated a line (should stay resident)");

        // -------------------------------------------------------------- T8
        // randomised soak over a window twice the cache size -> permanent
        // conflict misses, evictions and writebacks
        for (i = 0; i < 600; i = i + 1) begin
            a = ($urandom_range(0, SOAK_BYTES/BE_W - 1)) * BE_W;
            if ($urandom_range(0, 1)) begin
                st(a, $urandom, $urandom_range(1, 15));
            end else begin
                ld(a);
            end
        end
        $display("  T8 randomised soak                 600 mixed ops, %0d misses / %0d writebacks so far", n_miss, n_wb);

        do_flush();
        compare_memory("T8 post-soak flush");

        // -------------------------------------------------------------- done
        repeat (4) @(posedge clk);
        $display("--------------------------------------------------------");
        $display("Day 39  4-way set-associative write-back L1 D-cache");
        $display("  hits / misses        : %0d / %0d", n_hit, n_miss);
        $display("  refill bursts        : %0d", n_rdbst);
        $display("  writeback bursts     : %0d", n_wrbst);
        $display("  checks performed     : %0d", checks);
        $display("  mismatches           : %0d", errors);
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL ***");
        $display("--------------------------------------------------------");
        $finish;
    end

    // global watchdog
    initial begin
        #3000000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
