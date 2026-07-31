// ---------------------------------------------------------------------------
// tb_tcam.sv -- self-checking testbench for the pipelined TCAM lookup engine.
//
// An independent behavioural GOLDEN MODEL keeps a shadow copy of every entry
// {key, mask, valid} and, for each search, performs a linear priority scan
//     first i with valid[i] && (((skey ^ key[i]) & mask[i]) == 0)
// to derive the expected {match, index, stored-key, full hit bitmap}. Because
// the DUT registers its result with a fixed 1-cycle latency, every `cycle()`
// applies the stimulus, samples the DUT result right after the clock edge, and
// checks it against the golden expectation computed from the pre-write shadow
// state (writes commit with nonblocking semantics, exactly like the RTL).
//
// Coverage: reset, empty-table miss, exact matches, priority (lowest index
// wins), wildcard "default route" entry, longest-prefix-match prefix masks,
// entry invalidate + overwrite, a back-to-back search throughput burst, and
// thousands of randomized interleaved write/search cycles.
//
// Prints  RESULT: *** PASS ***  on success and dumps tcam.vcd.
// ---------------------------------------------------------------------------
`default_nettype none
`timescale 1ns/1ps

module tb_tcam;

    // ---- parameters (match the DUT under test) ---------------------------
    localparam int DEPTH     = 16;
    localparam int KEY_WIDTH = 32;
    localparam int IDXW      = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    // ---- DUT I/O ---------------------------------------------------------
    logic                    clk, rst;
    logic                    we;
    logic [IDXW-1:0]         waddr;
    logic [KEY_WIDTH-1:0]    wkey, wmask;
    logic                    wvalid;
    logic                    search;
    logic [KEY_WIDTH-1:0]    skey;

    logic                    match_valid_o;
    logic                    match_o;
    logic [IDXW-1:0]         match_index_o;
    logic [KEY_WIDTH-1:0]    match_key_o;
    logic [DEPTH-1:0]        hit_map_o;

    tcam #(.DEPTH(DEPTH), .KEY_WIDTH(KEY_WIDTH)) dut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .wkey(wkey), .wmask(wmask), .wvalid(wvalid),
        .search(search), .skey(skey),
        .match_valid_o(match_valid_o), .match_o(match_o),
        .match_index_o(match_index_o), .match_key_o(match_key_o),
        .hit_map_o(hit_map_o)
    );

    // ---- clock -----------------------------------------------------------
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // ---- golden shadow model ---------------------------------------------
    logic [KEY_WIDTH-1:0] g_key  [DEPTH];
    logic [KEY_WIDTH-1:0] g_mask [DEPTH];
    logic                 g_valid[DEPTH];

    int   errors = 0;
    int   checks = 0;

    // linear priority scan == reference for the parallel-compare + encoder
    task automatic golden_search(
            input  logic [KEY_WIDTH-1:0] sk,
            output bit                   gm,
            output int                   gi,
            output logic [KEY_WIDTH-1:0] gk,
            output logic [DEPTH-1:0]     ghit);
        gm = 1'b0; gi = 0; gk = '0; ghit = '0;
        for (int i = 0; i < DEPTH; i++) begin
            if (g_valid[i] && (((sk ^ g_key[i]) & g_mask[i]) == '0)) begin
                ghit[i] = 1'b1;
                if (!gm) begin gm = 1'b1; gi = i; gk = g_key[i]; end // lowest idx
            end
        end
    endtask

    // ---- one cycle: optional write + optional search, then self-check ----
    task automatic cycle(
            input bit                    do_we,
            input logic [IDXW-1:0]       a,
            input logic [KEY_WIDTH-1:0]  k,
            input logic [KEY_WIDTH-1:0]  m,
            input bit                    v,
            input bit                    do_search,
            input logic [KEY_WIDTH-1:0]  sk);
        bit                   exp_m;
        int                   exp_i;
        logic [KEY_WIDTH-1:0] exp_k;
        logic [DEPTH-1:0]     exp_hit;

        @(negedge clk);
        we     = do_we;   waddr = a;  wkey = k;  wmask = m;  wvalid = v;
        search = do_search; skey = sk;

        // expected result uses the PRE-write shadow (RTL reads array before the
        // same-edge nonblocking write commits)
        golden_search(sk, exp_m, exp_i, exp_k, exp_hit);

        @(posedge clk);   // DUT registers the search result + commits the write
        #1;

        // check the registered search result of THIS cycle
        if (match_valid_o !== do_search) begin
            errors++;
            $display("[%0t] FAIL match_valid_o=%b exp=%b", $time,
                     match_valid_o, do_search);
        end
        if (do_search) begin
            checks++;
            if (match_o !== exp_m) begin
                errors++;
                $display("[%0t] FAIL match_o=%b exp=%b (skey=%h)",
                         $time, match_o, exp_m, sk);
            end else if (exp_m) begin
                if (match_index_o !== exp_i[IDXW-1:0]) begin
                    errors++;
                    $display("[%0t] FAIL index=%0d exp=%0d (skey=%h)",
                             $time, match_index_o, exp_i, sk);
                end
                if (match_key_o !== exp_k) begin
                    errors++;
                    $display("[%0t] FAIL key=%h exp=%h (idx=%0d)",
                             $time, match_key_o, exp_k, exp_i);
                end
            end
            if (hit_map_o !== exp_hit) begin
                errors++;
                $display("[%0t] FAIL hit_map=%b exp=%b (skey=%h)",
                         $time, hit_map_o, exp_hit, sk);
            end
        end

        // commit the write into the shadow (visible to later cycles)
        if (do_we) begin
            g_key[a]   = k;
            g_mask[a]  = m;
            g_valid[a] = v;
        end
    endtask

    // convenience wrappers -------------------------------------------------
    localparam logic [KEY_WIDTH-1:0] ALL1 = {KEY_WIDTH{1'b1}};

    task automatic wr(input logic [IDXW-1:0] a, input logic [KEY_WIDTH-1:0] k,
                      input logic [KEY_WIDTH-1:0] m, input bit v);
        cycle(1'b1, a, k, m, v, 1'b0, '0);
    endtask
    task automatic srch(input logic [KEY_WIDTH-1:0] sk);
        cycle(1'b0, '0, '0, '0, 1'b0, 1'b1, sk);
    endtask
    task automatic idle();
        cycle(1'b0, '0, '0, '0, 1'b0, 1'b0, '0);
    endtask

    // ---- stimulus --------------------------------------------------------
    integer seed = 32'hACE1_2024;
    logic [KEY_WIDTH-1:0] rk;
    int hits;

    initial begin
        $dumpfile("tcam.vcd");
        $dumpvars(0, tb_tcam);

        we=0; waddr=0; wkey=0; wmask=0; wvalid=0; search=0; skey=0;
        for (int i=0;i<DEPTH;i++) begin g_valid[i]=0; g_key[i]=0; g_mask[i]=0; end

        // ---- reset ----
        rst = 1'b1;
        repeat (3) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        // ------------------------------------------------------------------
        // 1) empty table -> every search misses
        // ------------------------------------------------------------------
        srch(32'hDEAD_BEEF);
        srch(32'h0000_0000);
        srch(32'hFFFF_FFFF);

        // ------------------------------------------------------------------
        // 2) exact-match entries (full care mask) at scattered addresses
        // ------------------------------------------------------------------
        wr(4'd3,  32'h1234_5678, ALL1, 1'b1);
        wr(4'd7,  32'hCAFE_F00D, ALL1, 1'b1);
        wr(4'd12, 32'h0BAD_C0DE, ALL1, 1'b1);
        srch(32'h1234_5678);   // -> idx 3
        srch(32'hCAFE_F00D);   // -> idx 7
        srch(32'h0BAD_C0DE);   // -> idx 12
        srch(32'h1234_5679);   // near-miss -> no hit

        // ------------------------------------------------------------------
        // 3) priority: lower index wins when several entries match
        //    two identical exact keys at idx 5 and idx 9 -> idx 5 wins
        // ------------------------------------------------------------------
        wr(4'd9, 32'hA5A5_A5A5, ALL1, 1'b1);
        wr(4'd5, 32'hA5A5_A5A5, ALL1, 1'b1);
        srch(32'hA5A5_A5A5);   // -> idx 5, hit_map has bits 5 and 9 set

        // ------------------------------------------------------------------
        // 4) wildcard "default route": entry 15 = full don't-care (matches all)
        //    a specific low entry still wins; an unrelated key falls to default
        // ------------------------------------------------------------------
        wr(4'd15, 32'h0000_0000, 32'h0000_0000, 1'b1); // mask=0 -> matches all
        srch(32'h1234_5678);   // specific idx 3 still wins over default
        srch(32'h9999_9999);   // no specific -> default idx 15
        srch(32'h0000_0001);   // -> default idx 15

        // ------------------------------------------------------------------
        // 5) longest-prefix-match style: contiguous MSB "care" masks, ordered
        //    longest prefix at the lowest index so priority == LPM.
        //    /24 at idx1, /16 at idx2, /8 at idx4  (network 0x0A.. = 10.x)
        // ------------------------------------------------------------------
        wr(4'd1, 32'h0A0B_0C00, 32'hFFFF_FF00, 1'b1); // 10.11.12.0/24
        wr(4'd2, 32'h0A0B_0000, 32'hFFFF_0000, 1'b1); // 10.11.0.0/16
        wr(4'd4, 32'h0A00_0000, 32'hFF00_0000, 1'b1); // 10.0.0.0/8
        srch(32'h0A0B_0C05);   // in /24  -> idx 1 (longest)
        srch(32'h0A0B_9905);   // in /16  -> idx 2
        srch(32'h0A77_8899);   // in /8   -> idx 4
        srch(32'h0B00_0000);   // outside 10.x -> falls to default idx 15

        // ------------------------------------------------------------------
        // 6) invalidate an entry -> it stops matching
        // ------------------------------------------------------------------
        wr(4'd3, 32'h1234_5678, ALL1, 1'b0);  // invalidate idx 3
        srch(32'h1234_5678);   // idx 3 gone -> now falls to default idx 15

        // ------------------------------------------------------------------
        // 7) overwrite an entry's value -> match target moves
        // ------------------------------------------------------------------
        wr(4'd7, 32'h1111_2222, ALL1, 1'b1);  // idx 7 re-keyed
        srch(32'hCAFE_F00D);   // old key gone -> default idx 15
        srch(32'h1111_2222);   // new key -> idx 7

        // ------------------------------------------------------------------
        // 8) back-to-back search throughput burst (1 lookup/clock)
        // ------------------------------------------------------------------
        srch(32'h1111_2222);   // idx 7
        srch(32'hA5A5_A5A5);   // idx 5
        srch(32'h0A0B_0C05);   // idx 1
        srch(32'h0A0B_9905);   // idx 2
        srch(32'hDEAD_0000);   // default idx 15

        // ------------------------------------------------------------------
        // 9) randomized interleaved write/search storm
        // ------------------------------------------------------------------
        for (int n = 0; n < 3000; n++) begin
            bit                    dw, ds, v;
            logic [IDXW-1:0]       a;
            logic [KEY_WIDTH-1:0]  k, m, sk;

            dw = ($urandom(seed) % 100) < 40;   // ~40% cycles write
            ds = ($urandom(seed) % 100) < 85;   // ~85% cycles search
            a  = $urandom(seed);
            v  = ($urandom(seed) % 100) < 80;   // mostly-valid entries
            k  = {$urandom(seed), $urandom(seed)};
            // bias keys into a small value space so searches actually hit
            k  = k & 32'h0000_00FF;
            // mask: mix of full-care, prefix, and sparse wildcard patterns
            case ($urandom(seed) % 4)
                0: m = ALL1;                              // exact
                1: m = 32'h0000_00F0;                     // partial care
                2: m = 32'h0000_0000;                     // full wildcard
                default: m = $urandom(seed) & 32'h0000_00FF;
            endcase
            sk = $urandom(seed) & 32'h0000_00FF;

            cycle(dw, a, k, m, v, ds, sk);
        end

        // ------------------------------------------------------------------
        // sanity: confirm the shadow saw at least some real hits during random
        // ------------------------------------------------------------------
        hits = 0;
        for (int i = 0; i < DEPTH; i++) if (g_valid[i]) hits++;

        // ---- verdict -----------------------------------------------------
        $display("--------------------------------------------------------");
        $display("tcam: DEPTH=%0d KEY_WIDTH=%0d  checks=%0d  errors=%0d",
                 DEPTH, KEY_WIDTH, checks, errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL ***  (%0d mismatch%s)",
                     errors, (errors==1)?"":"es");
        $display("--------------------------------------------------------");
        $finish;
    end

    // ---- global timeout --------------------------------------------------
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL ***  (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
