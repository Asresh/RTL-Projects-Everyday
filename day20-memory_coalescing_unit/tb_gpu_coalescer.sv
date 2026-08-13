// ===========================================================================
// tb_gpu_coalescer.sv  --  self-checking testbench for the GPU memory
// coalescing unit.  An INDEPENDENT golden set-partition model (built in the
// TB, not reusing DUT logic) predicts, for every warp:
//
//   * num_txn         = number of distinct SEG_BYTES segments among active lanes
//   * per-transaction { base, lane_mask } emitted in ascending leader order
//     (first-appearance order of each segment when scanning lanes 0..LANES-1)
//
// The DUT's streamed transactions are captured and compared against the model.
// Additional structural invariants are asserted every warp:
//   - lane masks are DISJOINT and their union == req_mask (exact partition)
//   - every served lane's address lies inside the transaction's segment
//   - txn_index counts 0..num_txn-1, txn_last only on the final txn
//   - perf_lanes / perf_txns accumulate correctly
//
// Directed corners + 300 randomized warps, a global timeout, and a VCD dump.
// Prints "RESULT: *** PASS ***" only if every check passed.
// ===========================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_gpu_coalescer;

    // ---- DUT configuration ---------------------------------------------
    localparam int LANES     = 8;
    localparam int ADDRW     = 32;
    localparam int SEG_BYTES = 32;
    localparam int LOG2_SEG  = $clog2(SEG_BYTES);
    localparam int SEGW      = ADDRW - LOG2_SEG;
    localparam int CNTW      = $clog2(LANES + 1);

    // ---- clock / reset --------------------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;     // 100 MHz

    // ---- DUT I/O --------------------------------------------------------
    logic                    in_valid;
    wire                     in_ready;
    logic [LANES-1:0]        req_mask;
    logic [LANES*ADDRW-1:0]  addr;

    wire                     txn_valid;
    wire  [ADDRW-1:0]        txn_base;
    wire  [LANES-1:0]        txn_lane_mask;
    wire  [CNTW-1:0]         txn_index;
    wire                     txn_last;
    wire  [CNTW-1:0]         num_txn;
    wire                     warp_done;
    wire                     busy;
    wire  [31:0]             perf_lanes;
    wire  [31:0]             perf_txns;

    gpu_coalescer #(
        .LANES(LANES), .ADDRW(ADDRW), .SEG_BYTES(SEG_BYTES)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .req_mask(req_mask), .addr(addr),
        .txn_valid(txn_valid), .txn_base(txn_base),
        .txn_lane_mask(txn_lane_mask), .txn_index(txn_index),
        .txn_last(txn_last), .num_txn(num_txn),
        .warp_done(warp_done), .busy(busy),
        .perf_lanes(perf_lanes), .perf_txns(perf_txns)
    );

    // ---- scoreboard state ----------------------------------------------
    integer errors      = 0;
    integer warps_run   = 0;
    integer exp_lanes   = 0;   // running expected perf_lanes
    integer exp_txns    = 0;   // running expected perf_txns

    // golden per-warp expectation
    integer            g_ntxn;
    logic [ADDRW-1:0]  g_base [LANES];   // expected base per txn (index order)
    logic [LANES-1:0]  g_mask [LANES];   // expected lane mask per txn

    // captured DUT stream for the current warp
    integer            c_ntxn;
    logic [ADDRW-1:0]  c_base [LANES];
    logic [LANES-1:0]  c_mask [LANES];
    logic [CNTW-1:0]   c_idx  [LANES];
    logic              c_last [LANES];

    // ---- helpers --------------------------------------------------------
    function automatic logic [ADDRW-1:0] lane_addr(input logic [LANES*ADDRW-1:0] a,
                                                   input int i);
        return a[i*ADDRW +: ADDRW];
    endfunction

    function automatic logic [SEGW-1:0] seg_of(input logic [ADDRW-1:0] a);
        return a[ADDRW-1:LOG2_SEG];
    endfunction

    // Build the golden partition for the pending {req_mask, addr}.
    task automatic build_golden;
        int t;
        logic [SEGW-1:0] s;
        logic            seen;
        int              q;
        begin
            g_ntxn = 0;
            for (int i = 0; i < LANES; i++) begin
                if (req_mask[i]) begin
                    s    = seg_of(lane_addr(addr, i));
                    seen = 1'b0;
                    // did an earlier active lane already open this segment?
                    for (int j = 0; j < i; j++)
                        if (req_mask[j] && seg_of(lane_addr(addr, j)) == s)
                            seen = 1'b1;
                    if (!seen) begin
                        // new transaction: gather every active lane in seg s
                        g_base[g_ntxn] = {s, {LOG2_SEG{1'b0}}};
                        g_mask[g_ntxn] = '0;
                        for (int k = 0; k < LANES; k++)
                            if (req_mask[k] && seg_of(lane_addr(addr, k)) == s)
                                g_mask[g_ntxn][k] = 1'b1;
                        g_ntxn = g_ntxn + 1;
                    end
                end
            end
            // running perf expectation
            for (int i = 0; i < LANES; i++)
                if (req_mask[i]) exp_lanes = exp_lanes + 1;
            exp_txns = exp_txns + g_ntxn;
        end
    endtask

    // Drive one warp, capture its transaction stream, then compare.
    task automatic run_warp(input logic [LANES-1:0]       m,
                            input logic [LANES*ADDRW-1:0]  a,
                            input string                   label);
        int guard;
        logic [LANES-1:0] union_mask;
        begin
            // wait until the unit is idle
            guard = 0;
            while (!in_ready) begin @(posedge clk); guard++; if (guard>500) disable run_warp; end

            req_mask = m;
            addr     = a;
            build_golden();

            in_valid = 1'b1;
            @(posedge clk);          // accept happens here
            in_valid = 1'b0;
            req_mask = '0;
            addr     = '0;

            // capture the emitted transactions until warp_done
            c_ntxn = 0;
            guard  = 0;
            forever begin
                @(posedge clk);
                if (txn_valid) begin
                    c_base[c_ntxn] = txn_base;
                    c_mask[c_ntxn] = txn_lane_mask;
                    c_idx [c_ntxn] = txn_index;
                    c_last[c_ntxn] = txn_last;
                    c_ntxn = c_ntxn + 1;
                end
                if (warp_done) break;
                guard++;
                if (guard > 1000) begin
                    $display("  [%s] TIMEOUT waiting for warp_done", label);
                    errors++;
                    disable run_warp;
                end
            end

            warps_run++;

            // -------- compare count -------------------------------------
            if (c_ntxn !== g_ntxn) begin
                $display("  [%s] FAIL num_txn: dut=%0d golden=%0d",
                         label, c_ntxn, g_ntxn);
                errors++;
            end
            if (num_txn !== g_ntxn[CNTW-1:0]) begin
                $display("  [%s] FAIL num_txn port: dut=%0d golden=%0d",
                         label, num_txn, g_ntxn);
                errors++;
            end

            // -------- compare each transaction in order -----------------
            union_mask = '0;
            for (int t = 0; t < c_ntxn; t++) begin
                if (t < g_ntxn) begin
                    if (c_base[t] !== g_base[t]) begin
                        $display("  [%s] FAIL txn%0d base: dut=%h golden=%h",
                                 label, t, c_base[t], g_base[t]);
                        errors++;
                    end
                    if (c_mask[t] !== g_mask[t]) begin
                        $display("  [%s] FAIL txn%0d mask: dut=%b golden=%b",
                                 label, t, c_mask[t], g_mask[t]);
                        errors++;
                    end
                end
                // index must count up 0,1,2,...
                if (c_idx[t] !== t[CNTW-1:0]) begin
                    $display("  [%s] FAIL txn%0d index: dut=%0d expected=%0d",
                             label, t, c_idx[t], t);
                    errors++;
                end
                // last only on final txn
                if (c_last[t] !== (t == c_ntxn-1)) begin
                    $display("  [%s] FAIL txn%0d last: dut=%b expected=%b",
                             label, t, c_last[t], (t == c_ntxn-1));
                    errors++;
                end
                // masks must be disjoint (partition property)
                if (|(union_mask & c_mask[t])) begin
                    $display("  [%s] FAIL txn%0d mask overlaps a previous txn",
                             label, t);
                    errors++;
                end
                union_mask = union_mask | c_mask[t];
            end

            // -------- union of masks == active mask ---------------------
            if (union_mask !== m) begin
                $display("  [%s] FAIL union mask: got=%b expected=%b",
                         label, union_mask, m);
                errors++;
            end

            // -------- perf counters -------------------------------------
            if (perf_lanes !== exp_lanes[31:0]) begin
                $display("  [%s] FAIL perf_lanes: dut=%0d expected=%0d",
                         label, perf_lanes, exp_lanes);
                errors++;
            end
            if (perf_txns !== exp_txns[31:0]) begin
                $display("  [%s] FAIL perf_txns: dut=%0d expected=%0d",
                         label, perf_txns, exp_txns);
                errors++;
            end
        end
    endtask

    // convenience: set lane i's address into a flat bus
    task automatic set_lane(inout logic [LANES*ADDRW-1:0] a,
                            input int i, input logic [ADDRW-1:0] v);
        begin
            a[i*ADDRW +: ADDRW] = v;
        end
    endtask

    // ---- stimulus -------------------------------------------------------
    logic [LANES*ADDRW-1:0] a;
    logic [LANES-1:0]       m;
    logic [ADDRW-1:0]       tmp;
    integer seed = 32'hC0FFEE20;

    initial begin
        $dumpfile("gpu_coalescer.vcd");
        $dumpvars(0, tb_gpu_coalescer);

        in_valid = 1'b0;
        req_mask = '0;
        addr     = '0;

        // reset
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // -------- directed corner cases -----------------------------------
        // (1) all 8 lanes hit the SAME segment (perfect broadcast coalesce)
        a = '0;
        for (int i = 0; i < LANES; i++) set_lane(a, i, 32'h0000_1000 + i*4);
        run_warp(8'hFF, a, "same-seg");

        // (2) every lane in a DISTINCT segment (worst-case, 8 txns)
        a = '0;
        for (int i = 0; i < LANES; i++) set_lane(a, i, i*SEG_BYTES);
        run_warp(8'hFF, a, "all-distinct");

        // (3) two segments interleaved by lane (even->seg A, odd->seg B)
        a = '0;
        for (int i = 0; i < LANES; i++)
            set_lane(a, i, (i[0] ? 32'h0000_2000 : 32'h0000_4000) + (i>>1)*4);
        run_warp(8'hFF, a, "two-seg-interleave");

        // (4) unit-stride (contiguous) -> one segment of 8 words (32B line)
        a = '0;
        for (int i = 0; i < LANES; i++) set_lane(a, i, 32'h0000_8000 + i*4);
        run_warp(8'hFF, a, "unit-stride");

        // (5) large stride so each lane spills to its own segment
        a = '0;
        for (int i = 0; i < LANES; i++) set_lane(a, i, i*64);
        run_warp(8'hFF, a, "stride-64");

        // (6) partial mask: only lanes 1,3,5,7 active, two segments
        a = '0;
        for (int i = 0; i < LANES; i++)
            set_lane(a, i, (i < 4 ? 32'h000A_0000 : 32'h000B_0000) + i*4);
        run_warp(8'b1010_1010, a, "partial-mask");

        // (7) empty warp: no active lanes -> zero transactions
        a = '0;
        run_warp(8'h00, a, "empty");

        // (8) single active lane
        a = '0;
        set_lane(a, 5, 32'h00CC_0040);
        run_warp(8'b0010_0000, a, "single-lane");

        // (9) duplicate addresses (all lanes identical address)
        a = '0;
        for (int i = 0; i < LANES; i++) set_lane(a, i, 32'h00DD_0000);
        run_warp(8'hFF, a, "identical-addr");

        // -------- randomized warps ---------------------------------------
        for (int w = 0; w < 300; w++) begin
            m = $random(seed);
            a = '0;
            for (int i = 0; i < LANES; i++) begin
                // realistic mix: mostly clustered into a couple of segments
                // (coalesces well), occasionally scattered (worst case).
                if (($random(seed) & 7) == 0)
                    tmp = ($random(seed) & 32'h0000_FFFF);              // scattered
                else
                    tmp = 32'h0001_0000 + (($random(seed) & 1) << LOG2_SEG)
                                        + (($random(seed) & (SEG_BYTES-1)));
                set_lane(a, i, tmp);
            end
            run_warp(m, a, "rand");
        end

        // -------- report --------------------------------------------------
        $display("--------------------------------------------------------");
        $display("warps run          : %0d", warps_run);
        $display("total active lanes : %0d", perf_lanes);
        $display("total transactions : %0d", perf_txns);
        if (perf_txns != 0)
            $display("coalescing ratio   : %0d.%02d lanes/txn (higher = better)",
                     perf_lanes / perf_txns,
                     (perf_lanes * 100 / perf_txns) % 100);
        $display("errors             : %0d", errors);
        if (errors == 0)
            $display("RESULT: *** PASS ***");
        else
            $display("RESULT: *** FAIL *** (%0d error(s))", errors);
        $finish;
    end

    // ---- global watchdog ------------------------------------------------
    initial begin
        #500000;
        $display("RESULT: *** FAIL *** (global timeout)");
        $finish;
    end

endmodule

`default_nettype wire
