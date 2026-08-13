// ---------------------------------------------------------------------------
// Day 47 - Self-checking testbench for the out-of-order load/store queue
//
// The testbench is a small out-of-order machine wrapped around the LSU.  It
// owns a program-order table of memory ops and four independent drivers that
// deliberately pull those ops apart in time:
//
//   dispatch  - strictly in program order, one op per cycle, valid/ready
//   AGU (STA) - a randomly chosen dispatched op, after a per-op delay
//   STD       - store data, on its own port, with a different per-op delay
//   commit    - strictly in program order, from the head of the table
//
// Because dispatch and commit are in program order, the value a load must
// return is exactly the contents of the golden memory at the moment that load
// commits: every older store has committed by then and no younger store has.
// That single observation is what makes an exact reference model possible for a
// design whose whole purpose is to execute out of order.
//
// Three independent checkers:
//
//   1. Golden memory.       Every committed load is compared, byte-enable by
//                           byte-enable, against a flat reference memory that
//                           only ever advances at store commit.
//   2. Writeback tracking.  The testbench models the register file: a load's
//                           value is recorded on ld_wb_valid_o and DISCARDED on
//                           viol_valid_o for the victim and every younger load.
//                           Committing a load with no live writeback is a
//                           failure, so an under-reported squash set is caught
//                           even when the LSU quietly self-heals.
//   3. Drain order.         Every committed store is pushed onto an expectation
//                           FIFO; every memory write the LSU performs must
//                           match the head of it, in order, exactly once.
//
// Plus, continuously: no bus activity during reset, no writeback or violation
// for an op that is not in flight, viol_valid_o only ever naming a load that
// reported ld_wb_spec_o, commit only when the LSU says its head is ready, both
// queues empty at the end, and the whole data memory equal to the golden model.
// ---------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_lsq_disambiguation;

    // ---------------- geometry ------------------------------------------
    localparam int LQ_DEPTH = 8;
    localparam int SQ_DEPTH = 8;
    localparam int ADDR_W   = 12;
    localparam int DATA_W   = 32;
    localparam int ROB_W    = 6;
    localparam int URGENT   = 3;

    localparam int NB      = DATA_W / 8;
    localparam int LQ_AW   = $clog2(LQ_DEPTH);
    localparam int SQ_AW   = $clog2(SQ_DEPTH);
    localparam int LPTR_W  = LQ_AW + 2;
    localparam int SPTR_W  = SQ_AW + 2;
    localparam int WOFF    = $clog2(NB);
    localparam int WADDR_W = ADDR_W - WOFF;
    localparam int MEMW    = 1 << WADDR_W;

    localparam int MAXOPS      = 6000;
    localparam int MAX_CYCLES  = 400000;

    // ---------------- clock / reset --------------------------------------
    logic clk = 1'b0;
    logic rst_n;
    always #5 clk = ~clk;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---------------- DUT interface --------------------------------------
    logic               disp_valid_i, disp_is_store_i;
    logic [ROB_W-1:0]   disp_rob_i;
    logic               disp_lq_ready_o, disp_sq_ready_o;
    logic [LQ_AW-1:0]   disp_lq_idx_o;
    logic [SQ_AW-1:0]   disp_sq_idx_o;
    logic [LPTR_W-1:0]  disp_lq_tail_o;
    logic [SPTR_W-1:0]  disp_sq_tail_o;

    logic               ag_valid_i, ag_is_store_i;
    logic [SQ_AW-1:0]   ag_idx_i;
    logic [ADDR_W-1:0]  ag_addr_i;
    logic [NB-1:0]      ag_be_i;

    logic               sd_valid_i;
    logic [SQ_AW-1:0]   sd_idx_i;
    logic [DATA_W-1:0]  sd_data_i;

    logic               ld_wb_valid_o;
    logic [LQ_AW-1:0]   ld_wb_idx_o;
    logic [ROB_W-1:0]   ld_wb_rob_o;
    logic [DATA_W-1:0]  ld_wb_data_o;
    logic [NB-1:0]      ld_wb_be_o;
    logic               ld_wb_fwd_o, ld_wb_spec_o;
    logic               ld_replay_o;
    logic [1:0]         ld_replay_rsn_o;

    logic               viol_valid_o;
    logic [LQ_AW-1:0]   viol_idx_o;
    logic [ROB_W-1:0]   viol_rob_o;

    logic               commit_load_i, commit_store_i;
    logic               lq_head_ready_o, sq_head_ready_o;

    logic               flush_i;
    logic [LPTR_W-1:0]  flush_lq_tail_i;
    logic [SPTR_W-1:0]  flush_sq_tail_i;

    logic               dmem_req_o, dmem_we_o;
    logic [ADDR_W-1:0]  dmem_addr_o;
    logic [NB-1:0]      dmem_be_o;
    logic [DATA_W-1:0]  dmem_wdata_o;
    logic [DATA_W-1:0]  dmem_rdata_i;

    logic [LPTR_W-1:0]  lq_cnt_o;
    logic [SPTR_W-1:0]  sq_cnt_o, sq_uncommitted_o;
    logic [31:0] cnt_ld_exec_o, cnt_fwd_o, cnt_spec_o;
    logic [31:0] cnt_rp_partial_o, cnt_rp_nodata_o, cnt_rp_port_o, cnt_rp_kill_o;
    logic [31:0] cnt_viol_o, cnt_mem_rd_o, cnt_mem_wr_o;
    logic [31:0] cnt_drain_urgent_o, cnt_flush_o;

    lsq_disambiguation #(
        .LQ_DEPTH(LQ_DEPTH), .SQ_DEPTH(SQ_DEPTH), .ADDR_W(ADDR_W),
        .DATA_W(DATA_W), .ROB_W(ROB_W), .URGENT(URGENT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .disp_valid_i(disp_valid_i), .disp_is_store_i(disp_is_store_i),
        .disp_rob_i(disp_rob_i),
        .disp_lq_ready_o(disp_lq_ready_o), .disp_sq_ready_o(disp_sq_ready_o),
        .disp_lq_idx_o(disp_lq_idx_o), .disp_sq_idx_o(disp_sq_idx_o),
        .disp_lq_tail_o(disp_lq_tail_o), .disp_sq_tail_o(disp_sq_tail_o),
        .ag_valid_i(ag_valid_i), .ag_is_store_i(ag_is_store_i),
        .ag_idx_i(ag_idx_i), .ag_addr_i(ag_addr_i), .ag_be_i(ag_be_i),
        .sd_valid_i(sd_valid_i), .sd_idx_i(sd_idx_i), .sd_data_i(sd_data_i),
        .ld_wb_valid_o(ld_wb_valid_o), .ld_wb_idx_o(ld_wb_idx_o),
        .ld_wb_rob_o(ld_wb_rob_o), .ld_wb_data_o(ld_wb_data_o),
        .ld_wb_be_o(ld_wb_be_o), .ld_wb_fwd_o(ld_wb_fwd_o),
        .ld_wb_spec_o(ld_wb_spec_o), .ld_replay_o(ld_replay_o),
        .ld_replay_rsn_o(ld_replay_rsn_o),
        .viol_valid_o(viol_valid_o), .viol_idx_o(viol_idx_o),
        .viol_rob_o(viol_rob_o),
        .commit_load_i(commit_load_i), .commit_store_i(commit_store_i),
        .lq_head_ready_o(lq_head_ready_o), .sq_head_ready_o(sq_head_ready_o),
        .flush_i(flush_i), .flush_lq_tail_i(flush_lq_tail_i),
        .flush_sq_tail_i(flush_sq_tail_i),
        .dmem_req_o(dmem_req_o), .dmem_we_o(dmem_we_o),
        .dmem_addr_o(dmem_addr_o), .dmem_be_o(dmem_be_o),
        .dmem_wdata_o(dmem_wdata_o), .dmem_rdata_i(dmem_rdata_i),
        .lq_cnt_o(lq_cnt_o), .sq_cnt_o(sq_cnt_o),
        .sq_uncommitted_o(sq_uncommitted_o),
        .cnt_ld_exec_o(cnt_ld_exec_o), .cnt_fwd_o(cnt_fwd_o),
        .cnt_spec_o(cnt_spec_o), .cnt_rp_partial_o(cnt_rp_partial_o),
        .cnt_rp_nodata_o(cnt_rp_nodata_o), .cnt_rp_port_o(cnt_rp_port_o),
        .cnt_rp_kill_o(cnt_rp_kill_o), .cnt_viol_o(cnt_viol_o),
        .cnt_mem_rd_o(cnt_mem_rd_o), .cnt_mem_wr_o(cnt_mem_wr_o),
        .cnt_drain_urgent_o(cnt_drain_urgent_o), .cnt_flush_o(cnt_flush_o)
    );

    // =====================================================================
    //  Data memory model - single port, one-cycle synchronous read
    // =====================================================================
    logic [DATA_W-1:0] mem  [0:MEMW-1];
    logic [DATA_W-1:0] gmem [0:MEMW-1];      // golden: advances at store commit
    logic [DATA_W-1:0] rdata_r;

    assign dmem_rdata_i = rdata_r;

    always @(posedge clk) begin : memory_model
        integer b;
        if (dmem_req_o) begin
            if (dmem_we_o) begin
                for (b = 0; b < NB; b = b + 1)
                    if (dmem_be_o[b])
                        mem[dmem_addr_o[ADDR_W-1:WOFF]][b*8 +: 8] <=
                            dmem_wdata_o[b*8 +: 8];
            end else begin
                rdata_r <= mem[dmem_addr_o[ADDR_W-1:WOFF]];
            end
        end
    end

    // =====================================================================
    //  Program-order op table
    // =====================================================================
    integer op_st   [0:MAXOPS-1];   // 1 = store
    integer op_wa   [0:MAXOPS-1];   // word address
    integer op_be   [0:MAXOPS-1];
    integer op_dat  [0:MAXOPS-1];
    integer op_agd  [0:MAXOPS-1];   // AGU delay, cycles after dispatch
    integer op_sdd  [0:MAXOPS-1];   // STD delay, cycles after dispatch

    integer op_disp [0:MAXOPS-1];   // 1 once accepted by dispatch
    integer op_slot [0:MAXOPS-1];
    integer op_rob  [0:MAXOPS-1];
    integer op_lqt  [0:MAXOPS-1];   // checkpointed tails
    integer op_sqt  [0:MAXOPS-1];
    integer op_agt  [0:MAXOPS-1];   // cycle it becomes AGU-eligible
    integer op_agok [0:MAXOPS-1];
    integer op_sdok [0:MAXOPS-1];
    integer op_wbok [0:MAXOPS-1];   // live writeback exists
    integer op_wbd  [0:MAXOPS-1];
    integer op_wbs  [0:MAXOPS-1];   // reported speculative
    integer op_wbf  [0:MAXOPS-1];   // reported forwarded

    integer n_ops   = 0;
    integer p_disp  = 0;
    integer p_com   = 0;

    integer lqmap [0:LQ_DEPTH-1];
    integer sqmap [0:SQ_DEPTH-1];

    // store drain expectation FIFO
    integer dr_wa [0:MAXOPS-1];
    integer dr_be [0:MAXOPS-1];
    integer dr_dt [0:MAXOPS-1];
    integer dr_wr = 0, dr_rd = 0;

    integer errors  = 0;
    integer n_ld_committed = 0, n_st_committed = 0;
    integer seed = 1;

    // knobs the phases drive
    integer cfg_hold_commit = 0;    // cycles of commit back-pressure left
    integer cfg_flush_on_viol = 0;  // 1 = act as a ROB and flush on violation
    integer cfg_flush_rate  = 0;    // 1-in-N random flush chance per cycle
    integer pend_flush      = -1;   // program index to roll back to
    integer n_flushes_done  = 0;
    integer n_viol_seen     = 0;

    task fail(input string what);
        begin
            errors = errors + 1;
            $display("  [FAIL @%0t cyc %0d] %s", $time, cyc, what);
            if (errors > 25) begin
                $display("RESULT: *** FAIL *** (too many errors)");
                $finish;
            end
        end
    endtask

    function automatic integer masked(input integer val, input integer be);
        integer b, r;
        begin
            r = 0;
            for (b = 0; b < NB; b = b + 1)
                if (be[b]) r = r | (val & (32'hFF << (b*8)));
            masked = r;
        end
    endfunction

    task add_op(input integer is_st, input integer wa, input integer be,
                input integer dat, input integer agd, input integer sdd);
        begin
            op_st [n_ops] = is_st;
            op_wa [n_ops] = wa;
            op_be [n_ops] = be;
            op_dat[n_ops] = dat;
            op_agd[n_ops] = agd;
            op_sdd[n_ops] = sdd;
            op_disp[n_ops] = 0;  op_agok[n_ops] = 0;  op_sdok[n_ops] = 0;
            op_wbok[n_ops] = 0;  op_wbd [n_ops] = 0;  op_wbs [n_ops] = 0;
            op_wbf [n_ops] = 0;  op_slot[n_ops] = 0;  op_agt [n_ops] = 0;
            op_rob[n_ops]  = n_ops % (1 << ROB_W);
            n_ops = n_ops + 1;
        end
    endtask

    // =====================================================================
    //  Checker + driver
    //
    //  Deliberately ONE process.  The checker half samples the cycle that just
    //  ended and advances the program-order pointers; the driver half then
    //  decides what to present for the coming cycle.  Splitting them into two
    //  always blocks would make the result depend on the simulator's ordering
    //  of processes at the same edge - which is exactly how the driver ends up
    //  dispatching op N+1's slot with op N's ROB tag.
    //
    //  DUT inputs are driven with non-blocking assignments so they settle in
    //  the NBA region and are stable for the whole of the next cycle.
    // =====================================================================
    integer i, j, b;
    integer k;
    integer ag_cand [0:LQ_DEPTH+SQ_DEPTH];
    integer n_cand, pick;
    integer do_flush_now;

    // (no block label: Icarus mis-parses a bare task call under `if` inside a
    //  labelled procedural block as a generate construct)
    always @(posedge clk) begin
        if (!rst_n) begin
            disp_valid_i <= 1'b0; disp_is_store_i <= 1'b0; disp_rob_i <= '0;
            ag_valid_i <= 1'b0; ag_is_store_i <= 1'b0; ag_idx_i <= '0;
            ag_addr_i <= '0; ag_be_i <= '0;
            sd_valid_i <= 1'b0; sd_idx_i <= '0; sd_data_i <= '0;
            commit_load_i <= 1'b0; commit_store_i <= 1'b0;
            flush_i <= 1'b0; flush_lq_tail_i <= '0; flush_sq_tail_i <= '0;
            if (dmem_req_o)    fail("memory request asserted during reset");
            if (ld_wb_valid_o) fail("load writeback asserted during reset");
            if (viol_valid_o)  fail("violation asserted during reset");
        end else begin

            // ---- 1. dispatch acceptance --------------------------------
            if (disp_valid_i && !flush_i &&
                (disp_is_store_i ? disp_sq_ready_o : disp_lq_ready_o)) begin
                k = p_disp;
                op_disp[k] = 1;
                op_lqt [k] = disp_lq_tail_o;
                op_sqt [k] = disp_sq_tail_o;
                op_agt [k] = cyc + op_agd[k];
                if (op_st[k]) begin
                    op_slot[k]            = disp_sq_idx_o;
                    sqmap[disp_sq_idx_o]  = k;
                end else begin
                    op_slot[k]            = disp_lq_idx_o;
                    lqmap[disp_lq_idx_o]  = k;
                end
                p_disp = p_disp + 1;
            end

            // ---- 2. AGU / STD acceptance --------------------------------
            if (ag_valid_i && !flush_i) begin
                k = ag_is_store_i ? sqmap[ag_idx_i] : lqmap[ag_idx_i];
                op_agok[k] = 1;
            end
            if (sd_valid_i && !flush_i) begin
                k = sqmap[sd_idx_i];
                op_sdok[k] = 1;
            end

            // ---- 3. load writeback --------------------------------------
            if (ld_wb_valid_o) begin
                k = lqmap[ld_wb_idx_o];
                if (k < p_com || k >= p_disp || op_st[k])
                    fail($sformatf("writeback for op %0d that is not an in-flight load", k));
                else begin
                    if (ld_wb_rob_o !== op_rob[k][ROB_W-1:0])
                        fail($sformatf("op %0d writeback rob %0d, expected %0d",
                                       k, ld_wb_rob_o, op_rob[k]));
                    if (ld_wb_be_o !== op_be[k][NB-1:0])
                        fail($sformatf("op %0d writeback be %b, expected %b",
                                       k, ld_wb_be_o, op_be[k][NB-1:0]));
                    op_wbok[k] = 1;
                    op_wbd [k] = ld_wb_data_o;
                    op_wbs [k] = ld_wb_spec_o;
                    op_wbf [k] = ld_wb_fwd_o;
                end
            end

            // ---- 4. memory-order violation ------------------------------
            //   Applied AFTER the writeback above, matching the RTL, where the
            //   squash overwrites the S1 result for the same entry.
            if (viol_valid_o) begin
                k = lqmap[viol_idx_o];
                n_viol_seen = n_viol_seen + 1;
                if (k < p_com || k >= p_disp || op_st[k])
                    fail($sformatf("violation names op %0d, not an in-flight load", k));
                else begin
                    if (viol_rob_o !== op_rob[k][ROB_W-1:0])
                        fail($sformatf("violation rob %0d, expected %0d for op %0d",
                                       viol_rob_o, op_rob[k], k));
                    if (!op_wbok[k])
                        fail($sformatf("violation on op %0d which had no live result", k));
                    if (!op_wbs[k])
                        fail($sformatf("violation on op %0d which never reported spec", k));
                    // discard the victim and every younger load's result
                    for (j = k; j < p_disp; j = j + 1)
                        if (!op_st[j]) op_wbok[j] = 0;
                    if (cfg_flush_on_viol && pend_flush < 0) pend_flush = k;
                end
            end

            // ---- 5. commit ----------------------------------------------
            if (commit_load_i) begin
                if (!lq_head_ready_o)
                    fail("commit_load with lq_head_ready deasserted");
                k = p_com;
                if (op_st[k]) fail("commit_load but head op is a store");
                if (!op_wbok[k])
                    fail($sformatf("op %0d committed with no live writeback", k));
                else if (masked(op_wbd[k], op_be[k]) !==
                         masked(gmem[op_wa[k]], op_be[k]))
                    fail($sformatf(
                        "op %0d load @w%0d be %b got %08x expected %08x%s",
                        k, op_wa[k], op_be[k][NB-1:0],
                        masked(op_wbd[k], op_be[k]),
                        masked(gmem[op_wa[k]], op_be[k]),
                        op_wbf[k] ? " (forwarded)" : " (from memory)"));
                n_ld_committed = n_ld_committed + 1;
                p_com = p_com + 1;
            end
            if (commit_store_i) begin
                if (!sq_head_ready_o)
                    fail("commit_store with sq_head_ready deasserted");
                k = p_com;
                if (!op_st[k]) fail("commit_store but head op is a load");
                for (b = 0; b < NB; b = b + 1)
                    if (op_be[k][b])
                        gmem[op_wa[k]][b*8 +: 8] = op_dat[k][b*8 +: 8];
                dr_wa[dr_wr] = op_wa[k];
                dr_be[dr_wr] = op_be[k];
                dr_dt[dr_wr] = op_dat[k];
                dr_wr = dr_wr + 1;
                n_st_committed = n_st_committed + 1;
                p_com = p_com + 1;
            end

            // ---- 6. drain order ------------------------------------------
            if (dmem_req_o && dmem_we_o) begin
                if (dr_rd >= dr_wr)
                    fail("memory write with no committed store outstanding");
                else begin
                    if (dmem_addr_o[ADDR_W-1:WOFF] !== dr_wa[dr_rd][WADDR_W-1:0])
                        fail($sformatf("drain %0d address w%0d, expected w%0d",
                                       dr_rd, dmem_addr_o[ADDR_W-1:WOFF], dr_wa[dr_rd]));
                    if (dmem_be_o !== dr_be[dr_rd][NB-1:0])
                        fail($sformatf("drain %0d be %b, expected %b",
                                       dr_rd, dmem_be_o, dr_be[dr_rd][NB-1:0]));
                    if (masked(dmem_wdata_o, dr_be[dr_rd]) !==
                        masked(dr_dt[dr_rd],  dr_be[dr_rd]))
                        fail($sformatf("drain %0d data %08x, expected %08x",
                                       dr_rd, dmem_wdata_o, dr_dt[dr_rd]));
                    dr_rd = dr_rd + 1;
                end
            end

            // ---- 7. watchdog ---------------------------------------------
            if (cyc > MAX_CYCLES) begin
                $display("  [FAIL] watchdog: %0d cycles, %0d/%0d ops committed",
                         cyc, p_com, n_ops);
                $display("   stuck head op %0d: %s w%0d be %b slot %0d",
                         p_com, op_st[p_com] ? "store" : "load ",
                         op_wa[p_com], op_be[p_com][NB-1:0], op_slot[p_com]);
                $display("   disp %0d agok %0d sdok %0d wbok %0d   p_disp %0d",
                         op_disp[p_com], op_agok[p_com], op_sdok[p_com],
                         op_wbok[p_com], p_disp);
                $display("   lq_cnt %0d sq_cnt %0d sq_uncommitted %0d",
                         lq_cnt_o, sq_cnt_o, sq_uncommitted_o);
                if (!op_st[p_com])
                    $display("   lq entry: val %0d aval %0d exec %0d rpend %0d rsn %0d blk %0d",
                             dut.lq_val [op_slot[p_com]], dut.lq_aval[op_slot[p_com]],
                             dut.lq_exec[op_slot[p_com]], dut.lq_rpend[op_slot[p_com]],
                             dut.lq_rrsn[op_slot[p_com]], dut.lq_blk[op_slot[p_com]]);
                $display("   sq_head %0d sq_commit %0d sq_tail %0d lq_head %0d lq_tail %0d",
                         dut.sq_head, dut.sq_commit, dut.sq_tail,
                         dut.lq_head, dut.lq_tail);
                $display("RESULT: *** FAIL ***");
                $finish;
            end

            // ===============================================================
            //  Driver half - decide what to present for the coming cycle
            // ===============================================================
            disp_valid_i   <= 1'b0;
            ag_valid_i     <= 1'b0;
            sd_valid_i     <= 1'b0;
            commit_load_i  <= 1'b0;
            commit_store_i <= 1'b0;
            flush_i        <= 1'b0;

            // ---- flush decision -----------------------------------------
            do_flush_now = 0;
            if (pend_flush >= 0 && pend_flush < p_disp && pend_flush >= p_com)
                do_flush_now = 1;
            else if (pend_flush >= 0)
                pend_flush = -1;                      // no longer meaningful
            if (!do_flush_now && cfg_flush_rate > 0 && (p_disp - p_com) > 2) begin
                if (($urandom % cfg_flush_rate) == 0) begin
                    pend_flush   = p_com + 1 + ($urandom % (p_disp - p_com - 1));
                    do_flush_now = 1;
                end
            end

            if (do_flush_now) begin
                k = pend_flush;
                flush_i         <= 1'b1;
                flush_lq_tail_i <= op_lqt[k][LPTR_W-1:0];
                flush_sq_tail_i <= op_sqt[k][SPTR_W-1:0];
                for (j = k; j < p_disp; j = j + 1) begin
                    op_disp[j] = 0; op_agok[j] = 0; op_sdok[j] = 0;
                    op_wbok[j] = 0;
                end
                p_disp         = k;
                pend_flush     = -1;
                n_flushes_done = n_flushes_done + 1;
            end else begin
                // ---- dispatch --------------------------------------------
                if (p_disp < n_ops)
                    if (op_st[p_disp] ? disp_sq_ready_o : disp_lq_ready_o) begin
                        disp_valid_i    <= 1'b1;
                        disp_is_store_i <= op_st[p_disp][0];
                        disp_rob_i      <= op_rob[p_disp][ROB_W-1:0];
                    end

                // ---- AGU: a random eligible dispatched op ----------------
                n_cand = 0;
                for (j = p_com; j < p_disp; j = j + 1)
                    if (op_disp[j] && !op_agok[j] && cyc >= op_agt[j]) begin
                        ag_cand[n_cand] = j;
                        n_cand = n_cand + 1;
                    end
                if (n_cand > 0) begin
                    pick          = ag_cand[$urandom % n_cand];
                    ag_valid_i    <= 1'b1;
                    ag_is_store_i <= op_st[pick][0];
                    ag_idx_i      <= op_slot[pick][SQ_AW-1:0];
                    ag_addr_i     <= {op_wa[pick][WADDR_W-1:0], {WOFF{1'b0}}};
                    ag_be_i       <= op_be[pick][NB-1:0];
                end

                // ---- STD: a random eligible dispatched store -------------
                n_cand = 0;
                for (j = p_com; j < p_disp; j = j + 1)
                    if (op_disp[j] && op_st[j] && !op_sdok[j] &&
                        cyc >= (op_agt[j] - op_agd[j] + op_sdd[j])) begin
                        ag_cand[n_cand] = j;
                        n_cand = n_cand + 1;
                    end
                if (n_cand > 0) begin
                    pick       = ag_cand[$urandom % n_cand];
                    sd_valid_i <= 1'b1;
                    sd_idx_i   <= op_slot[pick][SQ_AW-1:0];
                    sd_data_i  <= op_dat[pick][DATA_W-1:0];
                end

                // ---- commit ----------------------------------------------
                //  Decided from the testbench's OWN model, which was brought up
                //  to date by the checker half a few lines above.  The DUT's
                //  *_head_ready_o outputs must not be used here: they are a
                //  cycle stale, and after a commit the head has already moved
                //  on, so a back-to-back commit would fire on the readiness of
                //  the store that just retired.  They are asserted instead.
                if (cfg_hold_commit > 0)
                    cfg_hold_commit = cfg_hold_commit - 1;
                else if (p_com < n_ops && p_com < p_disp && op_disp[p_com]) begin
                    if (op_st[p_com]) begin
                        if (op_agok[p_com] && op_sdok[p_com])
                            commit_store_i <= 1'b1;
                    end else begin
                        if (op_wbok[p_com]) commit_load_i <= 1'b1;
                    end
                end
            end
        end
    end
    // ---- end of the single checker+driver process ------------------------

    // =====================================================================
    //  Phase control
    // =====================================================================
    task run_to_drain;
        begin
            while (p_com < n_ops) @(posedge clk);
            // let the store queue empty out
            while (sq_cnt_o != 0 || lq_cnt_o != 0) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    // counter snapshots for per-phase deltas
    integer b_fwd, b_spec, b_part, b_nodata, b_port, b_kill, b_viol;
    integer b_rd, b_wr, b_urg, b_exec;

    task snap;
        begin
            b_fwd = cnt_fwd_o;  b_spec = cnt_spec_o;
            b_part = cnt_rp_partial_o; b_nodata = cnt_rp_nodata_o;
            b_port = cnt_rp_port_o; b_kill = cnt_rp_kill_o;
            b_viol = cnt_viol_o; b_rd = cnt_mem_rd_o; b_wr = cnt_mem_wr_o;
            b_urg = cnt_drain_urgent_o; b_exec = cnt_ld_exec_o;
        end
    endtask

    task expect_eq(input integer got, input integer exp, input string what);
        begin
            if (got !== exp)
                fail($sformatf("%s: got %0d expected %0d", what, got, exp));
        end
    endtask

    task expect_ge(input integer got, input integer lo, input string what);
        begin
            if (got < lo)
                fail($sformatf("%s: got %0d, expected at least %0d", what, got, lo));
        end
    endtask

    // phase_id is dumped to the VCD purely so gen_figures.py can anchor the
    // waveform plot on a named scenario instead of guessing at cycle numbers.
    integer phase_id = 0;

    task banner(input integer n, input string s);
        begin
            phase_id = n;
            $display("--- phase %0d: %s", n, s);
        end
    endtask

    // =====================================================================
    //  Stimulus
    // =====================================================================
    integer ph_base;
    integer r_st, r_wa, r_be, r_dat;
    integer hot;
    integer be_tab [0:6];

    initial begin
        be_tab[0] = 4'b0001; be_tab[1] = 4'b0010; be_tab[2] = 4'b0100;
        be_tab[3] = 4'b1000; be_tab[4] = 4'b0011; be_tab[5] = 4'b1100;
        be_tab[6] = 4'b1111;

        seed = 1;
        void'($value$plusargs("seed=%d", seed));
        i = $urandom(seed);              // deterministic per-seed stream

        $dumpfile("lsq_disambiguation.vcd");
        $dumpvars(0, tb_lsq_disambiguation);

        for (i = 0; i < MEMW; i = i + 1) begin
            mem [i] = 32'hA0000000 | (i * 32'h00010101);
            gmem[i] = mem[i];
        end
        for (i = 0; i < LQ_DEPTH; i = i + 1) lqmap[i] = 0;
        for (i = 0; i < SQ_DEPTH; i = i + 1) sqmap[i] = 0;
        rdata_r = '0;

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        $display("=========================================================");
        $display(" Day 47 - out-of-order load/store queue, seed %0d", seed);
        $display("=========================================================");

        // -----------------------------------------------------------------
        banner(1, "cold loads, no stores in flight");
        snap;
        add_op(0, 16, 4'b1111, 0, 0, 0);
        add_op(0, 17, 4'b0011, 0, 2, 0);
        add_op(0, 18, 4'b1000, 0, 1, 0);
        run_to_drain;
        expect_eq(cnt_fwd_o - b_fwd,  0, "phase1 forwards");
        expect_eq(cnt_spec_o - b_spec, 0, "phase1 speculative loads");
        expect_eq(cnt_mem_rd_o - b_rd, 3, "phase1 memory reads");
        expect_eq(cnt_mem_wr_o - b_wr, 0, "phase1 memory writes");

        // -----------------------------------------------------------------
        banner(2, "full-width store-to-load forward out of the queue");
        snap;
        cfg_hold_commit = 12;               // keep the store resident
        add_op(1, 20, 4'b1111, 32'hDEADBEEF, 0, 0);
        add_op(0, 20, 4'b1111, 0,            2, 0);
        run_to_drain;
        expect_eq(cnt_fwd_o - b_fwd, 1, "phase2 forwards");
        expect_eq(cnt_mem_rd_o - b_rd, 0, "phase2 memory reads (forward needs none)");
        expect_eq(cnt_mem_wr_o - b_wr, 1, "phase2 memory writes (the drain)");
        if (!op_wbf[n_ops-1]) fail("phase2 load did not report ld_wb_fwd");

        // -----------------------------------------------------------------
        banner(3, "youngest overlapping store wins the forward");
        snap;
        cfg_hold_commit = 16;
        add_op(1, 24, 4'b1111, 32'h11111111, 0, 0);
        add_op(1, 24, 4'b1111, 32'h22222222, 0, 0);
        add_op(1, 24, 4'b1111, 32'h33333333, 0, 0);
        add_op(0, 24, 4'b1111, 0,            4, 0);
        run_to_drain;
        expect_eq(cnt_fwd_o - b_fwd, 1, "phase3 forwards");
        if (op_wbd[n_ops-1] !== 32'h33333333)
            fail($sformatf("phase3 forwarded %08x, expected 33333333",
                           op_wbd[n_ops-1]));

        // -----------------------------------------------------------------
        banner(4, "store data late - RSN_NODATA replay, then forward");
        snap;
        cfg_hold_commit = 20;
        add_op(1, 28, 4'b1111, 32'hCAFEF00D, 0, 9);   // address early, data late
        add_op(0, 28, 4'b1111, 0,            1, 0);
        run_to_drain;
        expect_ge(cnt_rp_nodata_o - b_nodata, 1, "phase4 data-not-ready replays");
        expect_eq(cnt_fwd_o - b_fwd, 1, "phase4 forwards (after the replay)");
        if (op_wbd[n_ops-1] !== 32'hCAFEF00D)
            fail($sformatf("phase4 got %08x, expected CAFEF00D", op_wbd[n_ops-1]));

        // -----------------------------------------------------------------
        banner(5, "partial overlap - replay until the store drains");
        snap;
        add_op(1, 32, 4'b0011, 32'h0000BEEF, 0, 0);   // covers 2 of the 4 bytes
        add_op(0, 32, 4'b1111, 0,            1, 0);
        run_to_drain;
        expect_ge(cnt_rp_partial_o - b_part, 1, "phase5 partial-overlap replays");
        expect_eq(cnt_fwd_o - b_fwd, 0, "phase5 forwards (partial must not forward)");
        expect_ge(cnt_mem_rd_o - b_rd, 1, "phase5 memory reads");

        // -----------------------------------------------------------------
        banner(6, "memory-order violation, ROB flushes and re-executes");
        snap;
        cfg_flush_on_viol = 1;
        n_viol_seen = 0;
        cfg_hold_commit = 24;
        add_op(1, 36, 4'b1111, 32'h5A5A5A5A, 11, 0);  // address resolves late
        add_op(0, 36, 4'b1111, 0,             1, 0);  // speculates past it
        run_to_drain;
        cfg_flush_on_viol = 0;
        expect_eq(cnt_viol_o - b_viol, 1, "phase6 violations");
        expect_ge(n_flushes_done, 1, "phase6 ROB flushes");
        expect_ge(cnt_spec_o - b_spec, 1, "phase6 speculative loads");

        // -----------------------------------------------------------------
        banner(7, "same race, no flush - the LSU self-heals");
        snap;
        cfg_hold_commit = 24;
        add_op(1, 40, 4'b1111, 32'hA5A5A5A5, 11, 0);
        add_op(0, 40, 4'b1111, 0,             1, 0);
        run_to_drain;
        expect_eq(cnt_viol_o - b_viol, 1, "phase7 violations");
        if (op_wbd[n_ops-1] !== 32'hA5A5A5A5)
            fail($sformatf("phase7 re-executed load got %08x, expected A5A5A5A5",
                           op_wbd[n_ops-1]));

        // -----------------------------------------------------------------
        banner(8, "unknown store resolves elsewhere - no false violation");
        snap;
        cfg_hold_commit = 24;
        add_op(1, 45, 4'b1111, 32'h0BADF00D, 11, 0);  // different address
        add_op(0, 44, 4'b1111, 0,             1, 0);
        run_to_drain;
        expect_eq(cnt_viol_o - b_viol, 0, "phase8 violations (must be none)");
        expect_ge(cnt_spec_o - b_spec, 1, "phase8 speculative loads");

        // -----------------------------------------------------------------
        banner(9, "store older than the forwarding source cannot violate");
        snap;
        cfg_hold_commit = 30;
        add_op(1, 48, 4'b1111, 32'h11112222, 12, 0);  // OLD store, resolves last
        add_op(1, 48, 4'b1111, 32'h33334444,  0, 0);  // younger, resolves first
        add_op(0, 48, 4'b1111, 0,             3, 0);  // forwards from the younger
        run_to_drain;
        expect_eq(cnt_viol_o - b_viol, 0,
                  "phase9 violations (barrier must hide the older store)");
        expect_eq(cnt_fwd_o - b_fwd, 1, "phase9 forwards");

        // -----------------------------------------------------------------
        banner(10, "full store queue forces an urgent drain past the loads");
        snap;
        // The head store is ready immediately so it can retire, but the other
        // seven are stuck without an address, so the queue stays full and the
        // drain has to pre-empt the load stream instead of waiting for a gap.
        for (j = 0; j < 4; j = j + 1) begin
            add_op(1, 64 + j, 4'b1111, 32'h70000000 + j, 0, 0);
            for (i = 0; i < 14; i = i + 1)
                add_op(0, 200 + 16*j + i, 4'b1111, 0, 0, 0);
        end
        run_to_drain;
        expect_ge(cnt_drain_urgent_o - b_urg, 1, "phase10 urgent drains");
        expect_ge(cnt_rp_port_o - b_port, 1, "phase10 port-conflict replays");
        expect_eq(cnt_mem_wr_o - b_wr, 4, "phase10 memory writes");

        // -----------------------------------------------------------------
        banner(11, "pipeline flush rolls the tails back");
        snap;
        ph_base = n_ops;
        for (i = 0; i < 10; i = i + 1)
            add_op(i[0], 80 + i, 4'b1111, 32'h80000000 + i, 3, 3);
        pend_flush = -1;
        // let a few dispatch, then roll back to the third of them
        while (p_disp < ph_base + 6) @(posedge clk);
        pend_flush = ph_base + 3;
        run_to_drain;
        expect_ge(n_flushes_done, 2, "phase11 flushes performed");
        expect_eq(lq_cnt_o, 0, "phase11 load queue empty at the end");
        expect_eq(sq_cnt_o, 0, "phase11 store queue empty at the end");

        // -----------------------------------------------------------------
        banner(12, "randomized soak, 1200 ops over a hot working set");
        snap;
        cfg_flush_rate    = 0;
        cfg_flush_on_viol = 0;
        for (i = 0; i < 1200; i = i + 1) begin
            r_st  = ($urandom % 100) < 45;
            hot   = ($urandom % 100) < 75;
            r_wa  = hot ? (100 + ($urandom % 6)) : ($urandom % 256);
            r_be  = be_tab[$urandom % 7];
            r_dat = $urandom;
            add_op(r_st, r_wa, r_be, r_dat, $urandom % 7, $urandom % 9);
        end
        run_to_drain;
        expect_ge(cnt_fwd_o - b_fwd, 20, "soak forwards");
        expect_ge(cnt_spec_o - b_spec, 20, "soak speculative loads");
        expect_ge(cnt_viol_o - b_viol, 1, "soak violations");

        // -----------------------------------------------------------------
        banner(13, "soak with random ROB flushes and violation redirects");
        snap;
        cfg_flush_rate    = 40;
        cfg_flush_on_viol = 1;
        for (i = 0; i < 900; i = i + 1) begin
            r_st  = ($urandom % 100) < 50;
            hot   = ($urandom % 100) < 80;
            r_wa  = hot ? (300 + ($urandom % 5)) : ($urandom % 256);
            r_be  = be_tab[$urandom % 7];
            r_dat = $urandom;
            add_op(r_st, r_wa, r_be, r_dat, $urandom % 6, $urandom % 8);
        end
        run_to_drain;
        cfg_flush_rate    = 0;
        cfg_flush_on_viol = 0;
        expect_ge(n_flushes_done, 5, "phase13 flushes");

        // -----------------------------------------------------------------
        banner(14, "final: backdoor memory compare");
        if (dr_rd != dr_wr)
            fail($sformatf("%0d committed stores never reached memory",
                           dr_wr - dr_rd));
        j = 0;
        for (i = 0; i < MEMW; i = i + 1)
            if (mem[i] !== gmem[i]) begin
                if (j < 5)
                    fail($sformatf("memory w%0d = %08x, golden %08x",
                                   i, mem[i], gmem[i]));
                j = j + 1;
            end
        if (j != 0) fail($sformatf("%0d memory words differ from the golden model", j));
        expect_eq(lq_cnt_o, 0, "load queue empty at end of test");
        expect_eq(sq_cnt_o, 0, "store queue empty at end of test");

        $display("---------------------------------------------------------");
        $display(" ops %0d  (loads %0d, stores %0d)   cycles %0d",
                 n_ops, n_ld_committed, n_st_committed, cyc);
        $display(" loads executed %0d   forwarded %0d   speculative %0d",
                 cnt_ld_exec_o, cnt_fwd_o, cnt_spec_o);
        $display(" replays: partial %0d  no-data %0d  port %0d  s1-kill %0d",
                 cnt_rp_partial_o, cnt_rp_nodata_o, cnt_rp_port_o, cnt_rp_kill_o);
        $display(" violations %0d   ROB flushes %0d   urgent drains %0d",
                 cnt_viol_o, n_flushes_done, cnt_drain_urgent_o);
        $display(" memory: %0d reads, %0d writes", cnt_mem_rd_o, cnt_mem_wr_o);
        $display("---------------------------------------------------------");

        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $finish;
    end

endmodule
