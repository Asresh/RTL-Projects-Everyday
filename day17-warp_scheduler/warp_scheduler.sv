`default_nettype none
//============================================================================
// warp_scheduler.sv  --  Day 17
//
// GPU SM instruction-issue front-end.  Each cycle the scheduler looks at the
// decoded head instruction of every resident warp, decides which warps are
// *ready* (their operands are not waiting on an in-flight write), and issues
// exactly ONE warp using the Greedy-Then-Oldest (GTO) policy used by NVIDIA-
// class SMs / GPGPU-Sim:
//
//    * GREEDY : keep issuing from the same warp as long as it stays ready
//               (maximises per-warp locality / cuts scheduling churn), THEN
//    * OLDEST : when that warp stalls, fall back to the oldest ready warp.
//               All warps are resident from t0, so "oldest" == lowest warp id.
//
// Hazards are tracked by a per-warp register SCOREBOARD.  When a warp issues an
// instruction that writes register Rd, bit pending[warp][Rd] is set and the
// write travels a fixed-latency writeback pipeline; when it retires the bit is
// cleared.  A warp head instruction is blocked while any register it *reads*
// (RAW) or the register it *writes* (WAW) is still pending -- the classic
// in-order scoreboard interlock that keeps a SIMT lane's results correct
// without a full register-renaming out-of-order engine.
//
// Fully synthesizable, reset-safe, parameterized, single always_ff.
//============================================================================
module warp_scheduler #(
    parameter int NW         = 8,   // number of resident warps
    parameter int NREG       = 8,   // architectural registers per warp (scoreboard width)
    parameter int WB_LATENCY = 4,   // issue -> writeback latency (cycles a dest stays pending)
    // ---- derived widths (do not override) --------------------------------
    parameter int WIDW       = (NW   <= 1) ? 1 : $clog2(NW),
    parameter int RIDW       = (NREG <= 1) ? 1 : $clog2(NREG)
)(
    input  wire                   clk,
    input  wire                   rst_n,        // active-low async reset

    // ---- per-warp decoded head instruction (packed, warp0 in the LSBs) ----
    input  wire [NW-1:0]          ib_valid,     // 1 = warp w has an instruction ready to consider
    input  wire [NW-1:0]          ib_wdst,      // 1 = instruction writes a destination register
    input  wire [NW-1:0]          ib_use0,      // 1 = instruction reads source-0
    input  wire [NW-1:0]          ib_use1,      // 1 = instruction reads source-1
    input  wire [NW*RIDW-1:0]     ib_dst,       // destination register index (per warp)
    input  wire [NW*RIDW-1:0]     ib_src0,      // source-0 register index (per warp)
    input  wire [NW*RIDW-1:0]     ib_src1,      // source-1 register index (per warp)

    // ---- issue result (combinational, at most one warp per cycle) ---------
    output logic                  issue_valid,  // a warp issues this cycle
    output logic [WIDW-1:0]       issue_warp,   // which warp issued
    output logic [NW-1:0]         issue_onehot, // one-hot issue_warp (IB consume strobe)
    output logic [NW-1:0]         ready_mask    // warps eligible to issue this cycle (observability)
);

    // ---- scoreboard: pending[w][r] == 1 while a write to warp w reg r is in flight
    logic [NREG-1:0] pending [NW];

    // ---- GTO state: the warp we issued from the last time we issued --------
    logic [WIDW-1:0] last_warp;
    logic            last_valid;

    // ---- writeback shift pipeline (depth WB_LATENCY) ----------------------
    logic            wb_v [WB_LATENCY];   // stage carries a valid writeback
    logic [WIDW-1:0] wb_w [WB_LATENCY];   // ... for this warp
    logic [RIDW-1:0] wb_r [WB_LATENCY];   // ... to this register

    // process temporaries (module scope for Icarus friendliness)
    logic            hz0, hz1, hzd;
    logic [RIDW-1:0] dst_w, s0_w, s1_w;

    // ---------------------------------------------------------------------
    // 1) Combinational readiness: a warp is ready when it has an instruction
    //    and none of its consumed/produced registers are pending.
    // ---------------------------------------------------------------------
    always_comb begin
        ready_mask = '0;
        for (int w = 0; w < NW; w++) begin
            dst_w = ib_dst [w*RIDW +: RIDW];
            s0_w  = ib_src0[w*RIDW +: RIDW];
            s1_w  = ib_src1[w*RIDW +: RIDW];
            hz0   = ib_use0[w] & pending[w][s0_w];   // RAW on source 0
            hz1   = ib_use1[w] & pending[w][s1_w];   // RAW on source 1
            hzd   = ib_wdst[w] & pending[w][dst_w];  // WAW on destination
            ready_mask[w] = ib_valid[w] & ~(hz0 | hz1 | hzd);
        end
    end

    // ---------------------------------------------------------------------
    // 2) "Oldest" ready warp == lowest set index of ready_mask.
    // ---------------------------------------------------------------------
    logic [WIDW-1:0] oldest_warp;
    logic            any_ready;
    always_comb begin
        any_ready   = |ready_mask;
        oldest_warp = '0;
        for (int w = NW-1; w >= 0; w--)
            if (ready_mask[w]) oldest_warp = w[WIDW-1:0];
    end

    // ---------------------------------------------------------------------
    // 3) GTO selection: stay greedy on last_warp if still ready, else oldest.
    // ---------------------------------------------------------------------
    logic greedy_ok;
    always_comb begin
        greedy_ok    = last_valid & ready_mask[last_warp];
        issue_valid  = any_ready & rst_n;   // never issue while held in reset

        issue_warp   = greedy_ok ? last_warp : oldest_warp;
        issue_onehot = '0;
        if (issue_valid) issue_onehot[issue_warp] = 1'b1;
    end

    // destination of the issuing warp (only meaningful when issue_valid)
    logic [RIDW-1:0] issue_dst;
    logic            issue_wr;
    assign issue_dst = ib_dst[issue_warp*RIDW +: RIDW];
    assign issue_wr  = issue_valid & ib_wdst[issue_warp];

    // ---------------------------------------------------------------------
    // 4) Sequential: scoreboard set/clear, writeback pipeline, GTO state.
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int w = 0; w < NW; w++) pending[w] <= '0;
            for (int i = 0; i < WB_LATENCY; i++) begin
                wb_v[i] <= 1'b0;
                wb_w[i] <= '0;
                wb_r[i] <= '0;
            end
            last_warp  <= '0;
            last_valid <= 1'b0;
        end else begin
            // (a) retire the writeback leaving the tail -> clear scoreboard bit
            if (wb_v[WB_LATENCY-1])
                pending[wb_w[WB_LATENCY-1]][wb_r[WB_LATENCY-1]] <= 1'b0;

            // (b) advance the writeback pipeline
            for (int i = WB_LATENCY-1; i > 0; i--) begin
                wb_v[i] <= wb_v[i-1];
                wb_w[i] <= wb_w[i-1];
                wb_r[i] <= wb_r[i-1];
            end
            wb_v[0] <= issue_wr;
            wb_w[0] <= issue_warp;
            wb_r[0] <= issue_dst;

            // (c) set the scoreboard for the newly issued destination
            //     (a WAW-blocked reg can never be set here, so no collision
            //      with the retire in (a) on the same {warp,reg}).
            if (issue_wr)
                pending[issue_warp][issue_dst] <= 1'b1;

            // (d) GTO bookkeeping: remember who we just issued
            if (issue_valid) begin
                last_warp  <= issue_warp;
                last_valid <= 1'b1;
            end
        end
    end

endmodule
`default_nettype wire
