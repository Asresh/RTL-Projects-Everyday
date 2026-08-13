// ============================================================================
// Day 29 : Hardware Nanosecond-Timestamp & Tick-to-Trade Latency Monitor
// ----------------------------------------------------------------------------
// The instrumentation stage of the HFT tick-to-trade path: the block that
// *measures* ultra-low latency in hardware, on the wire, with no CPU, no host
// clock read, and no software timer jitter. Three pieces, all deterministic:
//
//   1. NCO ("DDS") fractional-nanosecond free-running clock. A phase
//      accumulator advances by a Q(int).FRAC_W nanoseconds-per-cycle word
//      (`inc_i`) every active clock. The integer part is the current wire
//      timestamp `now_o`. Because the increment is fractional, the timestamp
//      tracks a clock whose period is NOT an integer number of ns (the real
//      case), and `inc_i` doubles as the frequency-correction word a PTP /
//      IEEE-1588 servo would nudge to discipline the counter to grandmaster
//      time -- sub-ns resolution from an integer counter.
//
//   2. Tag-matched timestamp capture. A start event `t0` (a tick arriving at
//      ingress) and a stop event `t1` (the order leaving at egress) each carry
//      a small TAG. `t0` stamps `now` into a direct-mapped slot `t0_ts[tag]`
//      and marks it busy; `t1` reads the slot, forms the wrap-safe modular
//      difference `now - t0_ts[tag]` = the round-trip latency, and frees the
//      slot. Direct-mapped => no CAM, no search, O(1), occupancy-independent.
//      A `t1` with no matching `t0` is reported as an orphan (dropped probe).
//
//   3. Latency statistics + power-of-two histogram. Every completed
//      measurement updates min / max / last / count / running-sum (for mean)
//      and bumps one saturating histogram bin, indexed by floor(log2(lat)).
//      A log2 (order-of-magnitude) histogram is exactly how HFT teams read
//      TAIL latency -- the p99/p99.9 that actually loses races -- because the
//      mean hides it. Everything is registered: a `t1` at cycle C yields the
//      measurement and updated stats at cycle C+1, no matter the latency value
//      or how many probes are outstanding. Worst-case latency == typical.
//
// Latch-free, `default_nettype none`, synchronous active-high reset, fully
// parameterized. No vendor primitives -- portable RTL.
// ============================================================================
`default_nettype none
`timescale 1ns/1ps

module latency_monitor #(
    parameter int TS_W   = 32,   // integer timestamp width (ns)
    parameter int FRAC_W = 16,   // NCO fractional bits (sub-ns phase)
    parameter int INC_W  = 24,   // ns-per-cycle increment word width (Q(INC_W-FRAC_W).FRAC_W)
    parameter int TAG_W  = 3,    // probe tag width -> NTAG = 2**TAG_W outstanding slots
    parameter int NBINS  = 8,    // number of power-of-two latency histogram bins
    parameter int CNT_W  = 32,   // measurement / orphan counter width (saturating)
    parameter int SUM_W  = 48,   // running latency-sum width (for mean) (saturating)
    parameter int HIST_W = 32    // per-bin histogram counter width (saturating)
) (
    input  wire                     clk,
    input  wire                     rst,      // synchronous, active-high

    // ---- NCO timestamp clock -------------------------------------------------
    input  wire                     run_i,    // advance the timestamp this cycle
    input  wire [INC_W-1:0]         inc_i,    // ns-per-cycle, Q(INC_W-FRAC_W).FRAC_W
    output wire [TS_W-1:0]          now_o,    // current integer-ns wire timestamp

    // ---- start (t0) / stop (t1) probe events --------------------------------
    input  wire                     t0_valid_i,
    input  wire [TAG_W-1:0]         t0_tag_i,
    input  wire                     t1_valid_i,
    input  wire [TAG_W-1:0]         t1_tag_i,

    // ---- per-measurement result (registered, 1-cycle after a matched t1) ----
    output reg                      meas_valid_o,
    output reg  [TAG_W-1:0]         meas_tag_o,
    output reg  [TS_W-1:0]          meas_lat_o,
    output reg                      orphan_o,     // t1 with no matching t0

    // ---- rolling statistics (registered) ------------------------------------
    output reg  [CNT_W-1:0]         cnt_o,        // # completed measurements
    output reg  [TS_W-1:0]          min_o,
    output reg  [TS_W-1:0]          max_o,
    output reg  [TS_W-1:0]          last_o,
    output reg  [SUM_W-1:0]         sum_o,        // sum of latencies (mean = sum/cnt)
    output reg  [CNT_W-1:0]         orphan_cnt_o,
    output reg  [TAG_W:0]           outstanding_o,// # currently-armed t0 slots (popcount)

    // ---- power-of-two latency histogram (flattened, registered) -------------
    output reg  [NBINS*HIST_W-1:0]  hist_flat_o
);
    // ------------------------------------------------------------------ derived
    localparam int PHASE_W  = TS_W + FRAC_W;   // phase accumulator width
    localparam int NTAG     = 1 << TAG_W;
    localparam int BINSEL_W = (NBINS > 1) ? $clog2(NBINS) : 1;

    // =========================================================================
    // 1. NCO fractional-nanosecond phase accumulator
    // =========================================================================
    reg [PHASE_W-1:0] phase_acc;

    always_ff @(posedge clk) begin
        if (rst)
            phase_acc <= '0;
        else if (run_i)
            phase_acc <= phase_acc + {{(PHASE_W-INC_W){1'b0}}, inc_i};
    end

    // integer nanoseconds = phase >> FRAC_W  (combinational slice of a register)
    wire [TS_W-1:0] now_ns = phase_acc[PHASE_W-1:FRAC_W];
    assign now_o = now_ns;

    // =========================================================================
    // 2. Tag-matched timestamp-capture table (direct-mapped, O(1))
    // =========================================================================
    reg [TS_W-1:0] t0_ts [NTAG];   // stamped start time per tag
    reg [NTAG-1:0] busy;           // slot armed (a t0 awaiting its t1)

    // Combinational view of "does this cycle's t1 match an armed slot?"
    wire        t1_hit  = t1_valid_i & busy[t1_tag_i];
    // wrap-safe modular latency (truncate to TS_W handles the counter roll-over)
    wire [TS_W-1:0] lat = now_ns - t0_ts[t1_tag_i];

    // -------- power-of-two bin index of a latency value ----------------------
    // bin = min( floor(log2(lat)) , NBINS-1 );  lat==0 -> bin 0.
    // Top bin is a catch-all for everything >= 2**(NBINS-1).
    function automatic [BINSEL_W-1:0] log2bin(input [TS_W-1:0] v);
        integer i;
        reg [BINSEL_W-1:0] b;
        begin
            b = '0;                                   // default: bin 0 (lat 0 or 1)
            for (i = 0; i < TS_W; i = i + 1)
                if (v[i]) b = (i > (NBINS-1)) ? (NBINS-1) : i[BINSEL_W-1:0];
            log2bin = b;
        end
    endfunction

    // saturating +1 helpers -------------------------------------------------
    function automatic [CNT_W-1:0] inc_cnt(input [CNT_W-1:0] c);
        inc_cnt = (&c) ? c : c + 1'b1;
    endfunction
    function automatic [HIST_W-1:0] inc_hist(input [HIST_W-1:0] c);
        inc_hist = (&c) ? c : c + 1'b1;
    endfunction

    // popcount of busy for the outstanding gauge -----------------------------
    function automatic [TAG_W:0] popcount(input [NTAG-1:0] v);
        integer i;
        reg [TAG_W:0] s;
        begin
            s = '0;
            for (i = 0; i < NTAG; i = i + 1) s = s + v[i];
            popcount = s;
        end
    endfunction

    // unpacked histogram working copy (packed<->unpacked at the boundary) ----
    reg [HIST_W-1:0] hist [NBINS];

    integer k;
    reg [NTAG-1:0]     busy_nxt;
    reg [BINSEL_W-1:0] bin;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < NTAG;  k = k + 1) begin t0_ts[k] <= '0; end
            busy          <= '0;
            meas_valid_o  <= 1'b0;
            meas_tag_o    <= '0;
            meas_lat_o    <= '0;
            orphan_o      <= 1'b0;
            cnt_o         <= '0;
            min_o         <= '0;
            max_o         <= '0;
            last_o        <= '0;
            sum_o         <= '0;
            orphan_cnt_o  <= '0;
            outstanding_o <= '0;
            for (k = 0; k < NBINS; k = k + 1) hist[k] <= '0;
        end else begin
            // default single-cycle strobes low
            meas_valid_o <= 1'b0;
            orphan_o     <= 1'b0;

            // ---- t1: measure a matched probe -------------------------------
            busy_nxt = busy;
            if (t1_hit) begin
                meas_valid_o <= 1'b1;
                meas_tag_o   <= t1_tag_i;
                meas_lat_o   <= lat;
                busy_nxt[t1_tag_i] = 1'b0;   // free the slot

                // rolling stats
                last_o <= lat;
                cnt_o  <= inc_cnt(cnt_o);
                sum_o  <= (&sum_o[SUM_W-1:0]) ? sum_o :
                          (sum_o + {{(SUM_W-TS_W){1'b0}}, lat});
                if (cnt_o == '0) begin           // first-ever measurement
                    min_o <= lat;
                    max_o <= lat;
                end else begin
                    if (lat < min_o) min_o <= lat;
                    if (lat > max_o) max_o <= lat;
                end
                bin        = log2bin(lat);
                hist[bin] <= inc_hist(hist[bin]);
            end else if (t1_valid_i) begin
                // t1 with no armed t0 -> orphan probe
                orphan_o     <= 1'b1;
                orphan_cnt_o <= inc_cnt(orphan_cnt_o);
            end

            // ---- t0: arm a slot (takes precedence for the slot bit) --------
            if (t0_valid_i) begin
                t0_ts[t0_tag_i]     <= now_ns;
                busy_nxt[t0_tag_i]  = 1'b1;
            end

            busy          <= busy_nxt;
            outstanding_o <= popcount(busy_nxt);
        end
    end

    // pack the unpacked histogram into the flat output bus -------------------
    integer m;
    always_comb begin
        hist_flat_o = '0;
        for (m = 0; m < NBINS; m = m + 1)
            hist_flat_o[m*HIST_W +: HIST_W] = hist[m];
    end

`ifdef FORMAL
    // a freed slot is never simultaneously reported busy in the gauge
    always @(posedge clk) if (!rst)
        assert (outstanding_o <= NTAG);
`endif
endmodule

`default_nettype wire
