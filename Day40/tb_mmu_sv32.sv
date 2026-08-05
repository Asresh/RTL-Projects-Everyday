// ---------------------------------------------------------------------------
// Day 40 : self-checking testbench for mmu_sv32
// ---------------------------------------------------------------------------
// Structure
//   * A physical memory model holds a REAL Sv32 page-table tree (root table +
//     two second-level tables) built by `build_page_tables`. The model answers
//     the DUT's walk port with randomised ready/latency backpressure.
//   * A GOLDEN REFERENCE MODEL (`golden`) translates every virtual address by
//     walking that same page table in plain software - independent of the DUT's
//     TLB, FSM and pipelining. Every DUT response (paddr, fault, cause,
//     superpage flag) is compared against it.
//   * Directed stimulus covers bare mode, M-mode bypass, 4 KiB leaves, 4 MiB
//     megapages, invalid PTEs, the reserved W&&!R encoding, non-leaf-at-last-
//     level, misaligned superpages, U/S separation, SUM, MXR, A/D faults,
//     TLB-hit reuse and SFENCE.VMA invalidation.
//   * Randomised stimulus then fires 600 random {vaddr, access, priv, SUM, MXR}
//     requests to shake out TLB hit/miss/replacement interactions.
//   * A global timeout and a VCD dump are included.
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tb_mmu_sv32;

    parameter  int TLB_ENTRIES = 8;   // override: iverilog -P tb_mmu_sv32.TLB_ENTRIES=16

    // ---------------- encodings (mirrors of the DUT's) --------------------
    localparam logic [1:0] PRIV_U = 2'd0;
    localparam logic [1:0] PRIV_S = 2'd1;
    localparam logic [1:0] PRIV_M = 2'd3;

    localparam logic [1:0] ACC_LOAD  = 2'd0;
    localparam logic [1:0] ACC_STORE = 2'd1;
    localparam logic [1:0] ACC_FETCH = 2'd2;

    // PTE flag bits {D,A,G,U,X,W,R,V} for mk_pte()
    localparam logic [7:0] F_V   = 8'h01;
    localparam logic [7:0] F_R   = 8'h02;
    localparam logic [7:0] F_W   = 8'h04;
    localparam logic [7:0] F_X   = 8'h08;
    localparam logic [7:0] F_U   = 8'h10;
    localparam logic [7:0] F_A   = 8'h40;
    localparam logic [7:0] F_D   = 8'h80;

    // Physical pages used by the page-table tree
    localparam logic [21:0] PPN_ROOT = 22'd1;   // level-1 (root) table
    localparam logic [21:0] PPN_T0   = 22'd2;   // level-0 table for vpn1 = 0
    localparam logic [21:0] PPN_T4   = 22'd3;   // level-0 table for vpn1 = 4

    // ---------------- DUT connections ------------------------------------
    logic        clk = 1'b0;
    logic        rst_n;

    logic        satp_mode;
    logic [21:0] satp_ppn;
    logic [1:0]  priv;
    logic        mstatus_sum, mstatus_mxr;
    logic        sfence_valid;

    logic        req_valid;
    logic [31:0] req_vaddr;
    logic [1:0]  req_access;
    wire         req_ready;

    wire         resp_valid;
    wire [33:0]  resp_paddr;
    wire         resp_fault;
    wire [3:0]   resp_cause;
    wire         resp_super;

    wire         ptw_req_valid;
    wire [33:0]  ptw_req_addr;
    logic        ptw_req_ready;
    logic        ptw_resp_valid;
    logic [31:0] ptw_resp_data;

    wire         perf_tlb_hit, perf_tlb_miss, perf_fault;

    mmu_sv32 #(.TLB_ENTRIES(TLB_ENTRIES)) dut (
        .clk(clk), .rst_n(rst_n),
        .satp_mode(satp_mode), .satp_ppn(satp_ppn), .priv(priv),
        .mstatus_sum(mstatus_sum), .mstatus_mxr(mstatus_mxr),
        .sfence_valid(sfence_valid),
        .req_valid(req_valid), .req_vaddr(req_vaddr),
        .req_access(req_access), .req_ready(req_ready),
        .resp_valid(resp_valid), .resp_paddr(resp_paddr),
        .resp_fault(resp_fault), .resp_cause(resp_cause),
        .resp_super(resp_super),
        .ptw_req_valid(ptw_req_valid), .ptw_req_addr(ptw_req_addr),
        .ptw_req_ready(ptw_req_ready),
        .ptw_resp_valid(ptw_resp_valid), .ptw_resp_data(ptw_resp_data),
        .perf_tlb_hit(perf_tlb_hit), .perf_tlb_miss(perf_tlb_miss),
        .perf_fault(perf_fault)
    );

    always #5 clk = ~clk;

    // ---------------------------------------------------------------------
    // Physical memory model - 16 pages (PPN 0..15) = 16384 words
    // ---------------------------------------------------------------------
    localparam int MEM_WORDS = 16 * 1024;
    logic [31:0] ptmem [0:MEM_WORDS-1];

    function automatic logic [31:0] mk_pte(input logic [21:0] ppn,
                                           input logic [7:0]  flags);
        mk_pte = {ppn, 2'b00, flags};
    endfunction

    // word index of physical address `addr` inside ptmem
    function automatic int widx(input logic [33:0] addr);
        widx = int'(addr[15:2]);
    endfunction

    task automatic build_page_tables;
        integer i;
        begin
            for (i = 0; i < MEM_WORDS; i = i + 1) ptmem[i] = 32'h0;

            // ---- root table (level 1), indexed by vpn1 -------------------
            // vpn1 = 0 : pointer to the level-0 table T0
            ptmem[PPN_ROOT*1024 + 0] = mk_pte(PPN_T0, F_V);

            // vpn1 = 1 : 4 MiB megapage, supervisor RW data (U = 0)
            ptmem[PPN_ROOT*1024 + 1] = mk_pte({12'h200, 10'd0},
                                              F_V|F_R|F_W|F_A|F_D);

            // vpn1 = 2 : megapage with a non-zero ppn0 -> misaligned superpage
            ptmem[PPN_ROOT*1024 + 2] = mk_pte({12'h300, 10'd7},
                                              F_V|F_R|F_W|F_A|F_D|F_U);

            // vpn1 = 3 : invalid PTE (V = 0)
            ptmem[PPN_ROOT*1024 + 3] = mk_pte(22'h3F, 8'h00);

            // vpn1 = 4 : pointer to the level-0 table T4
            ptmem[PPN_ROOT*1024 + 4] = mk_pte(PPN_T4, F_V);

            // vpn1 = 5 : reserved encoding W = 1, R = 0
            ptmem[PPN_ROOT*1024 + 5] = mk_pte(22'h400, F_V|F_W|F_A|F_D|F_U);

            // vpn1 = 6 : megapage that is valid but has A = 0
            ptmem[PPN_ROOT*1024 + 6] = mk_pte({12'h500, 10'd0},
                                              F_V|F_R|F_W|F_U);

            // ---- T0 : 256 user RWX 4 KiB pages --------------------------
            for (i = 0; i < 256; i = i + 1)
                ptmem[PPN_T0*1024 + i] =
                    mk_pte(22'h1000 + i[21:0], F_V|F_R|F_W|F_X|F_U|F_A|F_D);

            // ---- T4 : corner-case 4 KiB leaves --------------------------
            // vpn0 = 0 : a *pointer* at the last level -> page fault
            ptmem[PPN_T4*1024 + 0] = mk_pte(PPN_T0, F_V);
            // vpn0 = 1 : read-only, A set, D clear  -> stores fault
            ptmem[PPN_T4*1024 + 1] = mk_pte(22'h2001, F_V|F_R|F_U|F_A);
            // vpn0 = 2 : execute-only               -> loads need MXR
            ptmem[PPN_T4*1024 + 2] = mk_pte(22'h2002, F_V|F_X|F_U|F_A);
            // vpn0 = 3 : supervisor RW (U = 0)      -> U-mode always faults
            ptmem[PPN_T4*1024 + 3] = mk_pte(22'h2003, F_V|F_R|F_W|F_A|F_D);
            // vpn0 = 4 : user RW, A and D set       -> fully permissive
            ptmem[PPN_T4*1024 + 4] = mk_pte(22'h2004, F_V|F_R|F_W|F_U|F_A|F_D);
        end
    endtask

    // ---- walk-port slave with randomised backpressure -------------------
    logic [33:0] mem_addr_q;
    integer      mem_delay;
    logic        mem_busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ptw_req_ready  <= 1'b0;
            ptw_resp_valid <= 1'b0;
            ptw_resp_data  <= 32'h0;
            mem_busy       <= 1'b0;
            mem_delay      <= 0;
        end else begin
            ptw_resp_valid <= 1'b0;
            // ready wiggles so the DUT's S_REQ handshake is exercised
            ptw_req_ready  <= mem_busy ? 1'b0 : ($urandom_range(0, 3) != 0);

            if (ptw_req_valid && ptw_req_ready && !mem_busy) begin
                mem_addr_q <= ptw_req_addr;
                mem_delay  <= $urandom_range(0, 3);
                mem_busy   <= 1'b1;
                ptw_req_ready <= 1'b0;
            end else if (mem_busy) begin
                if (mem_delay == 0) begin
                    ptw_resp_valid <= 1'b1;
                    ptw_resp_data  <= ptmem[widx(mem_addr_q)];
                    mem_busy       <= 1'b0;
                end else begin
                    mem_delay <= mem_delay - 1;
                end
            end
        end
    end

    // ---------------------------------------------------------------------
    // GOLDEN REFERENCE MODEL - a plain software Sv32 walk
    // ---------------------------------------------------------------------
    function automatic logic g_perm(input logic [31:0] pte,
                                     input logic [1:0]  acc,
                                     input logic [1:0]  pv,
                                     input logic        sum,
                                     input logic        mxr);
        logic r, w, x, u, a, d, ok;
        begin
            r = pte[1]; w = pte[2]; x = pte[3];
            u = pte[4]; a = pte[6]; d = pte[7];
            ok = 1'b1;
            if (!u && (pv == PRIV_U)) ok = 1'b0;
            if (u && (pv == PRIV_S) && ((acc == ACC_FETCH) || !sum)) ok = 1'b0;
            if (ok) begin
                case (acc)
                    ACC_FETCH: ok = x;
                    ACC_STORE: ok = w;
                    default:   ok = r | (mxr & x);
                endcase
            end
            if (!a) ok = 1'b0;
            if ((acc == ACC_STORE) && !d) ok = 1'b0;
            g_perm = ok;
        end
    endfunction

    task automatic golden(input  logic [31:0] va,
                          input  logic [1:0]  acc,
                          input  logic [1:0]  pv,
                          input  logic        sum,
                          input  logic        mxr,
                          output logic [33:0] pa,
                          output logic        flt,
                          output logic [3:0]  cse,
                          output logic        sup);
        logic [21:0] base, ppn;
        logic [31:0] pte;
        logic [9:0]  idx;
        integer      lvl;
        logic        done;
        begin
            pa = '0; flt = 1'b0; sup = 1'b0;
            cse = (acc == ACC_FETCH) ? 4'd12 :
                  (acc == ACC_STORE) ? 4'd15 : 4'd13;

            if (!(satp_mode && (pv != PRIV_M))) begin
                pa  = {2'b00, va};
                cse = 4'd0;
                return;
            end

            base = satp_ppn;
            done = 1'b0;
            for (lvl = 1; (lvl >= 0) && !done; lvl = lvl - 1) begin
                idx = (lvl == 1) ? va[31:22] : va[21:12];
                pte = ptmem[widx({base, idx, 2'b00})];

                if (!pte[0] || (pte[2] && !pte[1])) begin        // !V or W&&!R
                    flt = 1'b1; done = 1'b1;
                end else if (pte[1] || pte[3]) begin             // leaf (R or X)
                    ppn = pte[31:10];
                    if ((lvl == 1) && (pte[19:10] != 10'd0)) begin
                        flt = 1'b1;                              // misaligned
                    end else if (!g_perm(pte, acc, pv, sum, mxr)) begin
                        flt = 1'b1;
                    end else begin
                        sup = (lvl == 1);
                        if (lvl == 1) ppn = {ppn[21:10], va[21:12]};
                        pa  = {ppn, va[11:0]};
                        cse = 4'd0;
                    end
                    done = 1'b1;
                end else if (lvl == 0) begin                     // pointer at L0
                    flt = 1'b1; done = 1'b1;
                end else begin
                    base = pte[31:10];                           // descend
                end
            end
            if (flt) pa = '0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Scoreboard
    // ---------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;
    integer n_hit  = 0;
    integer n_miss = 0;
    integer n_flt  = 0;

    logic [33:0] got_pa;
    logic        got_flt, got_sup;
    logic [3:0]  got_cse;
    logic        was_fast;

    // Issue one translation request and capture the response.
    task automatic do_req(input logic [31:0] va, input logic [1:0] acc);
        begin
            @(negedge clk);
            req_vaddr  = va;
            req_access = acc;
            req_valid  = 1'b1;
            #1;                             // let the combinational paths settle

            // Wait until the MMU accepts (req_ready high at a negedge means the
            // upcoming posedge consumes the request).
            while (!req_ready) begin
                @(negedge clk);
                #1;
            end

            was_fast = resp_valid;          // zero-cycle bare/TLB-hit answer
            if (was_fast) begin
                got_pa  = resp_paddr;
                got_flt = resp_fault;
                got_cse = resp_cause;
                got_sup = resp_super;
            end

            @(negedge clk);                 // let the accepting posedge happen
            req_valid = 1'b0;

            if (!was_fast) begin
                while (!resp_valid) begin
                    @(negedge clk);
                    #1;
                end
                got_pa  = resp_paddr;
                got_flt = resp_fault;
                got_cse = resp_cause;
                got_sup = resp_super;
                @(negedge clk);
            end
        end
    endtask

    // Request + compare against the golden model.
    task automatic check(input logic [31:0] va, input logic [1:0] acc,
                         input string tag);
        logic [33:0] e_pa;
        logic        e_flt, e_sup;
        logic [3:0]  e_cse;
        begin
            golden(va, acc, priv, mstatus_sum, mstatus_mxr,
                   e_pa, e_flt, e_cse, e_sup);
            do_req(va, acc);
            checks = checks + 1;
            if (was_fast) n_hit = n_hit + 1; else n_miss = n_miss + 1;
            if (got_flt) n_flt = n_flt + 1;

            if (got_flt !== e_flt) begin
                errors = errors + 1;
                $display("ERROR [%0s] va=%08h acc=%0d priv=%0d sum=%0b mxr=%0b fast=%0b : fault %0b, expected %0b",
                         tag, va, acc, priv, mstatus_sum, mstatus_mxr,
                         was_fast, got_flt, e_flt);
                if (errors < 4) dump_tlb();
            end else if (e_flt) begin
                if (got_cse !== e_cse) begin
                    errors = errors + 1;
                    $display("ERROR [%0s] va=%08h : cause %0d, expected %0d",
                             tag, va, got_cse, e_cse);
                end
            end else begin
                if (got_pa !== e_pa) begin
                    errors = errors + 1;
                    $display("ERROR [%0s] va=%08h acc=%0d priv=%0d : paddr %09h, expected %09h",
                             tag, va, acc, priv, got_pa, e_pa);
                end
                if (got_sup !== e_sup) begin
                    errors = errors + 1;
                    $display("ERROR [%0s] va=%08h : super %0b, expected %0b",
                             tag, va, got_sup, e_sup);
                end
            end
        end
    endtask

    // Assert that the request just issued was (or was not) answered in zero
    // cycles, i.e. that it really took the bare/TLB-hit path.
    task automatic expect_fast(input logic exp, input string tag);
        begin
            if (was_fast !== exp) begin
                errors = errors + 1;
                $display("ERROR [%0s] : zero-cycle path was %0b, expected %0b",
                         tag, was_fast, exp);
            end
        end
    endtask

    // Is {vpn1, vpn0} currently cached? Read directly from the TLB arrays so
    // that measuring residency does not disturb it.
    function automatic logic page_resident(input logic [9:0] v1,
                                           input logic [9:0] v0);
        integer i;
        begin
            page_resident = 1'b0;
            for (i = 0; i < TLB_ENTRIES; i = i + 1)
                if (dut.tlb_valid[i] && (dut.tlb_vpn1[i] == v1) &&
                    (dut.tlb_super[i] || (dut.tlb_vpn0[i] == v0)))
                    page_resident = 1'b1;
        end
    endfunction

    task automatic dump_tlb;
        integer i;
        begin
            for (i = 0; i < TLB_ENTRIES; i = i + 1)
                $display("      tlb[%0d] v=%0b vpn1=%03h vpn0=%03h sup=%0b ppn=%06h perm(DAUXWR)=%06b",
                         i, dut.tlb_valid[i], dut.tlb_vpn1[i], dut.tlb_vpn0[i],
                         dut.tlb_super[i], dut.tlb_ppn[i], dut.tlb_perm[i]);
        end
    endtask

    task automatic do_sfence;
        begin
            @(negedge clk);
            sfence_valid = 1'b1;
            @(negedge clk);
            sfence_valid = 1'b0;
        end
    endtask

    // ---------------------------------------------------------------------
    // Stimulus
    // ---------------------------------------------------------------------
    logic [31:0] rva;
    logic [1:0]  racc;
    integer      k, sel;
    integer      r0, r1;
    integer      n_evicted, n_resident;

    integer seed, seed_arg, dummy;

    initial begin
        // Randomisation seed is overridable:  vvp mmu_sv32.vvp +seed=1234
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        // Icarus passes the seed as inout (like $random), so reseed from a copy
        // and keep `seed` itself intact for the report.
        seed_arg = seed;
        dummy    = $urandom(seed_arg);

        $dumpfile("mmu_sv32.vcd");
        $dumpvars(0, tb_mmu_sv32);

        build_page_tables();

        rst_n        = 1'b0;
        satp_mode    = 1'b0;
        satp_ppn     = PPN_ROOT;
        priv         = PRIV_U;
        mstatus_sum  = 1'b0;
        mstatus_mxr  = 1'b0;
        sfence_valid = 1'b0;
        req_valid    = 1'b0;
        req_vaddr    = 32'h0;
        req_access   = ACC_LOAD;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // ---------------- 1. bare mode: identity map ---------------------
        satp_mode = 1'b0;
        check(32'hDEAD_B123, ACC_LOAD,  "bare-load");
        expect_fast(1'b1, "bare-load");      // bare mode never walks
        check(32'h0000_1000, ACC_STORE, "bare-store");
        check(32'hFFFF_FFFC, ACC_FETCH, "bare-fetch");

        // ---------------- 2. M-mode bypasses translation -----------------
        satp_mode = 1'b1;
        priv      = PRIV_M;
        check(32'h0040_0AA0, ACC_LOAD, "mmode-bypass");

        // ---------------- 3. 4 KiB user leaves (miss then hit) -----------
        priv = PRIV_U;
        do_sfence();                                    // start from a cold TLB
        check(32'h0000_5678, ACC_LOAD,  "4k-miss");
        expect_fast(1'b0, "4k-miss");                   // cold -> must walk
        check(32'h0000_5AAA, ACC_LOAD,  "4k-hit");      // same page -> TLB hit
        expect_fast(1'b1, "4k-hit");                    // warm -> zero cycles
        check(32'h0000_5010, ACC_STORE, "4k-hit-st");
        expect_fast(1'b1, "4k-hit-st");
        check(32'h0000_5020, ACC_FETCH, "4k-hit-if");
        expect_fast(1'b1, "4k-hit-if");
        check(32'h0002_3456, ACC_LOAD,  "4k-other");
        check(32'h000F_F004, ACC_STORE, "4k-high-vpn0");

        // ---------------- 4. 4 MiB megapage (supervisor) -----------------
        priv = PRIV_S;
        check(32'h0040_0000, ACC_LOAD,  "mega-base");
        check(32'h007F_FFF8, ACC_STORE, "mega-top");
        check(32'h0055_5444, ACC_LOAD,  "mega-mid-hit");
        expect_fast(1'b1, "mega-mid-hit");   // one megapage entry covers 4 MiB

        // ---------------- 5. fault taxonomy ------------------------------
        priv = PRIV_U;
        check(32'h0080_0100, ACC_LOAD,  "misaligned-super");
        check(32'h00C0_0200, ACC_LOAD,  "invalid-pte");
        check(32'h0140_0300, ACC_LOAD,  "reserved-w-not-r");
        check(32'h0180_0400, ACC_LOAD,  "A-bit-clear");
        check(32'h0100_0000, ACC_FETCH, "pointer-at-L0");

        // ---------------- 6. per-access permission corners ---------------
        check(32'h0100_1000, ACC_LOAD,  "ro-load-ok");
        check(32'h0100_1004, ACC_STORE, "ro-store-fault");   // D = 0
        check(32'h0100_2000, ACC_FETCH, "xo-fetch-ok");
        check(32'h0100_2004, ACC_LOAD,  "xo-load-noMXR");    // fault
        mstatus_mxr = 1'b1;
        do_sfence();                                          // re-walk cleanly
        check(32'h0100_2008, ACC_LOAD,  "xo-load-MXR");      // now allowed
        mstatus_mxr = 1'b0;

        // ---------------- 7. U/S separation and SUM ----------------------
        priv = PRIV_U;
        check(32'h0100_3000, ACC_LOAD,  "u-on-spage");        // U=0 page, fault
        priv = PRIV_S;
        check(32'h0100_4000, ACC_LOAD,  "s-on-upage-noSUM");  // fault
        mstatus_sum = 1'b1;
        check(32'h0100_4004, ACC_LOAD,  "s-on-upage-SUM");    // allowed
        check(32'h0100_4008, ACC_FETCH, "s-fetch-upage");     // always faults
        mstatus_sum = 1'b0;

        // ---------------- 8. SFENCE.VMA invalidates the TLB --------------
        priv = PRIV_U;
        check(32'h0000_9000, ACC_LOAD, "pre-sfence");         // fills the TLB
        // Remap vpn1=0 / vpn0=9 to a different PPN, then fence.
        ptmem[PPN_T0*1024 + 9] = mk_pte(22'h3ABC, F_V|F_R|F_W|F_X|F_U|F_A|F_D);
        do_sfence();
        check(32'h0000_9000, ACC_LOAD, "post-sfence");        // must see 0x3ABC
        expect_fast(1'b0, "post-sfence");    // fence must have forced a re-walk
        // Put it back and fence again.
        ptmem[PPN_T0*1024 + 9] = mk_pte(22'h1009, F_V|F_R|F_W|F_X|F_U|F_A|F_D);
        do_sfence();
        check(32'h0000_9000, ACC_LOAD, "restored");

        // ---------------- 9. TLB capacity / replacement ------------------
        // From a COLD TLB, touch TLB_ENTRIES distinct pages: invalid-first
        // victim selection fills slots 0..N-1 and leaves rr_ptr back at 0.
        do_sfence();
        for (k = 0; k < TLB_ENTRIES; k = k + 1) begin
            check(32'h0000_0000 | (k << 12), ACC_LOAD, "cap-fill");
            expect_fast(1'b0, "cap-fill");          // cold: every one walks
        end
        // All N are now resident, so re-touching any of them must be free.
        for (k = 0; k < TLB_ENTRIES; k = k + 1) begin
            check(32'h0000_0004 | (k << 12), ACC_LOAD, "cap-warm");
            expect_fast(1'b1, "cap-warm");
        end
        // One more distinct page overflows the TLB. Which slot the round-robin
        // pointer picks depends on history, so assert the policy-agnostic
        // invariant instead: the new page displaced EXACTLY ONE of the N
        // resident pages (no more - it must not thrash - and no fewer - it must
        // not silently exceed its capacity).
        check(32'h0000_0000 | (TLB_ENTRIES << 12), ACC_LOAD, "cap-overflow");
        expect_fast(1'b0, "cap-overflow");
        // Residency is read straight out of the TLB rather than probed: probing
        // would itself miss and evict, perturbing what we are measuring.
        n_resident = 0;
        for (k = 0; k < TLB_ENTRIES; k = k + 1)
            if (page_resident(10'd0, k[9:0])) n_resident = n_resident + 1;
        n_evicted = TLB_ENTRIES - n_resident;
        if (n_evicted != 1) begin
            errors = errors + 1;
            $display("ERROR [cap-evict] %0d of %0d resident pages were displaced, expected exactly 1",
                     n_evicted, TLB_ENTRIES);
            dump_tlb();
        end
        if (!page_resident(10'd0, TLB_ENTRIES[9:0])) begin
            errors = errors + 1;
            $display("ERROR [cap-evict] the newly walked page was not installed");
        end

        // ---------------- 10. randomised stimulus ------------------------
        for (k = 0; k < 600; k = k + 1) begin
            sel = $urandom_range(0, 9);
            r0  = $urandom_range(0, 255);
            r1  = $urandom_range(0, 4095);
            case (sel)
                0, 1:       rva = ((r0 % 6) << 12) | r1;   // hot set -> TLB hits
                2, 3:       rva = (r0 << 12) | r1;                    // T0 pages
                4, 5:       rva = 32'h0040_0000 | $urandom_range(0, 22'h3F_FFFF);
                6:          rva = 32'h0100_0000
                                  | ($urandom_range(0, 5) << 12) | r1; // T4 corners
                7:          rva = ($urandom_range(2, 6) << 22)
                                  | $urandom_range(0, 22'h3F_FFFF);   // fault vpn1s
                default:    rva = $urandom;                            // anything
            endcase

            racc        = $urandom_range(0, 2);
            priv        = ($urandom_range(0, 1) != 0) ? PRIV_U : PRIV_S;
            mstatus_sum = $urandom_range(0, 1);
            mstatus_mxr = $urandom_range(0, 1);

            check(rva, racc, "random");

            // Occasionally fence to mix cold and warm TLB behaviour.
            if ($urandom_range(0, 40) == 0) do_sfence();
        end

        // ---------------- report ----------------------------------------
        @(posedge clk);
        $display("");
        $display("--------------------------------------------------------");
        $display(" mmu_sv32 : %0d translations checked (seed=%0d)", checks, seed);
        $display("   zero-cycle answers (bare / TLB hit) : %0d", n_hit);
        $display("   walked (TLB miss)                   : %0d", n_miss);
        $display("   page faults observed                : %0d", n_flt);
        $display("   mismatches vs golden model          : %0d", errors);
        $display("--------------------------------------------------------");
        if (errors == 0) $display("RESULT: *** PASS ***");
        else             $display("RESULT: *** FAIL *** (%0d errors)", errors);
        $display("");
        $finish;
    end

    // ---------------- global timeout --------------------------------------
    initial begin
        #4_000_000;
        $display("RESULT: *** FAIL *** (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
