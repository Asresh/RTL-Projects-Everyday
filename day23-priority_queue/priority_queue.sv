// ============================================================================
// priority_queue.sv
// ----------------------------------------------------------------------------
// Systolic Register-Array Hardware Priority Queue (min-queue).
//
//   A fixed-capacity priority queue that supports a single-cycle ENQUEUE and a
//   single-cycle EXTRACT-MIN (dequeue of the highest-priority entry), and even
//   BOTH in the same cycle (a "replace-min"). Throughput is one operation per
//   clock with deterministic, data-independent latency — the whole array
//   updates in one cycle from purely local (neighbour) datapaths, so there is
//   never a multi-cycle sift-up / sift-down bubble like a heap in memory.
//
//   The N entries are held as a shift-register array kept strictly SORTED
//   ASCENDING by key, so slot 0 is ALWAYS the current minimum (highest
//   priority) and is available combinationally as the head. Empty slots behave
//   as +infinity and live at the tail, so the valid entries are always packed
//   at the low indices.
//
//   This is a workhorse primitive in exactly the "FPGA-for-finance / line-rate
//   networking" world:
//     * HFT       -- price-time order book (best bid/ask = extract-min/max),
//                    event/timer wheels, and deadline scheduling where the
//                    next order to act on must pop in deterministic latency.
//     * FPGA NIC  -- packet schedulers (strict-priority / earliest-deadline),
//                    QoS queues, traffic shapers, and coalescing timers.
//
//   Per-cycle operation is selected by {enq, deq}:
//     enq  only : insert {enq_key, enq_data} in sorted position   (count += 1)
//     deq  only : remove slot 0 (the minimum), rest shift down     (count -= 1)
//     enq & deq : replace-min -- pop slot 0 AND insert the new key (count same)
//     neither   : hold
//   `full`/`empty` guard the array; an ignored enq-on-full raises `overflow_o`
//   and an ignored deq-on-empty raises `underflow_o` (registered 1-cycle
//   pulses). A synchronous `flush` clears the whole queue in one cycle.
//
//   Insertion uses a STRICT-greater comparison so equal-key entries extract in
//   arrival order (FIFO among equal priorities) -- the fair, well-defined tie
//   rule schedulers expect. State is stored as FLATTENED packed vectors (slot i
//   at [i*W +: W]) so the design is portable across simulators and synthesis.
//   Fully parameterized, synchronous-reset, lint-friendly, no latches.
// ============================================================================

module priority_queue #(
    parameter int N  = 8,    // queue capacity (number of slots)
    parameter int KW = 16,   // key / priority width  -- treated as UNSIGNED
    parameter int DW = 16    // data / payload width (order ID, pointer, ...)
) (
    input  logic                     clk,
    input  logic                     rst,        // synchronous, active-high
    input  logic                     flush,      // synchronous clear of all entries

    // operation request for this cycle
    input  logic                     enq,        // enqueue {enq_key, enq_data}
    input  logic                     deq,        // extract-min (pop slot 0)
    input  logic        [KW-1:0]     enq_key,    // priority of the new entry
    input  logic        [DW-1:0]     enq_data,   // payload of the new entry

    // head-of-queue view (slot 0 = current minimum), combinational
    output logic                     valid_o,          // head valid (count != 0)
    output logic        [KW-1:0]     min_key_o,        // smallest key currently held
    output logic        [DW-1:0]     min_data_o,       // its payload

    // full sorted-array view (slot i at [i*W +: W]); slot 0 = min
    output logic        [N-1:0]      slot_valid_o,
    output logic        [N*KW-1:0]   slot_key_o,
    output logic        [N*DW-1:0]   slot_data_o,

    // occupancy / status
    output logic [$clog2(N+1)-1:0]   count_o,          // # valid entries (0..N)
    output logic                     full_o,           // count_o == N
    output logic                     empty_o,          // count_o == 0
    output logic                     overflow_o,       // enq ignored (was full)
    output logic                     underflow_o       // deq ignored (was empty)
);

    localparam int CW = $clog2(N+1);                    // occupancy counter width
    // effective key of an empty slot: +infinity so empties sort to the tail
    localparam logic [KW-1:0] KEY_INF = {KW{1'b1}};

    // ---- state (flattened, slot i at [i*W +: W]) --------------------------
    logic [N*KW-1:0] r_key;
    logic [N*DW-1:0] r_data;
    logic [N-1:0]    r_valid;
    logic [CW-1:0]   count_q;

    // ---- accepted operations this cycle -----------------------------------
    // A replace (enq & deq) always inserts; it only pops if there is something
    // to pop. A lone enq is dropped when full; a lone deq is dropped when empty.
    logic do_enq, do_deq;
    always_comb begin
        do_enq = enq && (deq || (count_q != CW'(N)));   // full blocks a lone enq
        do_deq = deq && (count_q != CW'(0));            // empty blocks any pop
    end

    // ---- step 1: base[] = array after an (optional) extract-min shift-down -
    // Removing slot 0 shifts every entry toward index 0; the vacated tail slot
    // becomes empty. A sorted-ascending array stays sorted after this.
    logic [N*KW-1:0] base_key;
    logic [N*DW-1:0] base_data;
    logic [N-1:0]    base_valid;
    always_comb begin
        for (int i = 0; i < N; i++) begin
            if (do_deq) begin
                if (i == N-1) begin
                    base_key [i*KW +: KW] = KEY_INF;
                    base_data[i*DW +: DW] = '0;
                    base_valid[i]         = 1'b0;
                end
                else begin
                    base_key [i*KW +: KW] = r_key [(i+1)*KW +: KW];
                    base_data[i*DW +: DW] = r_data[(i+1)*DW +: DW];
                    base_valid[i]         = r_valid[i+1];
                end
            end
            else begin
                base_key [i*KW +: KW] = r_key [i*KW +: KW];
                base_data[i*DW +: DW] = r_data[i*DW +: DW];
                base_valid[i]         = r_valid[i];
            end
        end
    end

    // ---- step 2: insertion position of enq_key into the (sorted) base -----
    // eff[i] = base_valid[i] ? base_key[i] : +inf. Because base is sorted
    // ascending, gt[] = (eff[i] > enq_key) is MONOTONE 0..0 1..1, so the
    // insertion point is the index of its first set bit. STRICT '>' places the
    // new key AFTER any equal-key entries => equal priorities pop FIFO order.
    logic [N-1:0] gt;
    logic [KW-1:0] eff;
    always_comb begin
        for (int i = 0; i < N; i++) begin
            eff   = base_valid[i] ? base_key[i*KW +: KW] : KEY_INF;
            gt[i] = (eff > enq_key);
        end
    end

    logic [CW-1:0] pos;
    always_comb begin
        pos = CW'(N);                       // default: append at the tail
        for (int i = N-1; i >= 0; i--)
            if (gt[i]) pos = CW'(i);
    end

    // ---- step 3: next-state = base with the new key conditionally inserted -
    logic [N*KW-1:0] nxt_key;
    logic [N*DW-1:0] nxt_data;
    logic [N-1:0]    nxt_valid;
    always_comb begin
        nxt_key   = base_key;
        nxt_data  = base_data;
        nxt_valid = base_valid;
        if (do_enq) begin
            for (int i = 0; i < N; i++) begin
                if (CW'(i) < pos) begin
                    // below the insertion point: keep the base entry
                    nxt_key  [i*KW +: KW] = base_key [i*KW +: KW];
                    nxt_data [i*DW +: DW] = base_data[i*DW +: DW];
                    nxt_valid[i]          = base_valid[i];
                end
                else if (CW'(i) == pos) begin
                    // the insertion point: drop in the new entry
                    nxt_key  [i*KW +: KW] = enq_key;
                    nxt_data [i*DW +: DW] = enq_data;
                    nxt_valid[i]          = 1'b1;
                end
                else begin
                    // above the insertion point: shift the neighbour up
                    nxt_key  [i*KW +: KW] = base_key [(i-1)*KW +: KW];
                    nxt_data [i*DW +: DW] = base_data[(i-1)*DW +: DW];
                    nxt_valid[i]          = base_valid[i-1];
                end
            end
        end
    end

    // ---- registers --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            r_key       <= '0;
            r_data      <= '0;
            r_valid     <= '0;
            count_q     <= '0;
            overflow_o  <= 1'b0;
            underflow_o <= 1'b0;
        end
        else begin
            r_key   <= nxt_key;
            r_data  <= nxt_data;
            r_valid <= nxt_valid;
            count_q <= count_q + (do_enq ? CW'(1) : CW'(0))
                               - (do_deq ? CW'(1) : CW'(0));
            // status pulses: a request that could not be honoured
            overflow_o  <= enq && !deq && (count_q == CW'(N));
            underflow_o <= deq && !enq && (count_q == CW'(0));
        end
    end

    // ---- output views -----------------------------------------------------
    assign slot_valid_o = r_valid;
    assign slot_key_o   = r_key;
    assign slot_data_o  = r_data;
    assign valid_o      = r_valid[0];
    assign min_key_o    = r_key [0*KW +: KW];
    assign min_data_o   = r_data[0*DW +: DW];
    assign count_o      = count_q;
    assign full_o       = (count_q == CW'(N));
    assign empty_o      = (count_q == CW'(0));

endmodule
