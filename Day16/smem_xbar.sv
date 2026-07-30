// ===========================================================================
// smem_xbar.sv  --  SIMT shared-memory bank-conflict resolution crossbar
// ---------------------------------------------------------------------------
// This is the hardware that sits behind the single most-taught GPU performance
// concept: *shared-memory bank conflicts*.  On an NVIDIA SM the on-chip shared
// memory (a.k.a. CUDA __shared__ / the LDS) is sliced into B equally-sized
// banks, word-interleaved, so consecutive 32-bit words live in consecutive
// banks.  A warp of L lanes issues L addresses in one instruction and the
// load/store unit must satisfy them through the bank crossbar:
//
//   * If the L active lanes touch L *different* banks   -> 1 memory phase
//     (full bandwidth, "conflict-free").
//   * If K lanes touch the *same* bank at *different*   -> K memory phases
//     addresses, that access is a K-way bank conflict     (serialized).
//   * If several lanes touch the same bank at the SAME   -> 1 phase for the
//     address, the read is BROADCAST to all of them        whole group (this
//     is the hardware "broadcast" optimisation).
//
// This unit models a read gather (a warp-wide load).  Each cycle of the SERVE
// state it picks, per bank, the lowest-indexed still-pending lane as that
// bank's "leader", reads that one address, and satisfies the leader plus every
// other pending lane that wants the identical address (broadcast).  Lanes that
// want a different address in a busy bank wait for a later phase.  Because
// every occupied bank retires at least its leader each phase, `pending`
// strictly shrinks and the gather finishes in
//        phases = max over banks ( #distinct addresses requested to that bank )
// cycles -- exactly the conflict degree the CUDA C Programming Guide defines.
//
// The bank array is modelled as an async-read scratchpad (like a GPU register
// file / small LDS) so one conflict phase == one clock; a synchronous-read
// variant would simply add a fixed read-latency pipeline stage per phase.
//
// Ports use flat packed lane buses (lane 0 = LSBs) for maximum simulator
// portability; internally they are unpacked for readability.
// ===========================================================================
`timescale 1ns/1ps

module smem_xbar #(
    parameter int LANES      = 8,   // warp width (active lanes per request)
    parameter int BANKS      = 8,   // number of shared-memory banks (power of two)
    parameter int BANK_DEPTH = 32,  // words per bank (power of two)
    parameter int DATA_W     = 16,  // word width in bits
    // ---- derived; do NOT override ----------------------------------------
    parameter int ADDR_W     = $clog2(BANKS * BANK_DEPTH), // flat word address
    parameter int PHW        = $clog2(LANES + 1)           // phase-count width
) (
    input  logic                     clk,
    input  logic                     rst_n,

    // ---- scalar write / init port (one word per clock) --------------------
    input  logic                     we,
    input  logic [ADDR_W-1:0]        waddr,
    input  logic [DATA_W-1:0]        wdata,

    // ---- warp read request ------------------------------------------------
    input  logic                     req_valid,   // launch a warp gather
    input  logic [LANES-1:0]         req_mask,    // 1 = lane active this warp
    input  logic [LANES*ADDR_W-1:0]  req_addr,    // packed per-lane word address

    // ---- status / result --------------------------------------------------
    output logic                     busy,        // gather in progress
    output logic                     resp_valid,  // one-cycle result strobe
    output logic [LANES-1:0]         resp_mask,   // lanes that were served
    output logic [LANES*DATA_W-1:0]  resp_data,   // packed per-lane gathered word
    output logic [PHW-1:0]           resp_phases  // memory phases used (= conflict degree)
);

    // ---- address field extraction -----------------------------------------
    localparam int BSEL = $clog2(BANKS);       // low bits select the bank
    localparam int ROWW = ADDR_W - BSEL;       // remaining bits select the row

    function automatic logic [BSEL-1:0] bank_of(input logic [ADDR_W-1:0] a);
        bank_of = a[BSEL-1:0];
    endfunction
    function automatic logic [ROWW-1:0] row_of(input logic [ADDR_W-1:0] a);
        row_of = a[ADDR_W-1:BSEL];
    endfunction

    // ---- banked scratchpad memory (async read, sync write) -----------------
    logic [DATA_W-1:0] mem [0:BANKS-1][0:BANK_DEPTH-1];

    always_ff @(posedge clk) begin
        if (we)
            mem[bank_of(waddr)][row_of(waddr)] <= wdata;
    end

    // ---- request-tracking registers ----------------------------------------
    typedef enum logic [1:0] {IDLE, SERVE, DONE} state_e;
    state_e state;

    logic [LANES-1:0]      pending;                 // lanes still to satisfy
    logic [LANES-1:0]      mask_q;                   // original active mask
    logic [ADDR_W-1:0]     addr_q  [0:LANES-1];      // latched per-lane address
    logic [DATA_W-1:0]     data_acc[0:LANES-1];      // gathered results
    logic [PHW-1:0]        phase_cnt;

    // ---- per-phase combinational scheduler ---------------------------------
    // For each bank find its leader (lowest-index pending lane), then serve the
    // leader plus every pending lane requesting the same address (broadcast).
    logic                  lead_v   [0:BANKS-1];
    logic [ADDR_W-1:0]     lead_addr[0:BANKS-1];
    logic [LANES-1:0]      serve;
    logic [DATA_W-1:0]     rdata    [0:LANES-1];

    always_comb begin
        integer i, b;
        logic [BSEL-1:0] bnk;

        for (b = 0; b < BANKS; b++) begin
            lead_v[b]    = 1'b0;
            lead_addr[b] = '0;
        end
        // lowest-index pending lane wins the bank -> deterministic broadcast head
        for (i = 0; i < LANES; i++) begin
            if (pending[i]) begin
                bnk = bank_of(addr_q[i]);
                if (!lead_v[bnk]) begin
                    lead_v[bnk]    = 1'b1;
                    lead_addr[bnk] = addr_q[i];
                end
            end
        end
        // serve = leader + all same-address lanes in that bank (broadcast)
        for (i = 0; i < LANES; i++) begin
            serve[i] = 1'b0;
            rdata[i] = '0;
            if (pending[i]) begin
                bnk      = bank_of(addr_q[i]);
                rdata[i] = mem[bnk][row_of(addr_q[i])];
                if (lead_v[bnk] && (addr_q[i] == lead_addr[bnk]))
                    serve[i] = 1'b1;
            end
        end
    end

    wire [LANES-1:0] next_pending = pending & ~serve;

    // ---- control / datapath FSM --------------------------------------------
    integer j;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            pending    <= '0;
            mask_q     <= '0;
            phase_cnt  <= '0;
            resp_valid <= 1'b0;
            for (j = 0; j < LANES; j++) begin
                addr_q[j]   <= '0;
                data_acc[j] <= '0;
            end
        end else begin
            resp_valid <= 1'b0;                    // default: single-cycle strobe

            case (state)
                // -------------------------------------------------------------
                IDLE: begin
                    if (req_valid) begin
                        mask_q    <= req_mask;
                        pending   <= req_mask;
                        phase_cnt <= '0;
                        for (j = 0; j < LANES; j++)
                            addr_q[j] <= req_addr[j*ADDR_W +: ADDR_W];
                        if (req_mask == '0) begin
                            state      <= DONE;    // nothing to gather (0 phases)
                            resp_valid <= 1'b1;
                        end else begin
                            state <= SERVE;
                        end
                    end
                end
                // -------------------------------------------------------------
                SERVE: begin
                    for (j = 0; j < LANES; j++)
                        if (serve[j])
                            data_acc[j] <= rdata[j];
                    pending   <= next_pending;
                    phase_cnt <= phase_cnt + 1'b1;
                    if (next_pending == '0) begin
                        state      <= DONE;
                        resp_valid <= 1'b1;        // result ready next cycle
                    end
                end
                // -------------------------------------------------------------
                DONE: begin
                    state <= IDLE;                 // resp_valid already pulsed
                end
                default: state <= IDLE;
            endcase
        end
    end

    // ---- outputs ------------------------------------------------------------
    assign busy        = (state != IDLE);
    assign resp_mask   = mask_q;
    assign resp_phases = phase_cnt;

    genvar g;
    generate
        for (g = 0; g < LANES; g++) begin : g_pack
            assign resp_data[g*DATA_W +: DATA_W] = data_acc[g];
        end
    endgenerate

endmodule
