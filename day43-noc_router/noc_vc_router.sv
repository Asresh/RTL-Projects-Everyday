// -----------------------------------------------------------------------------
// Day 43 - Wormhole Virtual-Channel NoC Router (5-port mesh node)
//
// A synthesizable input-buffered router for a 2-D mesh network-on-chip.
//
//   * 5 physical ports (North, East, South, West, Local)
//   * VCS virtual channels per input port, each with its own flit FIFO and its
//     own wormhole state machine, so a packet blocked on one output cannot
//     head-of-line block an unrelated packet arriving on the same wire
//   * dimension-order (XY) route computation - deadlock free on a mesh
//   * separable virtual-channel allocator (rotating priority, at most one grant
//     per output VC per cycle)
//   * two-stage separable switch allocator: input-port arbitration first, then
//     output-port arbitration, both rotating priority
//   * credit-based flow control on every output VC; a flit is launched only
//     when the downstream buffer is known to have a free slot
//
// Pipeline (classic 3-stage virtual-channel router):
//
//   BW/RC : head flit reaches the front of an input VC -> XY route computed
//   VA    : that input VC bids for a free virtual channel on its output port
//   SA/ST : that input VC bids for the crossbar, wins, and traverses it
//
// Body and tail flits inherit the head's output port and output VC and re-run
// only the SA/ST stage.  That is what makes this wormhole rather than
// store-and-forward routing: one packet may be spread across several routers,
// and its buffers stay reserved until the tail passes.
//
// Flit format (FLIT_WIDTH bits):
//
//   [FLIT_WIDTH-1]                  tail bit
//   [FLIT_WIDTH-2]                  head bit   (11 = single-flit packet)
//   [FLIT_WIDTH-3 : 2*COORD_WIDTH]  opaque payload, untouched by the router
//   [2*COORD_WIDTH-1 : COORD_WIDTH] dest_y     (head flits only)
//   [COORD_WIDTH-1 : 0]             dest_x     (head flits only)
//
// All per-port buses are flattened so the port list stays simple and portable.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module noc_vc_router #(
    parameter int PORTS       = 5,   // fixed at 5 for a 2-D mesh node
    parameter int VCS         = 2,   // virtual channels per input port
    parameter int FLIT_WIDTH  = 32,  // must exceed 2 + 2*COORD_WIDTH
    parameter int BUF_DEPTH   = 4,   // flit slots per input VC
    parameter int COORD_WIDTH = 4,   // mesh coordinate width
    // ---- derived; do not override ------------------------------------------
    parameter int VCW         = (VCS > 1) ? $clog2(VCS) : 1,
    parameter int CNTW        = $clog2(BUF_DEPTH + 1)
) (
    input  logic                          clk,
    input  logic                          rst_n,

    // This router's mesh coordinates (tie to constants in a real mesh).
    input  logic [COORD_WIDTH-1:0]        my_x_i,
    input  logic [COORD_WIDTH-1:0]        my_y_i,

    // ---- upstream -> router : at most one flit per physical port per cycle --
    input  logic [PORTS-1:0]              in_valid_i,
    input  logic [PORTS*VCW-1:0]          in_vc_i,
    input  logic [PORTS*FLIT_WIDTH-1:0]   in_flit_i,
    output logic [PORTS*VCS-1:0]          in_ready_o,       // per (port,vc)

    // ---- router -> upstream : credit return when an input slot frees -------
    output logic [PORTS-1:0]              in_credit_valid_o,
    output logic [PORTS*VCW-1:0]          in_credit_vc_o,

    // ---- router -> downstream ----------------------------------------------
    output logic [PORTS-1:0]              out_valid_o,
    output logic [PORTS*VCW-1:0]          out_vc_o,
    output logic [PORTS*FLIT_WIDTH-1:0]   out_flit_o,

    // ---- downstream -> router : credit return ------------------------------
    input  logic [PORTS-1:0]              out_credit_valid_i,
    input  logic [PORTS*VCW-1:0]          out_credit_vc_i,

    // ---- observability ------------------------------------------------------
    output logic [PORTS*VCS*2-1:0]        dbg_state_o,      // per input VC
    output logic [PORTS*VCS-1:0]          dbg_ovc_busy_o,   // per output VC
    output logic [PORTS*VCS*CNTW-1:0]     dbg_occupancy_o,  // per input VC
    output logic [PORTS*VCS*CNTW-1:0]     dbg_credit_o,     // per output VC
    output logic [31:0]                   perf_flits_o,
    output logic [31:0]                   perf_packets_o,
    output logic [31:0]                   perf_va_stall_o,
    output logic [31:0]                   perf_sa_stall_o
);

  localparam int PW   = (PORTS > 1) ? $clog2(PORTS) : 1;
  localparam int PTRW = (BUF_DEPTH > 1) ? $clog2(BUF_DEPTH) : 1;
  localparam int NVC  = PORTS * VCS;

  // Physical port numbering.
  localparam int NORTH = 0;
  localparam int EAST  = 1;
  localparam int SOUTH = 2;
  localparam int WEST  = 3;
  localparam int LOCAL = 4;

  // Input-VC wormhole states.
  localparam logic [1:0] ST_IDLE   = 2'd0;  // waiting for a head flit
  localparam logic [1:0] ST_ROUTED = 2'd1;  // output port known, needs a VC
  localparam logic [1:0] ST_ACTIVE = 2'd2;  // owns an output VC, streaming

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------
  logic [FLIT_WIDTH-1:0] fbuf    [NVC][BUF_DEPTH];
  logic [PTRW-1:0]       rd_ptr  [NVC];
  logic [PTRW-1:0]       wr_ptr  [NVC];
  logic [CNTW-1:0]       occ     [NVC];   // input-VC occupancy
  logic [1:0]            st      [NVC];
  logic [PW-1:0]         oport_r [NVC];   // route-computation result
  logic [VCW-1:0]        ovc_r   [NVC];   // VC-allocation result

  logic [NVC-1:0]        ovc_busy;        // output VC owned by some input VC
  logic [CNTW-1:0]       credit  [NVC];   // downstream free slots, per out VC

  // Rotating-priority pointers.
  logic [7:0]      va_ptr;            // over all input VCs
  logic [VCW-1:0]  va_vcptr;          // over candidate output VCs
  logic [VCW-1:0]  sa_iptr [PORTS];   // input-side arbiter
  logic [PW-1:0]   sa_optr [PORTS];   // output-side arbiter

  // Registered outputs.
  logic [PORTS-1:0]      out_valid_q;
  logic [VCW-1:0]        out_vc_q   [PORTS];
  logic [FLIT_WIDTH-1:0] out_flit_q [PORTS];
  logic [PORTS-1:0]      cred_valid_q;
  logic [VCW-1:0]        cred_vc_q  [PORTS];

  logic [31:0] flits_q, packets_q, va_stall_q, sa_stall_q;

  // ---------------------------------------------------------------------------
  // Input unpacking
  // ---------------------------------------------------------------------------
  logic [FLIT_WIDTH-1:0] in_flit  [PORTS];
  logic [VCW-1:0]        in_vc    [PORTS];
  logic [VCW-1:0]        ocred_vc [PORTS];

  always_comb begin : unpack
    for (int p = 0; p < PORTS; p++) begin
      in_flit[p]  = in_flit_i[p*FLIT_WIDTH +: FLIT_WIDTH];
      in_vc[p]    = in_vc_i[p*VCW +: VCW];
      ocred_vc[p] = out_credit_vc_i[p*VCW +: VCW];
    end
  end

  // ---------------------------------------------------------------------------
  // Dimension-order (XY) route computation
  //
  // All X hops complete before any Y hop is taken, so the channel dependency
  // graph is acyclic and the mesh cannot deadlock even though wormhole packets
  // hold buffers in several routers simultaneously.
  // ---------------------------------------------------------------------------
  function automatic logic [PW-1:0] route_xy(input logic [COORD_WIDTH-1:0] dx,
                                             input logic [COORD_WIDTH-1:0] dy,
                                             input logic [COORD_WIDTH-1:0] mx,
                                             input logic [COORD_WIDTH-1:0] my);
    if (dx > mx)      route_xy = PW'(EAST);
    else if (dx < mx) route_xy = PW'(WEST);
    else if (dy > my) route_xy = PW'(NORTH);
    else if (dy < my) route_xy = PW'(SOUTH);
    else              route_xy = PW'(LOCAL);
  endfunction

  // ---------------------------------------------------------------------------
  // Stage VA - virtual-channel allocation
  //
  // Every input VC in ST_ROUTED bids for any free VC on its computed output
  // port.  Requesters are visited in rotating order so no input VC can be
  // starved, and `va_taken` stops two winners from being handed the same
  // output VC in one cycle.
  // ---------------------------------------------------------------------------
  logic [NVC-1:0] va_grant;
  logic [VCW-1:0] va_vc [NVC];
  logic [NVC-1:0] va_taken;
  logic [NVC-1:0] va_request;

  always_comb begin : vc_alloc
    int pv, cand, idx;
    logic found;

    va_grant   = '0;
    va_taken   = '0;
    va_request = '0;
    for (int i = 0; i < NVC; i++) va_vc[i] = '0;

    for (int i = 0; i < NVC; i++) begin
      pv = int'(va_ptr) + i;
      if (pv >= NVC) pv -= NVC;

      if (st[pv] == ST_ROUTED) begin
        va_request[pv] = 1'b1;
        found = 1'b0;
        for (int v = 0; v < VCS; v++) begin
          cand = int'(va_vcptr) + v;
          if (cand >= VCS) cand -= VCS;
          idx = int'(oport_r[pv]) * VCS + cand;
          if (!found && !ovc_busy[idx] && !va_taken[idx]) begin
            found         = 1'b1;
            va_taken[idx] = 1'b1;
            va_grant[pv]  = 1'b1;
            va_vc[pv]     = VCW'(cand);
          end
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Stage SA - separable two-stage switch allocation
  //
  // An input VC may bid only if it owns an output VC (ST_ACTIVE), holds a flit,
  // and has a downstream credit.  Stage 1 picks one VC per input port (only one
  // flit can leave a physical input per cycle); stage 2 picks one input port per
  // output port (only one flit can enter a physical output per cycle).  The two
  // stages together produce a conflict-free crossbar schedule.
  // ---------------------------------------------------------------------------
  logic [NVC-1:0]   sa_req;
  logic [NVC-1:0]   sw_grant;
  logic [NVC-1:0]   ovc_launch;     // output VC receiving a flit this cycle
  logic [PORTS-1:0] ip_win_any;
  logic [VCW-1:0]   ip_win_vc  [PORTS];
  logic [PORTS-1:0] op_grant_any;
  logic [PW-1:0]    op_grant_in [PORTS];

  always_comb begin : switch_alloc
    int pv, cand, cidx;

    // --- request vector -----------------------------------------------------
    for (int i = 0; i < NVC; i++) begin
      cidx      = int'(oport_r[i]) * VCS + int'(ovc_r[i]);
      sa_req[i] = (st[i] == ST_ACTIVE) && (occ[i] != '0) && (credit[cidx] != '0);
    end

    // --- stage 1 : one winner per input port --------------------------------
    for (int p = 0; p < PORTS; p++) begin
      ip_win_any[p] = 1'b0;
      ip_win_vc[p]  = '0;
      for (int v = 0; v < VCS; v++) begin
        cand = int'(sa_iptr[p]) + v;
        if (cand >= VCS) cand -= VCS;
        pv = p * VCS + cand;
        if (!ip_win_any[p] && sa_req[pv]) begin
          ip_win_any[p] = 1'b1;
          ip_win_vc[p]  = VCW'(cand);
        end
      end
    end

    // --- stage 2 : one winner per output port -------------------------------
    sw_grant   = '0;
    ovc_launch = '0;
    for (int o = 0; o < PORTS; o++) begin
      op_grant_any[o] = 1'b0;
      op_grant_in[o]  = '0;
      for (int k = 0; k < PORTS; k++) begin
        cand = int'(sa_optr[o]) + k;
        if (cand >= PORTS) cand -= PORTS;
        pv = cand * VCS + int'(ip_win_vc[cand]);
        if (!op_grant_any[o] && ip_win_any[cand] && (int'(oport_r[pv]) == o)) begin
          op_grant_any[o] = 1'b1;
          op_grant_in[o]  = PW'(cand);
          sw_grant[pv]    = 1'b1;
          ovc_launch[o*VCS + int'(ovc_r[pv])] = 1'b1;
        end
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Write-side acceptance
  // ---------------------------------------------------------------------------
  logic [NVC-1:0] push;

  always_comb begin : write_side
    push = '0;
    for (int p = 0; p < PORTS; p++)
      if (in_valid_i[p] && (occ[p*VCS + int'(in_vc[p])] != CNTW'(BUF_DEPTH)))
        push[p*VCS + int'(in_vc[p])] = 1'b1;
    for (int i = 0; i < NVC; i++)
      in_ready_o[i] = (occ[i] != CNTW'(BUF_DEPTH));
  end

  // ---------------------------------------------------------------------------
  // Sequential update
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin : seq
    logic [FLIT_WIDTH-1:0] head_flit, sent_flit;
    logic [CNTW-1:0]       occ_next;
    logic                  inc, dec;
    int                    cidx;
    int                    n_flits, n_tails;

    if (!rst_n) begin
      for (int i = 0; i < NVC; i++) begin
        rd_ptr[i]  <= '0;
        wr_ptr[i]  <= '0;
        occ[i]     <= '0;
        st[i]      <= ST_IDLE;
        oport_r[i] <= '0;
        ovc_r[i]   <= '0;
        credit[i]  <= CNTW'(BUF_DEPTH);
      end
      ovc_busy     <= '0;
      va_ptr       <= '0;
      va_vcptr     <= '0;
      for (int p = 0; p < PORTS; p++) begin
        sa_iptr[p]    <= '0;
        sa_optr[p]    <= '0;
        out_vc_q[p]   <= '0;
        out_flit_q[p] <= '0;
        cred_vc_q[p]  <= '0;
      end
      out_valid_q  <= '0;
      cred_valid_q <= '0;
      flits_q      <= '0;
      packets_q    <= '0;
      va_stall_q   <= '0;
      sa_stall_q   <= '0;
    end else begin
      out_valid_q  <= '0;
      cred_valid_q <= '0;

      // Rotating pointers advance every cycle, which bounds the waiting time
      // of every requester regardless of traffic pattern.
      va_ptr   <= (int'(va_ptr)   == NVC-1) ? 8'd0 : va_ptr + 8'd1;
      va_vcptr <= (int'(va_vcptr) == VCS-1) ? '0   : va_vcptr + 1'b1;

      // Up to PORTS flits traverse the crossbar per cycle, so the counters are
      // accumulated in blocking temporaries and committed once - a nonblocking
      // increment inside the loop would only ever count one of them.
      n_flits = 0;
      n_tails = 0;

      // --- per input VC ------------------------------------------------------
      for (int i = 0; i < NVC; i++) begin
        occ_next = occ[i];

        // buffer write
        if (push[i]) begin
          fbuf[i][wr_ptr[i]] <= in_flit[i/VCS];
          wr_ptr[i] <= (int'(wr_ptr[i]) == BUF_DEPTH-1) ? '0 : wr_ptr[i] + 1'b1;
          occ_next  = occ_next + 1'b1;
        end

        // crossbar traversal: pop the granted flit
        if (sw_grant[i]) begin
          sent_flit = fbuf[i][rd_ptr[i]];
          rd_ptr[i] <= (int'(rd_ptr[i]) == BUF_DEPTH-1) ? '0 : rd_ptr[i] + 1'b1;
          occ_next  = occ_next - 1'b1;

          out_valid_q[oport_r[i]] <= 1'b1;
          out_vc_q[oport_r[i]]    <= ovc_r[i];
          out_flit_q[oport_r[i]]  <= sent_flit;

          // exactly one flit left this physical input -> return one credit
          cred_valid_q[i/VCS] <= 1'b1;
          cred_vc_q[i/VCS]    <= VCW'(i % VCS);

          // the tail tears the circuit down and frees the output VC
          if (sent_flit[FLIT_WIDTH-1]) begin
            st[i]                                            <= ST_IDLE;
            ovc_busy[int'(oport_r[i])*VCS + int'(ovc_r[i])]   <= 1'b0;
            n_tails = n_tails + 1;
          end
          n_flits = n_flits + 1;
        end

        // route computation on the head flit sitting at the read pointer
        if ((st[i] == ST_IDLE) && (occ[i] != '0)) begin
          head_flit = fbuf[i][rd_ptr[i]];
          if (head_flit[FLIT_WIDTH-2]) begin  // head bit set
            oport_r[i] <= route_xy(head_flit[COORD_WIDTH-1:0],
                                   head_flit[2*COORD_WIDTH-1:COORD_WIDTH],
                                   my_x_i, my_y_i);
            st[i]      <= ST_ROUTED;
          end
        end

        // virtual-channel allocation result
        if ((st[i] == ST_ROUTED) && va_grant[i]) begin
          ovc_r[i]                                          <= va_vc[i];
          ovc_busy[int'(oport_r[i])*VCS + int'(va_vc[i])]    <= 1'b1;
          st[i]                                             <= ST_ACTIVE;
        end

        occ[i] <= occ_next;
      end

      // --- credit counters ---------------------------------------------------
      for (int o = 0; o < PORTS; o++) begin
        for (int v = 0; v < VCS; v++) begin
          cidx = o * VCS + v;
          dec  = ovc_launch[cidx];
          inc  = out_credit_valid_i[o] && (int'(ocred_vc[o]) == v);
          if (dec && !inc)      credit[cidx] <= credit[cidx] - 1'b1;
          else if (inc && !dec) credit[cidx] <= credit[cidx] + 1'b1;
        end
      end

      // --- arbiter pointer updates -------------------------------------------
      for (int p = 0; p < PORTS; p++) begin
        if (op_grant_any[p])
          sa_optr[p] <= (int'(op_grant_in[p]) == PORTS-1) ? '0
                                                          : op_grant_in[p] + 1'b1;
        if (ip_win_any[p] && sw_grant[p*VCS + int'(ip_win_vc[p])])
          sa_iptr[p] <= (int'(ip_win_vc[p]) == VCS-1) ? '0 : ip_win_vc[p] + 1'b1;
      end

      // --- performance counters ----------------------------------------------
      flits_q   <= flits_q   + 32'(n_flits);
      packets_q <= packets_q + 32'(n_tails);
      if ((va_request & ~va_grant) != '0) va_stall_q <= va_stall_q + 1'b1;
      if ((sa_req    & ~sw_grant) != '0)  sa_stall_q <= sa_stall_q + 1'b1;
    end
  end

  // ---------------------------------------------------------------------------
  // Output packing
  // ---------------------------------------------------------------------------
  always_comb begin : pack
    out_valid_o       = out_valid_q;
    in_credit_valid_o = cred_valid_q;
    for (int p = 0; p < PORTS; p++) begin
      out_vc_o[p*VCW +: VCW]                 = out_vc_q[p];
      out_flit_o[p*FLIT_WIDTH +: FLIT_WIDTH] = out_flit_q[p];
      in_credit_vc_o[p*VCW +: VCW]           = cred_vc_q[p];
    end
    for (int i = 0; i < NVC; i++) begin
      dbg_state_o[i*2 +: 2]           = st[i];
      dbg_occupancy_o[i*CNTW +: CNTW] = occ[i];
      dbg_credit_o[i*CNTW +: CNTW]    = credit[i];
    end
    dbg_ovc_busy_o = ovc_busy;
  end

  assign perf_flits_o    = flits_q;
  assign perf_packets_o  = packets_q;
  assign perf_va_stall_o = va_stall_q;
  assign perf_sa_stall_o = sa_stall_q;

endmodule
