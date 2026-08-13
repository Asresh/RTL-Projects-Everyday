// ---------------------------------------------------------------------------
// Day 40 : RISC-V Sv32 MMU - fully-associative TLB + hardware page-table walker
// ---------------------------------------------------------------------------
// Translates a 32-bit virtual address to a 34-bit physical address exactly as
// the RISC-V privileged spec (Sv32) requires:
//
//   * bare mode / M-mode  -> identity map, zero-cycle, never faults
//   * TLB hit             -> zero-cycle translation + permission check
//   * TLB miss            -> hardware 2-level page-table walk over a memory
//                            port, then the leaf PTE is installed in the TLB
//
// Sv32 address / PTE layout
//   VA  [31:22] vpn1   [21:12] vpn0   [11:0] page offset
//   PA  [33:12] ppn                   [11:0] page offset
//   PTE [31:20] ppn1  [19:10] ppn0  [9:8] RSW  [7] D [6] A [5] G [4] U
//       [3] X  [2] W  [1] R  [0] V
//
// Supported leaf sizes
//   level 0 leaf -> 4 KiB page
//   level 1 leaf -> 4 MiB megapage (superpage); ppn0 must be zero, otherwise a
//                   "misaligned superpage" page fault is raised
//
// A/D policy
//   This MMU never writes a PTE. A page whose A bit is clear (or whose D bit is
//   clear on a store) raises a page fault so that software sets the bits in the
//   trap handler. This is the spec-permitted software-managed option and keeps
//   the walker read-only.
//
// The design is fully synchronous, active-low-reset safe, and has no latches.
// ---------------------------------------------------------------------------

`default_nettype none

module mmu_sv32 #(
    // Number of fully-associative TLB entries (>= 2, power of two not required)
    parameter int TLB_ENTRIES = 8
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---------------- CSR / mode configuration ----------------------------
    input  wire                   satp_mode,    // 1 = Sv32 paging on, 0 = bare
    input  wire [21:0]            satp_ppn,     // root page-table PPN
    input  wire [1:0]             priv,         // PRIV_U / PRIV_S / PRIV_M
    input  wire                   mstatus_sum,  // permit S-mode access to U pages
    input  wire                   mstatus_mxr,  // make eXecutable Readable
    input  wire                   sfence_valid, // 1-cycle pulse: flush whole TLB

    // ---------------- CPU translation request -----------------------------
    input  wire                   req_valid,
    input  wire [31:0]            req_vaddr,
    input  wire [1:0]             req_access,   // ACC_LOAD / ACC_STORE / ACC_FETCH
    output wire                   req_ready,    // MMU can accept a request

    // ---------------- CPU translation response ----------------------------
    output wire                   resp_valid,
    output wire [33:0]            resp_paddr,
    output wire                   resp_fault,
    output wire [3:0]             resp_cause,   // 12 / 13 / 15, 0 when no fault
    output wire                   resp_super,   // leaf was a 4 MiB megapage

    // ---------------- Page-table-walk memory port -------------------------
    output wire                   ptw_req_valid,
    output wire [33:0]            ptw_req_addr, // always 4-byte aligned
    input  wire                   ptw_req_ready,
    input  wire                   ptw_resp_valid,
    input  wire [31:0]            ptw_resp_data,

    // ---------------- Performance counters (1-cycle pulses) ---------------
    output wire                   perf_tlb_hit,
    output wire                   perf_tlb_miss,
    output wire                   perf_fault
);

    // ---------------------------------------------------------------------
    // Encodings
    // ---------------------------------------------------------------------
    localparam logic [1:0] PRIV_U = 2'd0;
    localparam logic [1:0] PRIV_S = 2'd1;
    localparam logic [1:0] PRIV_M = 2'd3;

    localparam logic [1:0] ACC_LOAD  = 2'd0;
    localparam logic [1:0] ACC_STORE = 2'd1;
    localparam logic [1:0] ACC_FETCH = 2'd2;

    localparam logic [3:0] CAUSE_FETCH_PF = 4'd12;
    localparam logic [3:0] CAUSE_LOAD_PF  = 4'd13;
    localparam logic [3:0] CAUSE_STORE_PF = 4'd15;

    // PTE bit positions
    localparam int PTE_V = 0, PTE_R = 1, PTE_W = 2, PTE_X = 3;
    localparam int PTE_U = 4, PTE_A = 6, PTE_D = 7;

    // Walker FSM
    localparam logic [1:0] S_IDLE = 2'd0;  // lookup / accept a request
    localparam logic [1:0] S_REQ  = 2'd1;  // drive a PTE read
    localparam logic [1:0] S_WAIT = 2'd2;  // await the PTE, decode it
    localparam logic [1:0] S_RESP = 2'd3;  // one-cycle response to the CPU

    // Permission vector packing: {D, A, U, X, W, R}
    localparam int P_R = 0, P_W = 1, P_X = 2, P_U = 3, P_A = 4, P_D = 5;

    // ---------------------------------------------------------------------
    // Permission check - shared by the TLB-hit path and the walker leaf path.
    // Every input it depends on is an explicit argument: the function is pure,
    // so a continuous assign that calls it is correctly sensitive to all of
    // them (reading priv/sum/mxr out of module scope instead would hide that
    // dependency from the assign's sensitivity list).
    // ---------------------------------------------------------------------
    function automatic logic perm_ok(input logic [5:0] p,
                                     input logic [1:0] acc,
                                     input logic [1:0] pv,
                                     input logic       sum,
                                     input logic       mxr);
        logic ok;
        begin
            // U/S separation
            if (!p[P_U] && (pv == PRIV_U)) begin
                ok = 1'b0;
            end else if (p[P_U] && (pv == PRIV_S) &&
                         ((acc == ACC_FETCH) || !sum)) begin
                // S-mode may never fetch from a U page; data access needs SUM
                ok = 1'b0;
            end else begin
                case (acc)
                    ACC_FETCH: ok = p[P_X];
                    ACC_STORE: ok = p[P_W];
                    default:   ok = p[P_R] | (mxr & p[P_X]);   // ACC_LOAD
                endcase
            end
            // Accessed / Dirty must already be set (software-managed policy)
            if (!p[P_A])                              ok = 1'b0;
            if ((acc == ACC_STORE) && !p[P_D])         ok = 1'b0;
            perm_ok = ok;
        end
    endfunction

    function automatic logic [3:0] cause_of(input logic [1:0] acc);
        case (acc)
            ACC_FETCH: cause_of = CAUSE_FETCH_PF;
            ACC_STORE: cause_of = CAUSE_STORE_PF;
            default:   cause_of = CAUSE_LOAD_PF;
        endcase
    endfunction

    // ---------------------------------------------------------------------
    // TLB storage (fully associative, round-robin victim, invalid-first)
    // ---------------------------------------------------------------------
    logic [TLB_ENTRIES-1:0] tlb_valid;
    logic [9:0]             tlb_vpn1 [0:TLB_ENTRIES-1];
    logic [9:0]             tlb_vpn0 [0:TLB_ENTRIES-1];
    logic                   tlb_super[0:TLB_ENTRIES-1];
    logic [21:0]            tlb_ppn  [0:TLB_ENTRIES-1];
    logic [5:0]             tlb_perm [0:TLB_ENTRIES-1];

    localparam int IDXW = (TLB_ENTRIES > 1) ? $clog2(TLB_ENTRIES) : 1;
    logic [IDXW-1:0] rr_ptr;

    // ---------------------------------------------------------------------
    // Request-side decode
    // ---------------------------------------------------------------------
    logic [1:0]  state, state_n;
    logic [9:0]  vpn1, vpn0;
    logic [11:0] voff;

    assign vpn1 = req_vaddr[31:22];
    assign vpn0 = req_vaddr[21:12];
    assign voff = req_vaddr[11:0];

    // Paging is active only outside M-mode and only when satp selects Sv32.
    wire xlate_en = satp_mode && (priv != PRIV_M);

    // ---- associative lookup ---------------------------------------------
    logic            tlb_hit;
    logic [31:0]     hit_i;
    wire  [IDXW-1:0] tlb_hit_idx = hit_i[IDXW-1:0];

    always_comb begin
        integer i;
        tlb_hit = 1'b0;
        hit_i   = 32'd0;
        for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
            if (tlb_valid[i] && (tlb_vpn1[i] == vpn1) &&
                (tlb_super[i] || (tlb_vpn0[i] == vpn0))) begin
                tlb_hit = 1'b1;
                hit_i   = i;
            end
        end
    end

    // ---- victim selection: first invalid entry, else round-robin --------
    logic [31:0]     vic_i;
    logic            vic_found;
    wire  [IDXW-1:0] victim = vic_found ? vic_i[IDXW-1:0] : rr_ptr;

    always_comb begin
        integer i;
        vic_i     = 32'd0;
        vic_found = 1'b0;
        // scan downwards so the lowest invalid index wins
        for (i = TLB_ENTRIES - 1; i >= 0; i = i - 1) begin
            if (!tlb_valid[i]) begin
                vic_i     = i;
                vic_found = 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Zero-cycle (fast) path: bare mode or TLB hit
    // ---------------------------------------------------------------------
    logic [5:0]  hit_perm;
    logic [21:0] hit_ppn;
    logic        hit_super;

    assign hit_perm  = tlb_perm [tlb_hit_idx];
    assign hit_ppn   = tlb_ppn  [tlb_hit_idx];
    assign hit_super = tlb_super[tlb_hit_idx];

    wire idle_req  = req_valid && (state == S_IDLE);
    wire fast_resp = idle_req && (!xlate_en || tlb_hit);
    wire start_ptw = idle_req &&   xlate_en && !tlb_hit;

    // A megapage splices vpn0 into the physical address.
    wire [21:0] hit_ppn_final = hit_super ? {hit_ppn[21:10], vpn0} : hit_ppn;

    wire        fast_fault = xlate_en && tlb_hit && !perm_ok(hit_perm, req_access, priv, mstatus_sum, mstatus_mxr);
    wire [33:0] fast_paddr = xlate_en ? {hit_ppn_final, voff} : {2'b00, req_vaddr};

    // ---------------------------------------------------------------------
    // Page-table walker
    // ---------------------------------------------------------------------
    logic [21:0] walk_base;   // PPN of the page table currently being indexed
    logic        walk_level;  // 1 = level-1 table, 0 = level-0 table
    logic [9:0]  cur_vpn1, cur_vpn0;
    logic [11:0] cur_voff;
    logic [1:0]  cur_access;

    logic        rsp_v, rsp_fault, rsp_super;
    logic [33:0] rsp_paddr;
    logic [3:0]  rsp_cause;

    wire [9:0] walk_index = walk_level ? cur_vpn1 : cur_vpn0;

    assign ptw_req_valid = (state == S_REQ);
    assign ptw_req_addr  = {walk_base, walk_index, 2'b00};

    // ---- PTE field extraction -------------------------------------------
    wire        pte_v = ptw_resp_data[PTE_V];
    wire        pte_r = ptw_resp_data[PTE_R];
    wire        pte_w = ptw_resp_data[PTE_W];
    wire        pte_x = ptw_resp_data[PTE_X];
    wire [21:0] pte_ppn  = ptw_resp_data[31:10];
    wire [9:0]  pte_ppn0 = ptw_resp_data[19:10];
    wire [5:0]  pte_perm = {ptw_resp_data[PTE_D], ptw_resp_data[PTE_A],
                            ptw_resp_data[PTE_U], pte_x, pte_w, pte_r};

    wire pte_bad  = !pte_v || (pte_w && !pte_r);   // invalid, or reserved W&&!R
    wire pte_leaf = pte_r || pte_x;
    wire pte_mis  = walk_level && (pte_ppn0 != 10'd0); // misaligned superpage
    wire leaf_ok  = !pte_mis && perm_ok(pte_perm, cur_access, priv, mstatus_sum, mstatus_mxr);

    // Physical address formed from the leaf PTE
    wire [21:0] leaf_ppn = walk_level ? {pte_ppn[21:10], cur_vpn0} : pte_ppn;

    // A leaf that is taken (installed + returned)
    wire pte_take  = ptw_resp_valid && !pte_bad && pte_leaf && leaf_ok;
    // Any condition that terminates the walk with a page fault
    wire pte_fault = ptw_resp_valid &&
                     (pte_bad ||
                      (pte_leaf && !leaf_ok) ||
                      (!pte_leaf && !walk_level));   // non-leaf at the last level

    // ---------------------------------------------------------------------
    // FSM next state
    // ---------------------------------------------------------------------
    always_comb begin
        state_n = state;
        case (state)
            S_IDLE: if (start_ptw)                     state_n = S_REQ;
            S_REQ : if (ptw_req_ready)                 state_n = S_WAIT;
            S_WAIT: if (ptw_resp_valid) begin
                        if (pte_take || pte_fault)     state_n = S_RESP;
                        else                           state_n = S_REQ; // descend
                    end
            default:                                   state_n = S_IDLE; // S_RESP
        endcase
    end

    // ---------------------------------------------------------------------
    // Sequential state
    // ---------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        integer i;
        if (!rst_n) begin
            state      <= S_IDLE;
            tlb_valid  <= '0;
            rr_ptr     <= '0;
            walk_base  <= '0;
            walk_level <= 1'b0;
            cur_vpn1   <= '0;
            cur_vpn0   <= '0;
            cur_voff   <= '0;
            cur_access <= ACC_LOAD;
            rsp_v      <= 1'b0;
            rsp_fault  <= 1'b0;
            rsp_super  <= 1'b0;
            rsp_paddr  <= '0;
            rsp_cause  <= '0;
            for (i = 0; i < TLB_ENTRIES; i = i + 1) begin
                tlb_vpn1[i]  <= '0;
                tlb_vpn0[i]  <= '0;
                tlb_super[i] <= 1'b0;
                tlb_ppn[i]   <= '0;
                tlb_perm[i]  <= '0;
            end
        end else begin
            state <= state_n;
            rsp_v <= 1'b0;

            // SFENCE.VMA - invalidate the whole TLB. Only the valid bits are
            // cleared; the payload is left alone (it cannot be observed).
            if (sfence_valid) tlb_valid <= '0;

            case (state)
                // ---------------------------------------------------------
                S_IDLE: if (start_ptw) begin
                    walk_base  <= satp_ppn;
                    walk_level <= 1'b1;      // start at the root table
                    cur_vpn1   <= vpn1;
                    cur_vpn0   <= vpn0;
                    cur_voff   <= voff;
                    cur_access <= req_access;
                end

                // ---------------------------------------------------------
                S_WAIT: if (ptw_resp_valid) begin
                    if (pte_take) begin
                        // Install the leaf in the TLB and answer the CPU.
                        rsp_v     <= 1'b1;
                        rsp_fault <= 1'b0;
                        rsp_cause <= 4'd0;
                        rsp_super <= walk_level;
                        rsp_paddr <= {leaf_ppn, cur_voff};

                        if (!sfence_valid) begin
                            tlb_valid[victim] <= 1'b1;
                            tlb_vpn1 [victim] <= cur_vpn1;
                            tlb_vpn0 [victim] <= cur_vpn0;
                            tlb_super[victim] <= walk_level;
                            tlb_ppn  [victim] <= pte_ppn;
                            tlb_perm [victim] <= pte_perm;
                            rr_ptr <= (rr_ptr == TLB_ENTRIES[IDXW-1:0] - 1'b1)
                                      ? '0 : rr_ptr + 1'b1;
                        end
                    end else if (pte_fault) begin
                        rsp_v     <= 1'b1;
                        rsp_fault <= 1'b1;
                        rsp_cause <= cause_of(cur_access);
                        rsp_super <= 1'b0;
                        rsp_paddr <= '0;
                    end else begin
                        // Valid non-leaf PTE: descend one level.
                        walk_base  <= pte_ppn;
                        walk_level <= 1'b0;
                    end
                end

                default: ; // S_REQ / S_RESP need no bookkeeping
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // Outputs
    // ---------------------------------------------------------------------
    assign req_ready  = (state == S_IDLE);

    assign resp_valid = fast_resp | rsp_v;
    assign resp_paddr = rsp_v ? rsp_paddr : fast_paddr;
    assign resp_fault = rsp_v ? rsp_fault : fast_fault;
    assign resp_cause = rsp_v ? rsp_cause
                              : (fast_fault ? cause_of(req_access) : 4'd0);
    assign resp_super = rsp_v ? rsp_super
                              : (fast_resp && xlate_en && hit_super);

    assign perf_tlb_hit  = idle_req && xlate_en &&  tlb_hit;
    assign perf_tlb_miss = start_ptw;
    assign perf_fault    = resp_valid && resp_fault;

`ifdef FORMAL_ASSERTS
    // The response bus must never be driven from both paths at once.
    always @(posedge clk) if (rst_n) assert (!(fast_resp && rsp_v));
`endif

endmodule

`default_nettype wire
