// ============================================================================
//  simt_stack.sv  --  SIMT branch-divergence reconvergence stack (IPDOM stack)
// ----------------------------------------------------------------------------
//  The control-flow heart of a SIMT (single-instruction, multiple-thread) GPU
//  core.  A warp of NLANES threads shares one program counter, so when a
//  data-dependent branch sends some lanes one way and the rest the other, the
//  hardware must (a) serialize the two paths and (b) *reconverge* the warp back
//  to full width as soon as control flow re-merges -- otherwise the lanes stay
//  permanently split and SIMT efficiency collapses.
//
//  This is the classic immediate-post-dominator (IPDOM) reconvergence stack
//  used by NVIDIA-style SIMT cores (and modelled in GPGPU-Sim).  Each stack
//  entry is a { pc, rpc, active_mask } token:
//     pc   = next PC this lane-group will fetch
//     rpc  = reconvergence PC = the IPDOM of the branch (compiler-provided);
//            when this group's pc reaches rpc the group is finished and pops
//     mask = which lanes belong to this group
//
//  Divergence protocol (one divergent branch, current group = TOS):
//     t = taken_mask  & TOS.mask     // lanes that take the branch
//     n = ~taken_mask & TOS.mask     // lanes that fall through
//     if (t == TOS.mask)  TOS.pc <- pc_taken        // uniform: all take
//     else if (t == 0)    TOS.pc <- pc_notaken      // uniform: none take
//     else begin                                    // real divergence:
//        TOS.pc <- rpc                              //   TOS becomes the reconv
//                                                   //   entry (keeps full mask)
//        push { pc_notaken, rpc, n }                //   not-taken group
//        push { pc_taken,   rpc, t }                //   taken group runs first
//     end
//  Lane conservation is exact: (t | n) == TOS.mask and (t & n) == 0, so no lane
//  is ever lost or duplicated across a divergence.
//
//  A group advances with SETPC (fetch/execute updates its pc).  When its pc
//  equals its rpc the fetch stage sees `reconverge` and issues POP: the group
//  retires and the entry beneath resumes.  The final POP restores the reconv
//  entry, which carries the *original* full mask -- the warp is whole again.
//
//  Command interface (one command per cycle when cmd_valid):
//     CMD_NOP=0  CMD_DIVERGE=1  CMD_SETPC=2  CMD_POP=3
//  init_valid pushes the base (whole-warp) entry after reset.
//
//  Fully synthesizable, reset-safe, parameterized, lint-friendly.
// ============================================================================
`default_nettype none

module simt_stack #(
    parameter int NLANES = 8,             // threads per warp
    parameter int PCW    = 16,            // program-counter width
    parameter int DEPTH  = 32             // max simultaneously-live groups
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // ---- base-entry load (push the whole-warp entry after reset) ----------
    input  wire                     init_valid,
    input  wire [NLANES-1:0]        init_mask,
    input  wire [PCW-1:0]           init_pc,

    // ---- command port -----------------------------------------------------
    input  wire                     cmd_valid,
    input  wire [1:0]               cmd,
    input  wire [NLANES-1:0]        taken_mask,   // DIVERGE: lanes taking branch
    input  wire [PCW-1:0]           pc_taken,     // DIVERGE: taken-path PC
    input  wire [PCW-1:0]           pc_notaken,   // DIVERGE: fall-through PC
    input  wire [PCW-1:0]           rpc,          // DIVERGE: reconvergence PC (IPDOM)
    input  wire [PCW-1:0]           next_pc,      // SETPC : new PC for TOS group

    // ---- top-of-stack view (combinational: this is what fetch consumes) ----
    output wire                     tos_valid,    // stack non-empty -> warp live
    output wire [PCW-1:0]           tos_pc,       // PC to fetch next
    output wire [PCW-1:0]           tos_rpc,      // its reconvergence PC
    output wire [NLANES-1:0]        tos_mask,     // active-lane mask to execute
    output wire [$clog2(NLANES+1)-1:0] active_lanes, // popcount(tos_mask)
    output wire                     reconverge,   // tos_pc == tos_rpc -> pop me
    output wire [$clog2(DEPTH+1)-1:0]  sp,        // number of live entries
    output wire                     ovf,          // sticky: stack overflow
    output wire                     unf           // sticky: stack underflow
);

    localparam logic [1:0] CMD_NOP     = 2'd0;
    localparam logic [1:0] CMD_DIVERGE = 2'd1;
    localparam logic [1:0] CMD_SETPC   = 2'd2;
    localparam logic [1:0] CMD_POP     = 2'd3;

    // sentinel rpc for the base entry: an "impossible" PC that no group ever
    // reaches, so the base group never spuriously reconverges/pops itself.
    localparam logic [PCW-1:0] RPC_TOP = {PCW{1'b1}};

    localparam int SPW = $clog2(DEPTH+1);

    // ---- stack storage -----------------------------------------------------
    logic [PCW-1:0]    st_pc   [DEPTH];
    logic [PCW-1:0]    st_rpc  [DEPTH];
    logic [NLANES-1:0] st_mask [DEPTH];
    logic [SPW-1:0]    sp_q;
    logic              ovf_q, unf_q;

    // ---- combinational divergence split of the current TOS mask ------------
    wire [NLANES-1:0] tos_mask_c = (sp_q != 0) ? st_mask[sp_q-1] : '0;
    wire [NLANES-1:0] div_t      = taken_mask  & tos_mask_c;   // take branch
    wire [NLANES-1:0] div_n      = ~taken_mask & tos_mask_c;   // fall through

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_q  <= '0;
            ovf_q <= 1'b0;
            unf_q <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                st_pc[i]   <= '0;
                st_rpc[i]  <= '0;
                st_mask[i] <= '0;
            end
        end else if (init_valid) begin
            // push the whole-warp base entry
            if (sp_q < DEPTH[SPW-1:0]) begin
                st_pc[sp_q]   <= init_pc;
                st_rpc[sp_q]  <= RPC_TOP;
                st_mask[sp_q] <= init_mask;
                sp_q          <= sp_q + 1'b1;
            end else begin
                ovf_q <= 1'b1;
            end
        end else if (cmd_valid) begin
            case (cmd)
                // ---- divergent branch on the current (TOS) group ----------
                CMD_DIVERGE: begin
                    if (sp_q == 0) begin
                        unf_q <= 1'b1;
                    end else if (div_t == tos_mask_c) begin
                        // uniform: every active lane takes the branch
                        st_pc[sp_q-1] <= pc_taken;
                    end else if (div_t == '0) begin
                        // uniform: no active lane takes the branch
                        st_pc[sp_q-1] <= pc_notaken;
                    end else begin
                        // genuine divergence: reuse TOS as the reconv entry and
                        // push the not-taken then taken groups (taken on top).
                        if ((sp_q + 2) > DEPTH[SPW-1:0]) begin
                            ovf_q <= 1'b1;
                        end else begin
                            st_pc[sp_q-1]   <= rpc;                 // reconv entry
                            st_pc[sp_q]     <= pc_notaken;          // not-taken
                            st_rpc[sp_q]    <= rpc;
                            st_mask[sp_q]   <= div_n;
                            st_pc[sp_q+1]   <= pc_taken;            // taken (TOS)
                            st_rpc[sp_q+1]  <= rpc;
                            st_mask[sp_q+1] <= div_t;
                            sp_q            <= sp_q + 2'd2;
                        end
                    end
                end
                // ---- advance the current group's PC -----------------------
                CMD_SETPC: begin
                    if (sp_q == 0) unf_q <= 1'b1;
                    else           st_pc[sp_q-1] <= next_pc;
                end
                // ---- retire the current group (reconvergence) -------------
                CMD_POP: begin
                    if (sp_q == 0) unf_q <= 1'b1;
                    else           sp_q  <= sp_q - 1'b1;
                end
                default: /* CMD_NOP */ ;
            endcase
        end
    end

    // ---- top-of-stack view -------------------------------------------------
    assign tos_valid = (sp_q != 0);
    assign tos_pc    = (sp_q != 0) ? st_pc[sp_q-1]   : '0;
    assign tos_rpc   = (sp_q != 0) ? st_rpc[sp_q-1]  : '0;
    assign tos_mask  = (sp_q != 0) ? st_mask[sp_q-1] : '0;
    assign sp        = sp_q;
    assign ovf       = ovf_q;
    assign unf       = unf_q;

    // reconvergence detect: the fetch unit issues CMD_POP when this is high.
    assign reconverge = tos_valid && (tos_pc == tos_rpc);

    // popcount of the active mask -> how many lanes actually execute this cycle
    // (a direct measure of the SIMT divergence penalty).
    localparam int AW = $clog2(NLANES+1);
    integer j;
    logic [AW-1:0] cnt;
    always_comb begin
        cnt = '0;
        for (j = 0; j < NLANES; j = j + 1)
            cnt = cnt + tos_mask[j];
    end
    assign active_lanes = cnt;

`ifdef FORMAL_ASSERT
    // lane conservation on a genuine divergence (documentation-grade assert)
    always @(posedge clk) if (rst_n && cmd_valid && cmd==CMD_DIVERGE && sp_q!=0) begin
        assert ((div_t | div_n) == tos_mask_c);
        assert ((div_t & div_n) == '0);
    end
`endif

endmodule

`default_nettype wire
