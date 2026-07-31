// ============================================================================
// topk_stream_engine.sv
// ----------------------------------------------------------------------------
// Streaming Top-K Selection Engine (systolic sorted-insertion register array).
//
//   Keeps the K LARGEST (data, tag) pairs seen in a one-element-per-cycle
//   stream. On every cycle that `in_valid` is asserted the incoming candidate
//   is compared against ALL K stored entries IN PARALLEL and slotted into its
//   sorted position in a single cycle (throughput = 1 element/clock, latency 1).
//
//   This is a canonical GPU primitive (top-K sampling, beam search, k-NN) and
//   the core datapath of an HFT "top-of-book" / best-N-quote engine: the tag
//   field carries the order/quote ID so the winning entries stay identifiable.
//
//   The stored array is kept strictly SORTED DESCENDING by data. Invalid
//   (empty) slots behave as -infinity and always live at the tail, so a valid
//   candidate is inserted while the array fills, and once full the smallest
//   entry is displaced only when the candidate is strictly larger (with a
//   newer-wins tie rule). Because the effective values are monotone, the set
//   retained equals the global top-K under the total order (data desc, then
//   arrival order desc) — a running selection with no re-sort ever needed.
//
//   Internal state is stored as FLATTENED packed vectors (slot i lives at
//   [i*W +: W]) so the whole design is portable across simulators/synthesis.
//   Fully parameterized, synchronous-reset, lint-friendly, no latches.
// ============================================================================

module topk_stream_engine #(
    parameter int K  = 8,    // number of largest entries retained
    parameter int DW = 16,   // data (key) width  -- treated as SIGNED
    parameter int TW = 8     // tag  (payload/ID) width
) (
    input  logic                     clk,
    input  logic                     rst,        // synchronous, active-high
    input  logic                     flush,      // synchronous clear of all entries

    // streaming candidate input (accepted whenever in_valid && !flush)
    input  logic                     in_valid,
    input  logic signed [DW-1:0]     in_data,
    input  logic        [TW-1:0]     in_tag,

    // sorted result view (slot 0 = current maximum), combinationally reflects state
    output logic        [K-1:0]      valid_o,          // per-slot valid
    output logic        [K*DW-1:0]   data_o,           // slot i = data_o[i*DW +: DW]
    output logic        [K*TW-1:0]   tag_o,            // slot i = tag_o [i*TW +: TW]
    output logic [$clog2(K+1)-1:0]   count_o,          // # valid entries (0..K)
    output logic                     full_o            // count_o == K
);

    localparam int CW = $clog2(K+1);                    // counter / position width
    // most-negative sentinel used as the "empty slot" effective key
    localparam logic signed [DW-1:0] NEG_INF = {1'b1, {(DW-1){1'b0}}};

    // ---- state (flattened, slot i at [i*W +: W]) --------------------------
    logic        [K*DW-1:0] r_data;
    logic        [K*TW-1:0] r_tag;
    logic        [K-1:0]    r_valid;
    logic        [CW-1:0]   count_q;

    // ---- ge[i]: should the candidate sit AT or BEFORE slot i? -------------
    //   Empty slots count as -inf, so ge=1 there. Because effective keys are
    //   sorted descending, ge[] is monotone 0..0 1..1 and the insertion
    //   position `pos` is the index of its first set bit.
    logic [K-1:0]         ge;
    logic signed [DW-1:0] eff;
    always_comb begin
        for (int i = 0; i < K; i++) begin
            eff   = r_valid[i] ? $signed(r_data[i*DW +: DW]) : NEG_INF;
            ge[i] = (in_data >= eff);          // newer element wins ties (>=)
        end
    end

    logic [CW-1:0] pos;                        // K means "smaller than all -> dropped"
    always_comb begin
        pos = CW'(K);
        for (int i = K-1; i >= 0; i--)
            if (ge[i]) pos = CW'(i);
    end

    // an insert actually happens only for an accepted, in-range candidate
    logic do_insert;
    assign do_insert = in_valid && !flush && (pos != CW'(K));

    // ---- next-state: parallel conditional shift/insert --------------------
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            r_valid <= '0;
            r_data  <= '0;
            r_tag   <= '0;
            count_q <= '0;
        end
        else if (do_insert) begin
            for (int i = 0; i < K; i++) begin
                if (CW'(i) < pos) begin
                    // above the insertion point: untouched
                    r_data [i*DW +: DW] <= r_data [i*DW +: DW];
                    r_tag  [i*TW +: TW] <= r_tag  [i*TW +: TW];
                    r_valid[i]          <= r_valid[i];
                end
                else if (CW'(i) == pos) begin
                    r_data [i*DW +: DW] <= in_data;
                    r_tag  [i*TW +: TW] <= in_tag;
                    r_valid[i]          <= 1'b1;
                end
                else begin
                    // below the insertion point: shift previous slot down
                    r_data [i*DW +: DW] <= r_data [(i-1)*DW +: DW];
                    r_tag  [i*TW +: TW] <= r_tag  [(i-1)*TW +: TW];
                    r_valid[i]          <= r_valid[i-1];
                end
            end
            // grew by one unless the array was already full (then it displaced)
            if (!r_valid[K-1])
                count_q <= count_q + 1'b1;
        end
    end

    // ---- output view ------------------------------------------------------
    assign valid_o = r_valid;
    assign data_o  = r_data;
    assign tag_o   = r_tag;
    assign count_o = count_q;
    assign full_o  = (count_q == CW'(K));

endmodule
