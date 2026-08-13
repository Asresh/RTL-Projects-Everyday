// ---------------------------------------------------------------------------
// Day 45 - self-checking testbench for the MESI snooping coherence complex
//
// Three independent checkers constrain the design from different directions.
// None of them predicts the *schedule* - arbitration order and intervention
// are the features under test - they constrain the observable results instead:
//
//   1. Golden word memory.  Every core operation is checked against a flat
//      reference memory.  A per-line software lock keeps at most one operation
//      in flight per coherence line, so every load has exactly one legal
//      value and any lost store or stale hit shows up immediately.
//   2. Cycle-level coherence invariant checker.  Decodes every cache's MESI
//      state and tag out of the debug buses and proves, at every bus commit
//      and periodically in between:
//          I1  at most one cache holds a line in M or E
//          I2  an M or E copy is the ONLY valid copy of that line
//          I3  backing memory matches the golden memory for every line that
//              no cache currently holds in M
//   3. Protocol-event checker.  Directed phases assert the exact bus traffic a
//      correct MESI implementation must generate: how many BusRd / BusRdX /
//      BusUpgr / writeback transactions, how many cache-to-cache transfers,
//      and - the sharpest check in the file - that an E->M upgrade generates
//      *zero* bus transactions.
//
// Stimulus: nine directed phases (E fill, silent upgrade, intervention,
// BusUpgr, BusRdX-on-dirty, dirty eviction, the simultaneous-upgrade race,
// false-sharing ping-pong) then a four-core randomized soak, then a
// conflict-eviction drain and a backdoor memory compare.  A watchdog bounds
// the whole run.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_mesi_snoop_coherence;

  // ---------------------------------------------------------------------------
  // Geometry
  // ---------------------------------------------------------------------------
  localparam int NUM_CORES  = 4;
  localparam int SETS       = 8;
  localparam int WAYS       = 2;
  localparam int LINE_WORDS = 4;
  localparam int DATA_W     = 32;
  localparam int TAG_W      = 4;
  localparam int C2C_LAT    = 2;

  localparam int SIDX    = $clog2(SETS);
  localparam int WOFF    = $clog2(LINE_WORDS);
  localparam int CSEL    = $clog2(NUM_CORES);
  localparam int ADDR_W  = TAG_W + SIDX + WOFF;
  localparam int LADDR_W = TAG_W + SIDX;
  localparam int LINE_W  = LINE_WORDS * DATA_W;
  localparam int NTAGS   = 1 << TAG_W;
  localparam int NLINES  = 1 << LADDR_W;
  localparam int NWORDS  = NLINES * LINE_WORDS;

  // The top WAYS+1 tags are reserved for the conflict-eviction drain, so
  // ordinary traffic never allocates into them.  WAYS+1 and not WAYS: with
  // invalid-ways-first replacement the round-robin pointer does not
  // necessarily alternate, so WAYS conflicting fills can land twice in the
  // same way and leave a real line resident.
  localparam int FLUSH_TAGS   = WAYS + 1;
  localparam int FLUSH_TAG0   = NTAGS - FLUSH_TAGS;
  localparam int TRAFFIC_TAGS = NTAGS - FLUSH_TAGS;

  localparam logic [1:0] ST_I = 2'd0;
  localparam logic [1:0] ST_S = 2'd1;
  localparam logic [1:0] ST_E = 2'd2;
  localparam logic [1:0] ST_M = 2'd3;

  localparam int MEM_RD_LAT    = 4;   // accept -> read data
  localparam int MEM_STALL_MAX = 3;   // extra random accept latency
  localparam int SOAK_OPS      = 220; // randomized operations per core
  localparam int TIMEOUT       = 2_000_000;

  // ---------------------------------------------------------------------------
  // Clock, reset, bookkeeping
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  logic rst_n;
  always #5 clk = ~clk;

  int cycle;
  always @(posedge clk) cycle <= cycle + 1;

  int errors, seed;
  int n_reads, n_writes;
  logic [7:0] phase;          // dumped so the figure generator finds a window
  logic       running;

  int unsigned rnd_state;
  function automatic int unsigned rnd(input int unsigned m);
    rnd_state = rnd_state * 32'd1103515245 + 32'd12345;
    rnd = ((rnd_state >> 16) & 32'h0000_7FFF) % m;
  endfunction

  task automatic err(input string msg);
    begin
      errors = errors + 1;
      $display("[%0t] ERROR (cycle %0d, phase %0d): %s", $time, cycle, phase, msg);
      if (errors > 20) begin
        $display("RESULT: *** FAIL *** (too many errors)");
        $finish;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  logic [NUM_CORES-1:0]        cr_valid, cr_we, cr_ready, cr_rvalid;
  logic [ADDR_W-1:0]           cr_addr  [NUM_CORES];
  logic [DATA_W-1:0]           cr_wdata [NUM_CORES];
  logic [NUM_CORES*ADDR_W-1:0] cr_addr_flat;
  logic [NUM_CORES*DATA_W-1:0] cr_wdata_flat, cr_rdata_flat;

  always_comb begin
    for (int c = 0; c < NUM_CORES; c++) begin
      cr_addr_flat [c*ADDR_W +: ADDR_W] = cr_addr[c];
      cr_wdata_flat[c*DATA_W +: DATA_W] = cr_wdata[c];
    end
  end

  logic                    mem_req, mem_we, mem_ready, mem_rvalid;
  logic [LADDR_W-1:0]      mem_line;
  logic [LINE_W-1:0]       mem_wdata, mem_rdata;

  logic [NUM_CORES*SETS*WAYS*2-1:0]     dbg_state;
  logic [NUM_CORES*SETS*WAYS*TAG_W-1:0] dbg_tag;
  logic [NUM_CORES*4-1:0]               dbg_fsm;
  logic                                 bus_active, bus_commit;
  logic [1:0]                           bus_cmd;
  logic [LADDR_W-1:0]                   bus_line;
  logic [CSEL-1:0]                      bus_owner;
  logic [2:0]                           bus_state;
  logic [NUM_CORES-1:0]                 bus_gnt, snp_hit, snp_dirty;

  logic [31:0] p_busrd, p_busrdx, p_busupgr, p_wb, p_c2c;
  logic [31:0] p_memrd, p_memwr, p_inval, p_downgrade;
  logic [31:0] p_hits, p_misses, p_silent, p_race, p_wbcancel;

  mesi_snoop_coherence #(
      .NUM_CORES(NUM_CORES), .SETS(SETS), .WAYS(WAYS),
      .LINE_WORDS(LINE_WORDS), .DATA_W(DATA_W), .TAG_W(TAG_W),
      .C2C_LAT(C2C_LAT)
  ) dut (
      .clk               (clk),
      .rst_n             (rst_n),
      .core_req_valid_i  (cr_valid),
      .core_req_ready_o  (cr_ready),
      .core_we_i         (cr_we),
      .core_addr_i       (cr_addr_flat),
      .core_wdata_i      (cr_wdata_flat),
      .core_resp_valid_o (cr_rvalid),
      .core_rdata_o      (cr_rdata_flat),
      .mem_req_o         (mem_req),
      .mem_we_o          (mem_we),
      .mem_line_o        (mem_line),
      .mem_wdata_o       (mem_wdata),
      .mem_ready_i       (mem_ready),
      .mem_rvalid_i      (mem_rvalid),
      .mem_rdata_i       (mem_rdata),
      .dbg_state_o       (dbg_state),
      .dbg_tag_o         (dbg_tag),
      .dbg_fsm_o         (dbg_fsm),
      .bus_active_o      (bus_active),
      .bus_cmd_o         (bus_cmd),
      .bus_line_o        (bus_line),
      .bus_owner_o       (bus_owner),
      .bus_state_o       (bus_state),
      .bus_commit_o      (bus_commit),
      .bus_gnt_o         (bus_gnt),
      .snp_hit_o         (snp_hit),
      .snp_dirty_o       (snp_dirty),
      .perf_busrd_o      (p_busrd),
      .perf_busrdx_o     (p_busrdx),
      .perf_busupgr_o    (p_busupgr),
      .perf_wb_o         (p_wb),
      .perf_c2c_o        (p_c2c),
      .perf_mem_rd_o     (p_memrd),
      .perf_mem_wr_o     (p_memwr),
      .perf_inval_o      (p_inval),
      .perf_downgrade_o  (p_downgrade),
      .perf_hits_o       (p_hits),
      .perf_misses_o     (p_misses),
      .perf_silent_upgr_o(p_silent),
      .perf_upgr_race_o  (p_race),
      .perf_wb_cancel_o  (p_wbcancel)
  );

  // ---------------------------------------------------------------------------
  // Backing memory model: line granular, random accept latency, fixed read
  // latency.  Also independently counts memory traffic so the design's own
  // counters can be cross-checked.
  // ---------------------------------------------------------------------------
  logic [LINE_W-1:0] mem [NLINES];

  localparam int M_IDLE = 0, M_RD = 1;
  int                mstate;
  int                stall_q, rd_ctr;
  logic              req_d;
  logic [LINE_W-1:0] rd_data_q;
  int                tb_memrd, tb_memwr;

  // req_d in the term keeps the first cycle of every request a stall cycle, so
  // the randomized stall value is always sampled after it has been loaded.
  assign mem_ready = (mstate == M_IDLE) && mem_req && req_d && (stall_q == 0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mstate     <= M_IDLE;
      stall_q    <= 0;
      rd_ctr     <= 0;
      req_d      <= 1'b0;
      mem_rvalid <= 1'b0;
      mem_rdata  <= '0;
      rd_data_q  <= '0;
    end else begin
      mem_rvalid <= 1'b0;
      req_d      <= mem_req;

      if (mem_req && !req_d)      stall_q <= rnd(MEM_STALL_MAX + 1);
      else if (stall_q != 0)      stall_q <= stall_q - 1;

      case (mstate)
        M_IDLE:
          if (mem_ready) begin
            if (mem_we) begin
              mem[mem_line] <= mem_wdata;
              tb_memwr      <= tb_memwr + 1;
            end else begin
              rd_data_q <= mem[mem_line];
              rd_ctr    <= MEM_RD_LAT;
              tb_memrd  <= tb_memrd + 1;
              mstate    <= M_RD;
            end
          end
        M_RD:
          if (rd_ctr <= 1) begin
            mem_rvalid <= 1'b1;
            mem_rdata  <= rd_data_q;
            mstate     <= M_IDLE;
          end else begin
            rd_ctr <= rd_ctr - 1;
          end
        default: mstate <= M_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Golden memory + per-line software lock
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] gold [NWORDS];
  logic              lock [NLINES];

  function automatic int wa(input int tag, input int set, input int off);
    wa = (tag << (SIDX + WOFF)) | (set << WOFF) | off;
  endfunction

  function automatic int line_of(input int addr);
    line_of = addr >> WOFF;
  endfunction

  function automatic logic [LINE_W-1:0] gold_line(input int line);
    begin
      gold_line = '0;
      for (int k = 0; k < LINE_WORDS; k++)
        gold_line[k*DATA_W +: DATA_W] = gold[line*LINE_WORDS + k];
    end
  endfunction

  task automatic acquire(input int line);
    begin
      while (lock[line]) @(negedge clk);
      lock[line] = 1'b1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Cache-state introspection
  // ---------------------------------------------------------------------------
  function automatic logic [1:0] cst(input int c, input int s, input int w);
    cst = dbg_state[((c*SETS + s)*WAYS + w)*2 +: 2];
  endfunction

  function automatic logic [TAG_W-1:0] ctg(input int c, input int s, input int w);
    ctg = dbg_tag[((c*SETS + s)*WAYS + w)*TAG_W +: TAG_W];
  endfunction

  // MESI state core c holds for {tag,set}, ST_I if it has no copy.
  function automatic logic [1:0] state_of(input int c, input int s, input int tag);
    begin
      state_of = ST_I;
      for (int w = 0; w < WAYS; w++)
        if (cst(c, s, w) != ST_I && ctg(c, s, w) == tag[TAG_W-1:0])
          state_of = cst(c, s, w);
    end
  endfunction

  function automatic string st_name(input logic [1:0] s);
    case (s)
      ST_I:    st_name = "I";
      ST_S:    st_name = "S";
      ST_E:    st_name = "E";
      default: st_name = "M";
    endcase
  endfunction

  task automatic expect_state(input int c, input int s, input int tag,
                              input logic [1:0] want, input string what);
    begin
      if (state_of(c, s, tag) !== want)
        err($sformatf("%s: core %0d should hold tag %0d set %0d in %s, holds %s",
                      what, c, tag, s, st_name(want),
                      st_name(state_of(c, s, tag))));
    end
  endtask

  // A watched line, decoded per core and dumped for the waveform figure.
  int                    watch_set, watch_tag;
  logic [NUM_CORES*2-1:0] watch_state;
  always_comb begin
    for (int c = 0; c < NUM_CORES; c++)
      watch_state[c*2 +: 2] = state_of(c, watch_set, watch_tag);
  end

  // ---------------------------------------------------------------------------
  // Checker 2: coherence invariants
  // ---------------------------------------------------------------------------
  int cnt_v [NTAGS];
  int cnt_m [NTAGS];
  int cnt_x [NTAGS];
  int i3_checks;

  task automatic check_coh(input bit deep);
    int tt, ln;
    logic [LINE_W-1:0] gl;
    begin
      for (int s = 0; s < SETS; s++) begin
        for (int t = 0; t < NTAGS; t++) begin
          cnt_v[t] = 0;
          cnt_m[t] = 0;
          cnt_x[t] = 0;
        end
        for (int c = 0; c < NUM_CORES; c++) begin
          for (int w = 0; w < WAYS; w++) begin
            if (cst(c, s, w) != ST_I) begin
              tt       = ctg(c, s, w);
              cnt_v[tt] = cnt_v[tt] + 1;
              if (cst(c, s, w) == ST_M) cnt_m[tt] = cnt_m[tt] + 1;
              if (cst(c, s, w) != ST_S) cnt_x[tt] = cnt_x[tt] + 1;
            end
          end
        end
        for (int t = 0; t < NTAGS; t++) begin
          if (cnt_x[t] > 1)
            err($sformatf("I1 violated: %0d caches hold tag %0d set %0d in M/E",
                          cnt_x[t], t, s));
          if (cnt_x[t] == 1 && cnt_v[t] != 1)
            err($sformatf("I2 violated: tag %0d set %0d is M/E in one cache but has %0d valid copies",
                          t, s, cnt_v[t]));
          ln = (t << SIDX) | s;
          if (deep && cnt_m[t] == 0 && !lock[ln]) begin
            gl = gold_line(ln);
            i3_checks = i3_checks + 1;
            if (mem[ln] !== gl)
              err($sformatf("I3 violated: line %0d has no M copy but memory %h != golden %h",
                            ln, mem[ln], gl));
          end
        end
      end
    end
  endtask

  // Every bus commit is an ordering point, so the invariants must hold right
  // after one; the periodic sweep also covers the silent E->M upgrade, which
  // changes state without any bus event at all.
  logic commit_d;
  always @(posedge clk) commit_d <= bus_commit;
  always @(negedge clk)
    if (rst_n && running && (commit_d || (cycle % 16 == 0))) check_coh(1'b1);

  // ---------------------------------------------------------------------------
  // Reset-state and protocol sanity, continuously
  // ---------------------------------------------------------------------------
  always @(negedge clk) begin
    if (rst_n && running) begin
      // At most one grant per cycle: the bus is atomic by construction.
      if ($countones(bus_gnt) > 1)
        err("more than one bus grant asserted in the same cycle");
      // A cache may never both supply data and not hold the line.
      for (int c = 0; c < NUM_CORES; c++)
        if (snp_dirty[c] && !snp_hit[c])
          err($sformatf("core %0d asserts snoop-dirty without snoop-hit", c));
    end
  end

  // ---------------------------------------------------------------------------
  // Core drivers
  // ---------------------------------------------------------------------------
  logic [DATA_W-1:0] op_rdata [NUM_CORES];

  // Raw single operation: no locking, no golden update.
  task automatic core_op(input int c, input bit we, input int addr,
                         input logic [DATA_W-1:0] wd);
    begin
      @(negedge clk);
      while (!cr_ready[c]) @(negedge clk);
      cr_valid[c] = 1'b1;
      cr_we[c]    = we;
      cr_addr[c]  = addr[ADDR_W-1:0];
      cr_wdata[c] = wd;
      @(negedge clk);              // the posedge between accepted it
      cr_valid[c] = 1'b0;
      while (!cr_rvalid[c]) @(negedge clk);
      op_rdata[c] = cr_rdata_flat[c*DATA_W +: DATA_W];
    end
  endtask

  // Checked read: the golden value is unambiguous because the line is locked.
  task automatic do_read(input int c, input int addr);
    logic [DATA_W-1:0] exp;
    int ln;
    begin
      ln = line_of(addr);
      acquire(ln);
      exp = gold[addr];
      core_op(c, 1'b0, addr, '0);
      if (op_rdata[c] !== exp)
        err($sformatf("core %0d read addr %0d (tag %0d set %0d off %0d): got %h expected %h",
                      c, addr, addr >> (SIDX+WOFF), (addr >> WOFF) & (SETS-1),
                      addr & (LINE_WORDS-1), op_rdata[c], exp));
      n_reads  = n_reads + 1;
      lock[ln] = 1'b0;
    end
  endtask

  task automatic do_write(input int c, input int addr, input logic [DATA_W-1:0] wd);
    int ln;
    begin
      ln = line_of(addr);
      acquire(ln);
      core_op(c, 1'b1, addr, wd);
      gold[addr] = wd;             // committed only once the store has retired
      n_writes   = n_writes + 1;
      lock[ln]   = 1'b0;
    end
  endtask

  task automatic idle_cycles(input int n);
    begin
      for (int i = 0; i < n; i++) @(negedge clk);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Counter snapshots
  // ---------------------------------------------------------------------------
  int s_rd, s_rdx, s_upgr, s_wb, s_c2c, s_mrd, s_mwr, s_sil, s_race, s_inval;

  task automatic snap();
    begin
      s_rd    = p_busrd;
      s_rdx   = p_busrdx;
      s_upgr  = p_busupgr;
      s_wb    = p_wb;
      s_c2c   = p_c2c;
      s_mrd   = p_memrd;
      s_mwr   = p_memwr;
      s_sil   = p_silent;
      s_race  = p_race;
      s_inval = p_inval;
    end
  endtask

  task automatic expect_delta(input string what, input string field,
                              input int got, input int want);
    begin
      if (got != want)
        err($sformatf("%s: expected %0d %s, saw %0d", what, want, field, got));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Randomized soak driver, one process per core
  // ---------------------------------------------------------------------------
  int soak_done;

  task automatic soak_core(input int c);
    int addr, tag, set, off;
    begin
      for (int i = 0; i < SOAK_OPS; i++) begin
        // 70 % of traffic aims at a small hot working set so that sharing,
        // invalidation and intervention actually happen; the rest spreads out
        // to force conflict misses and writebacks.
        if (rnd(10) < 7) begin
          tag = rnd(2);
          set = rnd(4);
        end else begin
          tag = rnd(TRAFFIC_TAGS);
          set = rnd(SETS);
        end
        off  = rnd(LINE_WORDS);
        addr = wa(tag, set, off);
        if (rnd(2) == 0) do_write(c, addr, {8'hC0 + c[7:0], 8'(i), 8'(tag), 8'(off)});
        else             do_read(c, addr);
        idle_cycles(rnd(5));
      end
      soak_done = soak_done + 1;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  int t_start, bd_bad;
  logic [DATA_W-1:0] tmp;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    rnd_state = 32'h1234_5678 + 32'(seed) * 32'd2654435761;

    $dumpfile("mesi_snoop_coherence.vcd");
    $dumpvars(0, tb_mesi_snoop_coherence);

    errors = 0; n_reads = 0; n_writes = 0; cycle = 0;
    tb_memrd = 0; tb_memwr = 0; i3_checks = 0; soak_done = 0;
    phase = 8'd0; running = 1'b0;
    watch_set = 2; watch_tag = 1;

    cr_valid = '0; cr_we = '0;
    for (int c = 0; c < NUM_CORES; c++) begin
      cr_addr[c]  = '0;
      cr_wdata[c] = '0;
      op_rdata[c] = '0;
    end
    for (int l = 0; l < NLINES; l++) lock[l] = 1'b0;

    // Backing memory and the golden model start life identical.
    for (int l = 0; l < NLINES; l++) begin
      for (int k = 0; k < LINE_WORDS; k++) begin
        tmp = {16'(rnd(65536)), 16'(rnd(65536))};
        gold[l*LINE_WORDS + k]       = tmp;
        mem[l][k*DATA_W +: DATA_W]   = tmp;
      end
    end

    $display("=========================================================");
    $display(" Day 45 - MESI snooping cache-coherence complex");
    $display("  cores=%0d  cache=%0dx%0d lines of %0d words  tags=%0d (%0d for traffic)",
             NUM_CORES, SETS, WAYS, LINE_WORDS, NTAGS, TRAFFIC_TAGS);
    $display("  memory=%0d lines (%0d words)  C2C_LAT=%0d  mem read lat=%0d+",
             NLINES, NWORDS, C2C_LAT, MEM_RD_LAT);
    $display("  seed=%0d", seed);
    $display("=========================================================");

    rst_n = 1'b0;
    repeat (5) @(posedge clk);

    // Out of reset every cache must be completely invalid and the bus quiet.
    for (int c = 0; c < NUM_CORES; c++)
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++)
          if (cst(c, s, w) !== ST_I)
            err($sformatf("core %0d set %0d way %0d not invalid out of reset", c, s, w));
    if (bus_active !== 1'b0) err("bus active during reset");
    if (mem_req !== 1'b0)    err("memory request asserted during reset");
    if (p_busrd != 0 || p_busrdx != 0 || p_busupgr != 0 || p_wb != 0)
      err("bus counters non-zero out of reset");

    rst_n   = 1'b1;
    running = 1'b1;
    @(negedge clk);

    // -- phase 1: cold read miss must fill Exclusive, not Shared -------------
    phase = 8'd1;
    snap();
    do_read(0, wa(1, 2, 0));
    expect_delta("phase 1", "BusRd",   p_busrd - s_rd,   1);
    expect_delta("phase 1", "mem read", p_memrd - s_mrd, 1);
    expect_delta("phase 1", "C2C",     p_c2c - s_c2c,    0);
    expect_state(0, 2, 1, ST_E, "phase 1");
    for (int c = 1; c < NUM_CORES; c++) expect_state(c, 2, 1, ST_I, "phase 1");

    // -- phase 2: E -> M is silent.  Zero bus transactions, or MESI is a lie -
    phase = 8'd2;
    snap();
    do_write(0, wa(1, 2, 1), 32'hE2E2_0001);
    expect_delta("phase 2", "BusRd",    p_busrd - s_rd,     0);
    expect_delta("phase 2", "BusRdX",   p_busrdx - s_rdx,   0);
    expect_delta("phase 2", "BusUpgr",  p_busupgr - s_upgr, 0);
    expect_delta("phase 2", "writeback", p_wb - s_wb,       0);
    expect_delta("phase 2", "mem read", p_memrd - s_mrd,    0);
    expect_delta("phase 2", "mem write", p_memwr - s_mwr,   0);
    expect_delta("phase 2", "silent upgrade", p_silent - s_sil, 1);
    expect_state(0, 2, 1, ST_M, "phase 2");

    // -- phase 3: sharing a dirty line - intervention plus a flush ----------
    phase = 8'd3;
    snap();
    do_read(1, wa(1, 2, 1));       // snoops core 0's M copy: C2C + flush
    do_read(2, wa(1, 2, 1));       // clean sharing now: plain memory read
    do_read(3, wa(1, 2, 0));
    expect_delta("phase 3", "BusRd",     p_busrd - s_rd,  3);
    expect_delta("phase 3", "C2C",       p_c2c - s_c2c,   1);
    expect_delta("phase 3", "mem write", p_memwr - s_mwr, 1);
    expect_delta("phase 3", "mem read",  p_memrd - s_mrd, 2);
    for (int c = 0; c < NUM_CORES; c++) expect_state(c, 2, 1, ST_S, "phase 3");

    // -- phase 4: store to a shared line is permission-only ----------------
    phase = 8'd4;
    snap();
    do_write(1, wa(1, 2, 2), 32'h0BAD_C0DE);
    expect_delta("phase 4", "BusUpgr",   p_busupgr - s_upgr, 1);
    expect_delta("phase 4", "BusRdX",    p_busrdx - s_rdx,   0);
    expect_delta("phase 4", "mem read",  p_memrd - s_mrd,    0);
    expect_delta("phase 4", "mem write", p_memwr - s_mwr,    0);
    expect_delta("phase 4", "invalidation", p_inval - s_inval, NUM_CORES - 1);
    expect_state(1, 2, 1, ST_M, "phase 4");
    expect_state(0, 2, 1, ST_I, "phase 4");
    expect_state(2, 2, 1, ST_I, "phase 4");
    expect_state(3, 2, 1, ST_I, "phase 4");

    // -- phase 5: read-for-ownership against a dirty owner -----------------
    phase = 8'd5;
    snap();
    do_write(2, wa(1, 2, 3), 32'hFEED_BEEF);
    expect_delta("phase 5", "BusRdX",    p_busrdx - s_rdx, 1);
    expect_delta("phase 5", "C2C",       p_c2c - s_c2c,    1);
    expect_delta("phase 5", "mem read",  p_memrd - s_mrd,  0);
    expect_delta("phase 5", "mem write", p_memwr - s_mwr,  1);
    expect_state(2, 2, 1, ST_M, "phase 5");
    expect_state(1, 2, 1, ST_I, "phase 5");
    // The word core 1 wrote in phase 4 must have survived the transfer.
    do_read(2, wa(1, 2, 2));
    do_read(2, wa(1, 2, 1));

    // -- phase 6: dirty victim eviction writes back exactly once -----------
    phase = 8'd6;
    snap();
    do_write(3, wa(2, 5, 0), 32'h1111_0000);
    do_write(3, wa(3, 5, 0), 32'h2222_0000);
    expect_delta("phase 6", "writeback", p_wb - s_wb, 0);
    snap();
    do_read(3, wa(4, 5, 0));       // set 5 is full of dirty lines: one must go
    expect_delta("phase 6", "writeback", p_wb - s_wb,     1);
    expect_delta("phase 6", "mem write", p_memwr - s_mwr, 1);
    do_read(3, wa(2, 5, 0));       // the evicted line still reads correctly
    do_read(3, wa(3, 5, 0));

    // -- phase 7: the simultaneous-upgrade race (waveform window) ----------
    // Both cores hold the line in S and store to different words of it in the
    // same cycle.  One wins with BusUpgr; the loser has lost its copy and must
    // promote its own request to BusRdX rather than claim M over stale data.
    phase     = 8'd7;
    watch_set = 1;
    watch_tag = 6;
    do_read(0, wa(6, 1, 0));       // core 0: E
    do_read(1, wa(6, 1, 0));       // core 0 -> S, core 1 -> S
    expect_state(0, 1, 6, ST_S, "phase 7 setup");
    expect_state(1, 1, 6, ST_S, "phase 7 setup");
    snap();
    acquire(line_of(wa(6, 1, 0))); // hand-managed: two ops on one line at once
    fork
      core_op(0, 1'b1, wa(6, 1, 0), 32'hAAAA_0000);
      core_op(1, 1'b1, wa(6, 1, 1), 32'hBBBB_1111);
    join
    gold[wa(6, 1, 0)] = 32'hAAAA_0000;
    gold[wa(6, 1, 1)] = 32'hBBBB_1111;
    lock[line_of(wa(6, 1, 0))] = 1'b0;
    expect_delta("phase 7", "BusUpgr", p_busupgr - s_upgr, 1);
    expect_delta("phase 7", "BusRdX",  p_busrdx - s_rdx,   1);
    expect_delta("phase 7", "promoted upgrade", p_race - s_race, 1);
    // Exactly one of them ends up the owner, and both stores are visible.
    if (!((state_of(0, 1, 6) == ST_M && state_of(1, 1, 6) == ST_I) ||
          (state_of(1, 1, 6) == ST_M && state_of(0, 1, 6) == ST_I)))
      err($sformatf("phase 7: expected one owner and one invalid, got core0=%s core1=%s",
                    st_name(state_of(0, 1, 6)), st_name(state_of(1, 1, 6))));
    do_read(2, wa(6, 1, 0));
    do_read(3, wa(6, 1, 1));

    // -- phase 8: false-sharing ping-pong ----------------------------------
    // Four cores writing four different words of one line: every store must
    // still take ownership of the whole line, so this is the worst case for a
    // line-granular protocol and the best test of the transfer path.
    phase     = 8'd8;
    watch_set = 3;
    watch_tag = 7;
    snap();
    for (int round = 0; round < 6; round++)
      for (int c = 0; c < NUM_CORES; c++)
        do_write(c, wa(7, 3, c), 32'hF0000000 + 32'(round*16 + c));
    if (p_c2c - s_c2c < 10)
      err($sformatf("phase 8: expected heavy intervention traffic, saw %0d C2C transfers",
                    p_c2c - s_c2c));
    for (int c = 0; c < NUM_CORES; c++) do_read((c + 1) % NUM_CORES, wa(7, 3, c));

    // -- phase 9: four-core randomized soak --------------------------------
    phase     = 8'd9;
    watch_set = 0;
    watch_tag = 0;
    t_start   = cycle;
    fork
      soak_core(0);
      soak_core(1);
      soak_core(2);
      soak_core(3);
    join
    if (soak_done != NUM_CORES) err("soak processes did not all finish");

    // -- phase 10: drain every cache by conflict, then compare memory ------
    // Reading the two reserved tags in each set evicts both ways, writing back
    // anything dirty.  Afterwards no traffic line may be cached anywhere and
    // memory must equal the golden model word for word.
    phase = 8'd10;
    for (int c = 0; c < NUM_CORES; c++)
      for (int s = 0; s < SETS; s++)
        for (int k = 0; k < FLUSH_TAGS; k++)
          do_read(c, wa(FLUSH_TAG0 + k, s, 0));

    for (int c = 0; c < NUM_CORES; c++)
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++)
          if (cst(c, s, w) !== ST_I && ctg(c, s, w) < FLUSH_TAG0)
            err($sformatf("drain incomplete: core %0d set %0d way %0d still holds tag %0d in %s",
                          c, s, w, ctg(c, s, w), st_name(cst(c, s, w))));

    bd_bad = 0;
    for (int l = 0; l < NLINES; l++)
      if (mem[l] !== gold_line(l)) begin
        bd_bad = bd_bad + 1;
        err($sformatf("backdoor compare: line %0d memory %h != golden %h",
                      l, mem[l], gold_line(l)));
      end
    if (bd_bad == 0)
      $display("[%0t] backdoor memory compare over %0d words: clean", $time, NWORDS);

    // Cross-check the design's own memory counters against the model's.
    if (p_memrd != tb_memrd)
      err($sformatf("memory read counter mismatch: design %0d, model %0d",
                    p_memrd, tb_memrd));
    if (p_memwr != tb_memwr)
      err($sformatf("memory write counter mismatch: design %0d, model %0d",
                    p_memwr, tb_memwr));

    // Nothing may be left in flight.
    for (int l = 0; l < NLINES; l++)
      if (lock[l]) err($sformatf("line %0d still locked at end of test", l));
    if (bus_active !== 1'b0) err("bus still active at end of test");

    running = 1'b0;
    repeat (4) @(posedge clk);

    $display("---------------------------------------------------------");
    $display(" core operations   %0d  (reads %0d, writes %0d)",
             n_reads + n_writes, n_reads, n_writes);
    $display(" cache hits %0d  misses %0d  silent E->M upgrades %0d",
             p_hits, p_misses, p_silent);
    $display(" BusRd %0d  BusRdX %0d  BusUpgr %0d  writeback %0d",
             p_busrd, p_busrdx, p_busupgr, p_wb);
    $display(" cache-to-cache transfers %0d  invalidations %0d  M/E->S downgrades %0d",
             p_c2c, p_inval, p_downgrade);
    $display(" memory reads %0d  memory writes %0d", p_memrd, p_memwr);
    $display(" promoted upgrades %0d  cancelled writebacks %0d",
             p_race, p_wbcancel);
    $display(" coherence sweeps: %0d line-level memory checks", i3_checks);
    $display("---------------------------------------------------------");

    if (errors == 0) $display("RESULT: *** PASS ***");
    else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Watchdog
  // ---------------------------------------------------------------------------
  initial begin
    repeat (TIMEOUT) @(posedge clk);
    $display("[%0t] ERROR: watchdog expired in phase %0d", $time, phase);
    $display("RESULT: *** FAIL *** (timeout)");
    $finish;
  end

endmodule
