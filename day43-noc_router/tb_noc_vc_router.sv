// -----------------------------------------------------------------------------
// Day 43 - Self-checking testbench for the wormhole virtual-channel NoC router
//
// The reference model is structural rather than a second copy of the RTL: the
// router may schedule flits in any order it likes, but the following invariants
// must hold, and every one of them is checked on every flit.
//
//   1. Routing        - a packet must leave on exactly the port that
//                       dimension-order XY routing selects for its destination.
//   2. Wormhole       - once a head flit appears on an output VC, every later
//                       flit on that output VC must belong to the same packet,
//                       in order, until its tail.  No interleaving is allowed.
//   3. Data integrity - every flit's payload must match the value the injector
//                       generated for that (packet id, flit index).
//   4. Ordering       - packets injected on the same (input port, input VC)
//                       must be delivered in injection order.
//   5. Flow control   - the router must never launch a flit on an output VC
//                       whose downstream credit count is zero.  The testbench
//                       models the downstream buffer and fails on overflow.
//   6. Credit balance - credits returned upstream must equal the number of
//                       flits the router consumed.
//   7. Completion     - every injected packet must eventually be delivered.
//
// Each flit's payload is a pure function of (packet id, flit index), so the
// checker regenerates the expected flit instead of storing packet contents.
//
// Stimulus: eight scenarios - seven directed (including a head-of-line-blocking
// test that is the whole reason virtual channels exist, and a starvation test)
// followed by a randomized soak with random destinations, packet lengths, VCs,
// injection gaps and credit-return delays.
//
// Icarus has no support for arrays of queues, so every software FIFO here is an
// explicit circular buffer.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_noc_vc_router;

  localparam int PORTS       = 5;
  localparam int VCS         = 2;
  localparam int FLIT_WIDTH  = 32;
  localparam int BUF_DEPTH   = 4;
  localparam int COORD_WIDTH = 4;

  localparam int VCW  = (VCS > 1) ? $clog2(VCS) : 1;
  localparam int CNTW = $clog2(BUF_DEPTH + 1);
  localparam int NVC  = PORTS * VCS;

  localparam int NORTH = 0;
  localparam int EAST  = 1;
  localparam int SOUTH = 2;
  localparam int WEST  = 3;
  localparam int LOCAL = 4;

  localparam int MY_X = 2;
  localparam int MY_Y = 2;

  localparam int MAX_PKTS = 512;
  localparam int MAX_LEN  = 6;
  localparam int QDEPTH   = 4096;   // software FIFO depth per input VC
  localparam int RDEPTH   = 64;     // credit-return pipe depth per output port
  localparam int TIMEOUT  = 300000; // cycles

  // ---------------------------------------------------------------------------
  // DUT interface
  // ---------------------------------------------------------------------------
  logic                        clk, rst_n;
  logic [COORD_WIDTH-1:0]      my_x, my_y;

  logic [PORTS-1:0]            in_valid;
  logic [PORTS*VCW-1:0]        in_vc;
  logic [PORTS*FLIT_WIDTH-1:0] in_flit;
  logic [PORTS*VCS-1:0]        in_ready;

  logic [PORTS-1:0]            in_credit_valid;
  logic [PORTS*VCW-1:0]        in_credit_vc;

  logic [PORTS-1:0]            out_valid;
  logic [PORTS*VCW-1:0]        out_vc;
  logic [PORTS*FLIT_WIDTH-1:0] out_flit;

  logic [PORTS-1:0]            out_credit_valid;
  logic [PORTS*VCW-1:0]        out_credit_vc;

  logic [PORTS*VCS*2-1:0]      dbg_state;
  logic [PORTS*VCS-1:0]        dbg_ovc_busy;
  logic [PORTS*VCS*CNTW-1:0]   dbg_occupancy;
  logic [PORTS*VCS*CNTW-1:0]   dbg_credit;
  logic [31:0]                 perf_flits, perf_packets, perf_va_stall,
                               perf_sa_stall;

  noc_vc_router #(
      .PORTS      (PORTS),
      .VCS        (VCS),
      .FLIT_WIDTH (FLIT_WIDTH),
      .BUF_DEPTH  (BUF_DEPTH),
      .COORD_WIDTH(COORD_WIDTH)
  ) dut (
      .clk               (clk),
      .rst_n             (rst_n),
      .my_x_i            (my_x),
      .my_y_i            (my_y),
      .in_valid_i        (in_valid),
      .in_vc_i           (in_vc),
      .in_flit_i         (in_flit),
      .in_ready_o        (in_ready),
      .in_credit_valid_o (in_credit_valid),
      .in_credit_vc_o    (in_credit_vc),
      .out_valid_o       (out_valid),
      .out_vc_o          (out_vc),
      .out_flit_o        (out_flit),
      .out_credit_valid_i(out_credit_valid),
      .out_credit_vc_i   (out_credit_vc),
      .dbg_state_o       (dbg_state),
      .dbg_ovc_busy_o    (dbg_ovc_busy),
      .dbg_occupancy_o   (dbg_occupancy),
      .dbg_credit_o      (dbg_credit),
      .perf_flits_o      (perf_flits),
      .perf_packets_o    (perf_packets),
      .perf_va_stall_o   (perf_va_stall),
      .perf_sa_stall_o   (perf_sa_stall)
  );

  // ---------------------------------------------------------------------------
  // Clock, cycle counter, error counter
  // ---------------------------------------------------------------------------
  initial clk = 1'b0;
  always #5 clk = ~clk;

  int cycle;
  always @(posedge clk) cycle <= cycle + 1;

  int errors;
  int seed;

  // Deterministic RNG.  $urandom(seed) re-seeds on every call in some
  // simulators, which would return the same number forever, so roll our own.
  int unsigned rnd_state;
  function automatic int unsigned rnd(input int unsigned m);
    rnd_state = rnd_state * 32'd1103515245 + 32'd12345;
    rnd = ((rnd_state >> 16) & 32'h0000_7FFF) % m;
  endfunction

  function automatic string port_name(input int p);
    case (p)
      NORTH:   port_name = "N";
      EAST:    port_name = "E";
      SOUTH:   port_name = "S";
      WEST:    port_name = "W";
      default: port_name = "L";
    endcase
  endfunction

  // ---------------------------------------------------------------------------
  // Flit construction.  The payload is a pure function of (id, index), so the
  // checker can regenerate any expected flit without storing packet contents.
  //
  //   head : {tail,head} = 01, or 11 for a single-flit packet
  //          [29:21]=id [20:18]=len [17:15]=in_port [14:13]=in_vc
  //          [12:8]=0   [7:4]=dest_y [3:0]=dest_x
  //   body : {tail,head} = 00, or 10 for the last flit
  //          [29:21]=id [20:18]=index [17:0]=hash(id,index)
  //
  // The id field is 9 bits (MAX_PKTS <= 512) and the len/index fields are 3 bits
  // (MAX_LEN <= 7); both must stay wide enough or the checker would compare
  // against a truncated id.
  // ---------------------------------------------------------------------------
  function automatic logic [FLIT_WIDTH-1:0] mk_head(input int id, len, ip, iv,
                                                              dx, dy);
    logic [1:0] ftype;
    ftype   = (len == 1) ? 2'b11 : 2'b01;
    mk_head = {ftype, 9'(id), 3'(len), 3'(ip), 2'(iv), 5'd0, 4'(dy), 4'(dx)};
  endfunction

  function automatic logic [FLIT_WIDTH-1:0] mk_body(input int id, idx, len);
    logic [1:0]  ftype;
    logic [17:0] hash;
    ftype   = (idx == len-1) ? 2'b10 : 2'b00;
    hash    = 18'(id * 18'h2F1B3) ^ 18'(idx * 18'h1D07F) ^ 18'h3A5C6;
    mk_body = {ftype, 9'(id), 3'(idx), hash};
  endfunction

  function automatic logic [FLIT_WIDTH-1:0] mk_flit(input int id, idx, len, ip,
                                                              iv, dx, dy);
    mk_flit = (idx == 0) ? mk_head(id, len, ip, iv, dx, dy)
                         : mk_body(id, idx, len);
  endfunction

  function automatic int route_xy(input int dx, dy);
    if (dx > MY_X)      route_xy = EAST;
    else if (dx < MY_X) route_xy = WEST;
    else if (dy > MY_Y) route_xy = NORTH;
    else if (dy < MY_Y) route_xy = SOUTH;
    else                route_xy = LOCAL;
  endfunction

  // ---------------------------------------------------------------------------
  // Software FIFOs (explicit circular buffers - Icarus has no array-of-queues)
  //
  //   inq_*  : flits still to be driven into each input VC
  //   ord_*  : ids of packets injected on each input VC, for the ordering check
  //   ret_*  : credit returns owed to the router on each output port
  // ---------------------------------------------------------------------------
  logic [FLIT_WIDTH-1:0] inq_mem  [NVC][QDEPTH];
  int                    inq_h    [NVC];
  int                    inq_t    [NVC];

  int                    ord_mem  [NVC][QDEPTH];
  int                    ord_h    [NVC];
  int                    ord_t    [NVC];

  int                    ret_vc   [PORTS][RDEPTH];
  int                    ret_dly  [PORTS][RDEPTH];
  int                    ret_h    [PORTS];
  int                    ret_t    [PORTS];

  function automatic int inq_size(input int pv);
    inq_size = inq_t[pv] - inq_h[pv];
  endfunction

  task automatic inq_push(input int pv, input logic [FLIT_WIDTH-1:0] f);
    begin
      if (inq_size(pv) >= QDEPTH) begin
        $display("FATAL: input FIFO %0d overflow", pv);
        $finish;
      end
      inq_mem[pv][inq_t[pv] % QDEPTH] = f;
      inq_t[pv] = inq_t[pv] + 1;
    end
  endtask

  function automatic logic [FLIT_WIDTH-1:0] inq_pop(input int pv);
    inq_pop   = inq_mem[pv][inq_h[pv] % QDEPTH];
    inq_h[pv] = inq_h[pv] + 1;
  endfunction

  function automatic int ord_size(input int pv);
    ord_size = ord_t[pv] - ord_h[pv];
  endfunction

  task automatic ord_push(input int pv, input int id);
    begin
      ord_mem[pv][ord_t[pv] % QDEPTH] = id;
      ord_t[pv] = ord_t[pv] + 1;
    end
  endtask

  function automatic int ord_pop(input int pv);
    ord_pop   = ord_mem[pv][ord_h[pv] % QDEPTH];
    ord_h[pv] = ord_h[pv] + 1;
  endfunction

  // ---------------------------------------------------------------------------
  // Packet bookkeeping
  // ---------------------------------------------------------------------------
  int  pkt_len  [MAX_PKTS];
  int  pkt_dx   [MAX_PKTS];
  int  pkt_dy   [MAX_PKTS];
  int  pkt_ip   [MAX_PKTS];
  int  pkt_iv   [MAX_PKTS];
  bit  pkt_done [MAX_PKTS];

  int  next_id, pkts_done, flits_sent, flits_recv;
  int  gap_max, credit_max_delay;

  task automatic queue_packet(input int ip, iv, dx, dy, len);
    int id, pv;
    begin
      id = next_id;
      next_id = next_id + 1;
      if (id >= MAX_PKTS) begin
        $display("FATAL: packet id space exhausted");
        $finish;
      end
      pv           = ip*VCS + iv;
      pkt_len[id]  = len;
      pkt_dx[id]   = dx;
      pkt_dy[id]   = dy;
      pkt_ip[id]   = ip;
      pkt_iv[id]   = iv;
      pkt_done[id] = 1'b0;
      for (int k = 0; k < len; k++)
        inq_push(pv, mk_flit(id, k, len, ip, iv, dx, dy));
      ord_push(pv, id);
    end
  endtask

  task automatic fail(input string msg);
    begin
      errors = errors + 1;
      $display("[%0t] ERROR (cycle %0d): %s", $time, cycle, msg);
      if (errors > 20) begin
        $display("RESULT: *** FAIL *** (too many errors)");
        $finish;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Injector: models the upstream router on each link.
  //
  // Flow control is credit based, exactly as it would be between two real
  // routers: the injector starts with BUF_DEPTH credits per input VC, spends
  // one per flit, and refills from the DUT's in_credit_valid_o/in_credit_vc_o
  // returns.  Using in_ready_o for this instead would be a cycle stale - the
  // ready seen at a clock edge does not account for the flit being pushed on
  // that same edge - and would silently overrun a full buffer.
  //
  // At most one flit per physical input port per cycle, with a randomized gap.
  // ---------------------------------------------------------------------------
  int up_credit [NVC];
  int gap_cnt   [PORTS];
  int inj_rr    [PORTS];

  always @(posedge clk or negedge rst_n) begin : injector
    int v, pv, chosen;
    if (!rst_n) begin
      in_valid <= '0;
      in_vc    <= '0;
      in_flit  <= '0;
      for (int p = 0; p < PORTS; p++) begin
        gap_cnt[p] <= 0;
        inj_rr[p]  <= 0;
      end
    end else begin
      // credit returns from the router refill the upstream link credits
      for (int p = 0; p < PORTS; p++)
        if (in_credit_valid[p]) begin
          v = int'(in_credit_vc[p*VCW +: VCW]);
          up_credit[p*VCS+v] = up_credit[p*VCS+v] + 1;
          if (up_credit[p*VCS+v] > BUF_DEPTH)
            fail($sformatf("router returned more credits than %s vc%0d can hold",
                           port_name(p), v));
        end

      in_valid <= '0;
      for (int p = 0; p < PORTS; p++) begin
        if (gap_cnt[p] > 0) begin
          gap_cnt[p] <= gap_cnt[p] - 1;
        end else begin
          chosen = -1;
          for (int k = 0; k < VCS; k++) begin
            v  = (inj_rr[p] + k) % VCS;
            pv = p*VCS + v;
            if ((chosen < 0) && (inq_size(pv) != 0) && (up_credit[pv] > 0))
              chosen = v;
          end
          if (chosen >= 0) begin
            pv = p*VCS + chosen;
            // a credited flit must always find room; if not, the router's
            // ready/credit accounting disagrees with its own buffer
            if (!in_ready[pv])
              fail($sformatf("in_ready deasserted on %s vc%0d while the upstream link still held a credit",
                             port_name(p), chosen));
            up_credit[pv] = up_credit[pv] - 1;
            in_valid[p]                         <= 1'b1;
            in_vc[p*VCW +: VCW]                 <= VCW'(chosen);
            in_flit[p*FLIT_WIDTH +: FLIT_WIDTH] <= inq_pop(pv);
            inj_rr[p]                           <= (chosen + 1) % VCS;
            flits_sent = flits_sent + 1;   // blocking: up to PORTS per cycle
            gap_cnt[p] <= (gap_max == 0) ? 0 : rnd(gap_max + 1);
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Downstream model + checker
  //
  // tb_credit/tb_occ model the buffer the router is shooting at, so invariant 5
  // is checked against an independent credit count rather than the router's own.
  // hold_credit[o] freezes returns on a port, creating real backpressure.
  // ---------------------------------------------------------------------------
  int  tb_credit    [NVC];
  int  tb_occ       [NVC];
  bit  hold_credit  [PORTS];
  int  cred_ret_cnt [NVC];

  bit  rx_busy [NVC];
  int  rx_id   [NVC];
  int  rx_len  [NVC];
  int  rx_idx  [NVC];

  always @(posedge clk) begin : rx_monitor
    int ov, id, len, ip, iv, dx, dy, expect_port, head_id, ovc_i, v;
    logic [FLIT_WIDTH-1:0] f, exp_f;

    if (rst_n) begin
      // ---- credits the router returned upstream ---------------------------
      for (int p = 0; p < PORTS; p++)
        if (in_credit_valid[p]) begin
          v = int'(in_credit_vc[p*VCW +: VCW]);
          cred_ret_cnt[p*VCS + v] = cred_ret_cnt[p*VCS + v] + 1;
        end

      // ---- flits arriving at the downstream model -------------------------
      for (int o = 0; o < PORTS; o++) begin
        if (out_valid[o]) begin
          ov    = int'(out_vc[o*VCW +: VCW]);
          ovc_i = o*VCS + ov;
          f     = out_flit[o*FLIT_WIDTH +: FLIT_WIDTH];
          flits_recv = flits_recv + 1;

          // -- invariant 5: credit-based flow control -----------------------
          if (tb_credit[ovc_i] <= 0)
            fail($sformatf("credit underflow: flit launched on %s vc%0d with 0 credits",
                           port_name(o), ov));
          else
            tb_credit[ovc_i] = tb_credit[ovc_i] - 1;
          tb_occ[ovc_i] = tb_occ[ovc_i] + 1;
          if (tb_occ[ovc_i] > BUF_DEPTH)
            fail($sformatf("downstream buffer overflow on %s vc%0d",
                           port_name(o), ov));

          if (!rx_busy[ovc_i]) begin
            // -- this output VC is idle, so a head flit is required ---------
            if (!f[FLIT_WIDTH-2]) begin
              fail($sformatf("non-head flit %h opened a packet on %s vc%0d",
                             f, port_name(o), ov));
            end else begin
              id  = int'(f[29:21]);
              len = int'(f[20:18]);
              ip  = int'(f[17:15]);
              iv  = int'(f[14:13]);
              dy  = int'(f[7:4]);
              dx  = int'(f[3:0]);

              // -- invariant 3: the head must be bit-exact ------------------
              exp_f = mk_head(id, len, ip, iv, dx, dy);
              if (f !== exp_f)
                fail($sformatf("corrupt head on %s vc%0d: got %h exp %h",
                               port_name(o), ov, f, exp_f));

              if ((id >= next_id) || pkt_done[id]) begin
                fail($sformatf("head for unknown or already-completed packet id %0d",
                               id));
              end else if ((pkt_len[id] != len) || (pkt_dx[id] != dx) ||
                           (pkt_dy[id] != dy) || (pkt_ip[id] != ip) ||
                           (pkt_iv[id] != iv)) begin
                fail($sformatf("head fields disagree with injection for pkt %0d",
                               id));
              end else begin
                // -- invariant 1: dimension-order routing -------------------
                expect_port = route_xy(dx, dy);
                if (expect_port != o)
                  fail($sformatf("pkt %0d dest (%0d,%0d) left on %s, expected %s",
                                 id, dx, dy, port_name(o),
                                 port_name(expect_port)));

                // -- invariant 4: per-(input port, input VC) ordering -------
                if (ord_size(ip*VCS+iv) == 0) begin
                  fail($sformatf("pkt %0d arrived but its input order list is empty",
                                 id));
                end else begin
                  head_id = ord_pop(ip*VCS+iv);
                  if (head_id != id)
                    fail($sformatf("ordering violation on in-port %s vc%0d: got pkt %0d, expected %0d",
                                   port_name(ip), iv, id, head_id));
                end
              end

              if (len == 1) begin
                if (f[FLIT_WIDTH-1] !== 1'b1)
                  fail($sformatf("single-flit pkt %0d is missing its tail bit",
                                 id));
                pkt_done[id] = 1'b1;
                pkts_done    = pkts_done + 1;
              end else begin
                if (f[FLIT_WIDTH-1] !== 1'b0)
                  fail($sformatf("multi-flit pkt %0d head has the tail bit set",
                                 id));
                rx_busy[ovc_i] = 1'b1;
                rx_id[ovc_i]   = id;
                rx_len[ovc_i]  = len;
                rx_idx[ovc_i]  = 1;
              end
            end
          end else begin
            // -- invariants 2 and 3: wormhole continuation, exact payload ---
            id    = rx_id[ovc_i];
            len   = rx_len[ovc_i];
            exp_f = mk_body(id, rx_idx[ovc_i], len);
            if (f !== exp_f)
              fail($sformatf("wormhole/data violation on %s vc%0d, flit %0d of pkt %0d: got %h exp %h",
                             port_name(o), ov, rx_idx[ovc_i], id, f, exp_f));
            rx_idx[ovc_i] = rx_idx[ovc_i] + 1;
            if (rx_idx[ovc_i] == len) begin
              rx_busy[ovc_i] = 1'b0;
              pkt_done[id]   = 1'b1;
              pkts_done      = pkts_done + 1;
            end
          end
        end
      end

      // ---- credit-return pipe back to the router ---------------------------
      out_credit_valid <= '0;
      for (int o = 0; o < PORTS; o++) begin
        if (out_valid[o]) begin
          if ((ret_t[o] - ret_h[o]) >= RDEPTH) begin
            $display("FATAL: credit-return FIFO overflow on port %0d", o);
            $finish;
          end
          ret_vc [o][ret_t[o] % RDEPTH] = int'(out_vc[o*VCW +: VCW]);
          ret_dly[o][ret_t[o] % RDEPTH] = (credit_max_delay == 0)
                                          ? 0 : rnd(credit_max_delay + 1);
          ret_t[o] = ret_t[o] + 1;
        end
        if ((ret_t[o] != ret_h[o]) && !hold_credit[o]) begin
          if (ret_dly[o][ret_h[o] % RDEPTH] > 0) begin
            ret_dly[o][ret_h[o] % RDEPTH] = ret_dly[o][ret_h[o] % RDEPTH] - 1;
          end else begin
            v        = ret_vc[o][ret_h[o] % RDEPTH];
            ret_h[o] = ret_h[o] + 1;
            out_credit_valid[o]         <= 1'b1;
            out_credit_vc[o*VCW +: VCW] <= VCW'(v);
            tb_credit[o*VCS+v] = tb_credit[o*VCS+v] + 1;
            tb_occ[o*VCS+v]    = tb_occ[o*VCS+v]    - 1;
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------
  task automatic wait_drain(input int limit, input string what);
    int guard;
    begin
      guard = 0;
      while ((pkts_done != next_id) && (guard < limit)) begin
        @(posedge clk);
        guard = guard + 1;
      end
      if (pkts_done != next_id)
        fail($sformatf("%s did not drain: %0d of %0d packets delivered",
                       what, pkts_done, next_id));
    end
  endtask

  task automatic banner(input string s);
    $display("  -- %s", s);
  endtask

  // ---------------------------------------------------------------------------
  // Stimulus
  // ---------------------------------------------------------------------------
  int delivered_before;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    rnd_state = 32'h1234_5678 + 32'(seed) * 32'd2654435761;

    $dumpfile("noc_vc_router.vcd");
    $dumpvars(0, tb_noc_vc_router);

    errors     = 0;
    cycle      = 0;
    next_id    = 0;
    pkts_done  = 0;
    flits_sent = 0;
    flits_recv = 0;
    gap_max    = 0;
    credit_max_delay = 0;
    my_x = COORD_WIDTH'(MY_X);
    my_y = COORD_WIDTH'(MY_Y);
    out_credit_valid = '0;
    out_credit_vc    = '0;

    for (int i = 0; i < NVC; i++) begin
      inq_h[i] = 0; inq_t[i] = 0;
      ord_h[i] = 0; ord_t[i] = 0;
      tb_credit[i]    = BUF_DEPTH;
      up_credit[i]    = BUF_DEPTH;
      tb_occ[i]       = 0;
      rx_busy[i]      = 1'b0;
      cred_ret_cnt[i] = 0;
    end
    for (int p = 0; p < PORTS; p++) begin
      ret_h[p] = 0; ret_t[p] = 0;
      hold_credit[p] = 1'b0;
    end

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    $display("Day 43 - Wormhole VC NoC Router, node at mesh coordinate (%0d,%0d)",
             MY_X, MY_Y);
    $display("  PORTS=%0d VCS=%0d FLIT_WIDTH=%0d BUF_DEPTH=%0d seed=%0d",
             PORTS, VCS, FLIT_WIDTH, BUF_DEPTH, seed);

    // -- T1: single-flit packet -----------------------------------------------
    banner("T1  single-flit packet   L.vc0 -> (3,2) = EAST");
    queue_packet(LOCAL, 0, 3, 2, 1);
    wait_drain(200, "T1");

    // -- T2: multi-flit wormhole packet that turns from X to Y ----------------
    banner("T2  4-flit wormhole      W.vc0 -> (2,4) = NORTH (X done, turn to Y)");
    queue_packet(WEST, 0, 2, 4, 4);
    wait_drain(200, "T2");

    // -- T3: ejection to the local port ---------------------------------------
    banner("T3  3-flit packet        N.vc1 -> (2,2) = LOCAL ejection");
    queue_packet(NORTH, 1, 2, 2, 3);
    wait_drain(200, "T3");

    // -- T4: all five inputs injecting at once to five distinct outputs -------
    banner("T4  all 5 inputs at once, five distinct output ports");
    queue_packet(NORTH, 0, 3, 2, 2);   // -> EAST
    queue_packet(EAST,  0, 1, 2, 2);   // -> WEST
    queue_packet(SOUTH, 0, 2, 5, 2);   // -> NORTH
    queue_packet(WEST,  0, 2, 0, 2);   // -> SOUTH
    queue_packet(LOCAL, 0, 2, 2, 2);   // -> LOCAL
    wait_drain(400, "T4");

    // -- T5: output-port contention, four inputs onto one output --------------
    banner("T5  4 inputs contend for one output port (EAST)");
    queue_packet(NORTH, 0, 3, 2, 3);
    queue_packet(SOUTH, 0, 4, 2, 3);
    queue_packet(WEST,  0, 5, 2, 3);
    queue_packet(LOCAL, 0, 3, 1, 3);
    wait_drain(600, "T5");

    // -- T6: the entire point of virtual channels -----------------------------
    // Freeze the EAST downstream so a packet on W.vc0 stalls mid-wormhole, then
    // inject a NORTH-bound packet behind it on W.vc1.  With one shared buffer
    // per input the second packet would be head-of-line blocked; with virtual
    // channels it must be delivered while the first is still stuck.
    banner("T6  head-of-line avoidance: W.vc0 blocked on EAST, W.vc1 -> NORTH");
    hold_credit[EAST] = 1'b1;
    delivered_before  = pkts_done;
    queue_packet(WEST, 0, 5, 2, MAX_LEN);   // stalls on the blocked EAST port
    repeat (30) @(posedge clk);
    queue_packet(WEST, 1, 2, 4, 3);         // must still get through
    repeat (150) @(posedge clk);
    if (pkts_done != delivered_before + 1)
      fail($sformatf("VC independence broken: %0d packets delivered while EAST was blocked, expected exactly 1",
                     pkts_done - delivered_before));
    else
      banner("    vc1 packet delivered while vc0 stayed blocked - OK");
    hold_credit[EAST] = 1'b0;
    wait_drain(600, "T6");

    // -- T7: fairness - a flooding input must not lock out a quiet one --------
    banner("T7  fairness: NORTH floods EAST while LOCAL sends one EAST packet");
    for (int k = 0; k < 12; k++) queue_packet(NORTH, k % VCS, 4, 2, 2);
    queue_packet(LOCAL, 0, 4, 2, 1);
    wait_drain(3000, "T7");

    // -- T8: randomized soak ---------------------------------------------------
    banner("T8  randomized soak: random dest / length / VC / gap / credit delay");
    gap_max          = 2;
    credit_max_delay = 3;
    for (int k = 0; k < 220; k++) begin
      int ip, iv, dx, dy, len;
      ip  = rnd(PORTS);
      iv  = rnd(VCS);
      dx  = rnd(6);
      dy  = rnd(6);
      len = 1 + rnd(MAX_LEN);
      queue_packet(ip, iv, dx, dy, len);
      if (rnd(16) == 0) @(posedge clk);
    end
    wait_drain(60000, "T8");
    gap_max          = 0;
    credit_max_delay = 0;

    repeat (40) @(posedge clk);

    // -- final structural checks -----------------------------------------------
    for (int i = 0; i < NVC; i++) begin
      if (inq_size(i) != 0)
        fail($sformatf("input FIFO %0d still holds %0d flits", i, inq_size(i)));
      if (ord_size(i) != 0)
        fail($sformatf("order list %0d still expects %0d packets",
                       i, ord_size(i)));
      if (rx_busy[i])
        fail($sformatf("output VC %0d ended mid-packet (tail never arrived)", i));
    end
    if (pkts_done != next_id)
      fail($sformatf("only %0d of %0d packets delivered", pkts_done, next_id));
    if (flits_recv != flits_sent)
      fail($sformatf("flit count mismatch: sent %0d, received %0d",
                     flits_sent, flits_recv));

    // -- invariant 6: credits returned upstream == flits consumed --------------
    begin
      int total_ret;
      total_ret = 0;
      for (int i = 0; i < NVC; i++) total_ret = total_ret + cred_ret_cnt[i];
      if (total_ret != flits_sent)
        fail($sformatf("upstream credit imbalance: %0d returned, %0d flits consumed",
                       total_ret, flits_sent));
    end
    if (perf_flits !== 32'(flits_sent))
      fail($sformatf("perf_flits_o=%0d disagrees with %0d flits traversed",
                     perf_flits, flits_sent));
    if (perf_packets !== 32'(next_id))
      fail($sformatf("perf_packets_o=%0d disagrees with %0d packets",
                     perf_packets, next_id));
    if (dbg_ovc_busy !== '0)
      fail("output VCs still allocated after the network drained");

    $display("");
    $display("  packets delivered : %0d", next_id);
    $display("  flits traversed   : %0d", flits_sent);
    $display("  perf_flits_o      : %0d", perf_flits);
    $display("  perf_packets_o    : %0d", perf_packets);
    $display("  VA stall cycles   : %0d", perf_va_stall);
    $display("  SA stall cycles   : %0d", perf_sa_stall);
    $display("  simulated cycles  : %0d", cycle);
    $display("  errors            : %0d", errors);
    $display("");

    if (errors == 0) $display("RESULT: *** PASS ***");
    else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
    $finish;
  end

  // ---------------------------------------------------------------------------
  // Global timeout
  // ---------------------------------------------------------------------------
  initial begin
    #(TIMEOUT * 10);
    $display("[%0t] ERROR: global timeout at cycle %0d (%0d of %0d packets)",
             $time, cycle, pkts_done, next_id);
    $display("RESULT: *** FAIL *** (timeout)");
    $finish;
  end

endmodule
