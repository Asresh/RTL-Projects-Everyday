// ---------------------------------------------------------------------------
// Day 39 : 4-way set-associative write-back / write-allocate L1 data cache
//          with true-LRU replacement and a writeback flush engine
//
//  - Zero-wait-state hits: the tag compare, way mux and word mux are all
//    combinational, so a hitting request is acknowledged in the SAME cycle it
//    is presented (back-to-back 1 request/clock hit throughput).
//  - Misses are handled by a hard-sequenced FSM: select victim (invalid way
//    first, else true-LRU rank), write the victim back as a burst if it is
//    dirty, refill the missing line as a burst, then allocate + merge any
//    pending store and answer the CPU.
//  - Write policy: write-back + write-allocate, byte-enable granular. A store
//    hit does a read-modify-write of the cached line and sets the dirty bit;
//    no memory traffic is generated until the line is evicted or flushed.
//  - True LRU (not pseudo-LRU): each way carries an age rank 0..WAYS-1 that is
//    a permutation of the ways in that set. Any access promotes its way to
//    rank 0 (MRU) and increments every way that was more recent; the victim is
//    the way at rank WAYS-1.
//  - `flush_req` walks the whole tag array and writes every dirty line back to
//    memory (clean-flush: lines stay valid, dirty bits are cleared), so a
//    testbench or a DMA agent can make memory architecturally coherent.
//
// Fully parameterized, reset-safe, latch-free, no vendor primitives.
// ---------------------------------------------------------------------------

`default_nettype none

module l1_dcache_4way #(
    parameter int ADDR_W         = 32,   // byte address width
    parameter int DATA_W         = 32,   // CPU word width
    parameter int WAYS           = 4,    // associativity (power of 2)
    parameter int SETS           = 64,   // sets (power of 2)
    parameter int WORDS_PER_LINE = 4     // line size in words (power of 2)
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // ---------------- CPU side (single outstanding request) ----------------
    input  wire                   cpu_req,    // hold until cpu_ack
    input  wire                   cpu_we,     // 1 = store, 0 = load
    input  wire [ADDR_W-1:0]      cpu_addr,   // byte address
    input  wire [DATA_W-1:0]      cpu_wdata,
    input  wire [DATA_W/8-1:0]    cpu_be,     // store byte enables
    output logic [DATA_W-1:0]     cpu_rdata,  // valid in the cycle cpu_ack=1
    output logic                  cpu_ack,    // request retired this cycle

    // ---------------- maintenance -----------------------------------------
    input  wire                   flush_req,  // pulse: write back all dirty lines
    output logic                  flush_busy,
    output logic                  flush_done, // 1-cycle pulse when finished

    // ---------------- memory side (line-granular bursts) ------------------
    output logic                  mem_rd_req, // 1-cycle: start a line read
    output logic                  mem_wr_req, // 1-cycle: start a line write
    output logic [ADDR_W-1:0]     mem_addr,   // line-aligned
    output logic [DATA_W-1:0]     mem_wdata,  // write beat (word 0 first)
    output logic                  mem_wvalid,
    input  wire                   mem_wready,
    input  wire [DATA_W-1:0]      mem_rdata,  // read beat (word 0 first)
    input  wire                   mem_rvalid,

    // ---------------- performance event pulses ----------------------------
    output logic                  ev_hit,
    output logic                  ev_miss,
    output logic                  ev_wb       // a dirty line went to memory
);

    // ----------------------------------------------------------------- //
    // derived geometry
    // ----------------------------------------------------------------- //
    localparam int BE_W   = DATA_W / 8;
    localparam int LINE_W = DATA_W * WORDS_PER_LINE;
    localparam int BOFF_W = $clog2(BE_W);            // byte-in-word offset
    localparam int WOFF_W = $clog2(WORDS_PER_LINE);  // word-in-line offset
    localparam int IDX_W  = $clog2(SETS);
    localparam int TAG_W  = ADDR_W - IDX_W - WOFF_W - BOFF_W;
    localparam int WAY_W  = $clog2(WAYS);
    localparam int LOFF_W = WOFF_W + BOFF_W;         // byte-in-line offset

    // ----------------------------------------------------------------- //
    // address field helpers
    // ----------------------------------------------------------------- //
    function automatic [TAG_W-1:0] tag_of(input logic [ADDR_W-1:0] a);
        tag_of = a[ADDR_W-1 -: TAG_W];
    endfunction

    function automatic [IDX_W-1:0] idx_of(input logic [ADDR_W-1:0] a);
        idx_of = a[LOFF_W+IDX_W-1 -: IDX_W];
    endfunction

    function automatic [WOFF_W-1:0] woff_of(input logic [ADDR_W-1:0] a);
        woff_of = a[LOFF_W-1 -: WOFF_W];
    endfunction

    function automatic [ADDR_W-1:0] line_addr(input logic [TAG_W-1:0] t,
                                              input logic [IDX_W-1:0] i);
        line_addr = {t, i, {LOFF_W{1'b0}}};
    endfunction

    // extract one word out of a cache line
    function automatic [DATA_W-1:0] word_of(input logic [LINE_W-1:0]  line,
                                            input logic [WOFF_W-1:0]  off);
        word_of = line[off*DATA_W +: DATA_W];
    endfunction

    // byte-enable read-modify-write of one word inside a cache line
    function automatic [LINE_W-1:0] merge_word(input logic [LINE_W-1:0] line,
                                               input logic [WOFF_W-1:0] off,
                                               input logic [DATA_W-1:0] wd,
                                               input logic [BE_W-1:0]   be);
        logic [LINE_W-1:0] res;
        res = line;
        for (int b = 0; b < BE_W; b++)
            if (be[b]) res[off*DATA_W + b*8 +: 8] = wd[b*8 +: 8];
        merge_word = res;
    endfunction

    // ----------------------------------------------------------------- //
    // tag / valid / dirty / age / data arrays
    // ----------------------------------------------------------------- //
    logic [TAG_W-1:0]  tag_q [SETS-1:0][WAYS-1:0];
    logic              vld_q [SETS-1:0][WAYS-1:0];
    logic              dty_q [SETS-1:0][WAYS-1:0];
    logic [WAY_W-1:0]  age_q [SETS-1:0][WAYS-1:0];   // 0 = MRU, WAYS-1 = LRU
    logic [LINE_W-1:0] dat_q [SETS-1:0][WAYS-1:0];

    // ----------------------------------------------------------------- //
    // FSM
    // ----------------------------------------------------------------- //
    typedef enum logic [3:0] {
        S_IDLE      = 4'd0,   // combinational lookup / 1-cycle hit
        S_SEL       = 4'd1,   // pick the victim way for a miss
        S_WB_REQ    = 4'd2,   // request the victim writeback burst
        S_WB_DATA   = 4'd3,   // stream the victim line out
        S_FILL_REQ  = 4'd4,   // request the refill burst
        S_FILL_DATA = 4'd5,   // collect the refill beats
        S_ALLOC     = 4'd6,   // install the line, merge the store, answer CPU
        S_FL_SCAN   = 4'd7,   // flush: inspect one (set,way)
        S_FL_NEXT   = 4'd8    // flush: advance the (set,way) walk
    } state_e;

    state_e state_q;

    // latched request
    logic [ADDR_W-1:0]  r_addr;
    logic               r_we;
    logic [DATA_W-1:0]  r_wdata;
    logic [BE_W-1:0]    r_be;
    logic [WAY_W-1:0]   r_way;

    // burst machinery
    logic [ADDR_W-1:0]  wb_addr_q;
    logic [LINE_W-1:0]  wb_line_q;
    logic [LINE_W-1:0]  fill_q;
    logic [WOFF_W-1:0]  beat_q;
    logic               wb_is_flush;

    // flush walk
    logic [IDX_W:0]     fl_set;      // one extra bit: terminates at SETS
    logic [WAY_W-1:0]   fl_way;
    logic               flush_pend;

    wire [IDX_W-1:0]    fs = fl_set[IDX_W-1:0];

    // current (CPU-presented) address fields
    wire [TAG_W-1:0]    c_tag  = tag_of(cpu_addr);
    wire [IDX_W-1:0]    c_idx  = idx_of(cpu_addr);
    wire [WOFF_W-1:0]   c_woff = woff_of(cpu_addr);

    // latched (miss) address fields
    wire [TAG_W-1:0]    r_tag  = tag_of(r_addr);
    wire [IDX_W-1:0]    r_idx  = idx_of(r_addr);
    wire [WOFF_W-1:0]   r_woff = woff_of(r_addr);

    // ----------------------------------------------------------------- //
    // combinational tag lookup (all WAYS compared in parallel)
    // ----------------------------------------------------------------- //
    logic             hit;
    logic [WAY_W-1:0] hit_way;

    always_comb begin
        hit     = 1'b0;
        hit_way = '0;
        for (int w = 0; w < WAYS; w++)
            if (vld_q[c_idx][w] && (tag_q[c_idx][w] == c_tag)) begin
                hit     = 1'b1;
                hit_way = w;
            end
    end

    // a request can be served this cycle only from S_IDLE with no flush pending
    wire lookup_en = (state_q == S_IDLE) && cpu_req && !flush_pend;
    wire hit_now   = lookup_en &&  hit;
    wire miss_now  = lookup_en && !hit;

    // ----------------------------------------------------------------- //
    // victim selection for the latched miss: invalid way first, else LRU
    // ----------------------------------------------------------------- //
    logic [WAY_W-1:0] vic_way;
    logic             vic_inv;

    always_comb begin
        vic_way = '0;
        vic_inv = 1'b0;
        for (int w = WAYS-1; w >= 0; w--)          // lowest invalid way wins
            if (!vld_q[r_idx][w]) begin
                vic_way = w;
                vic_inv = 1'b1;
            end
        if (!vic_inv)
            for (int w = 0; w < WAYS; w++)         // else the LRU rank
                if (age_q[r_idx][w] == WAYS-1)
                    vic_way = w;
    end

    // ----------------------------------------------------------------- //
    // outputs
    // ----------------------------------------------------------------- //
    always_comb begin
        cpu_rdata = '0;
        if (state_q == S_IDLE)       cpu_rdata = word_of(dat_q[c_idx][hit_way], c_woff);
        else if (state_q == S_ALLOC) cpu_rdata = word_of(fill_q, r_woff);
    end

    always_comb begin
        cpu_ack    = hit_now || (state_q == S_ALLOC);
        ev_hit     = hit_now;
        ev_miss    = miss_now;
        ev_wb      = (state_q == S_WB_REQ);
        flush_busy = flush_pend || (state_q == S_FL_SCAN) || (state_q == S_FL_NEXT);

        mem_rd_req = (state_q == S_FILL_REQ);
        mem_wr_req = (state_q == S_WB_REQ);
        mem_wvalid = (state_q == S_WB_DATA);
        mem_wdata  = word_of(wb_line_q, beat_q);
        mem_addr   = (state_q == S_WB_REQ) ? wb_addr_q
                                           : line_addr(r_tag, r_idx);
    end

    // ----------------------------------------------------------------- //
    // main sequential logic
    // ----------------------------------------------------------------- //
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q     <= S_IDLE;
            r_addr      <= '0;
            r_we        <= 1'b0;
            r_wdata     <= '0;
            r_be        <= '0;
            r_way       <= '0;
            wb_addr_q   <= '0;
            wb_line_q   <= '0;
            fill_q      <= '0;
            beat_q      <= '0;
            wb_is_flush <= 1'b0;
            fl_set      <= '0;
            fl_way      <= '0;
            flush_pend  <= 1'b0;
            flush_done  <= 1'b0;
            for (int s = 0; s < SETS; s++)
                for (int w = 0; w < WAYS; w++) begin
                    vld_q[s][w] <= 1'b0;
                    dty_q[s][w] <= 1'b0;
                    tag_q[s][w] <= '0;
                    dat_q[s][w] <= '0;
                    age_q[s][w] <= w;   // ranks start as a permutation
                end
        end else begin
            flush_done <= 1'b0;
            if (flush_req) flush_pend <= 1'b1;

            case (state_q)

            // ---------------- lookup / zero-wait-state hit ----------------
            S_IDLE: begin
                if (flush_pend) begin
                    fl_set   <= '0;
                    fl_way   <= '0;
                    state_q  <= S_FL_SCAN;
                end else if (cpu_req) begin
                    if (hit) begin
                        if (cpu_we) begin
                            dat_q[c_idx][hit_way] <= merge_word(dat_q[c_idx][hit_way],
                                                               c_woff, cpu_wdata, cpu_be);
                            dty_q[c_idx][hit_way] <= 1'b1;
                        end
                        // promote this way to MRU (true LRU rank update)
                        for (int k = 0; k < WAYS; k++)
                            if (age_q[c_idx][k] < age_q[c_idx][hit_way])
                                age_q[c_idx][k] <= age_q[c_idx][k] + 1'b1;
                        age_q[c_idx][hit_way] <= '0;
                    end else begin
                        r_addr  <= cpu_addr;
                        r_we    <= cpu_we;
                        r_wdata <= cpu_wdata;
                        r_be    <= cpu_be;
                        state_q <= S_SEL;
                    end
                end
            end

            // ---------------- pick the victim -----------------------------
            S_SEL: begin
                r_way       <= vic_way;
                wb_addr_q   <= line_addr(tag_q[r_idx][vic_way], r_idx);
                wb_line_q   <= dat_q[r_idx][vic_way];
                beat_q      <= '0;
                wb_is_flush <= 1'b0;
                if (vld_q[r_idx][vic_way] && dty_q[r_idx][vic_way])
                    state_q <= S_WB_REQ;      // dirty victim: write it back first
                else
                    state_q <= S_FILL_REQ;    // clean or empty: straight to refill
            end

            // ---------------- victim writeback burst ----------------------
            S_WB_REQ: begin
                beat_q  <= '0;
                state_q <= S_WB_DATA;
            end

            S_WB_DATA: begin
                if (mem_wready) begin
                    if (beat_q == WORDS_PER_LINE-1) begin
                        beat_q <= '0;
                        if (wb_is_flush) begin
                            dty_q[fs][fl_way] <= 1'b0;   // line is clean again
                            state_q           <= S_FL_NEXT;
                        end else begin
                            state_q <= S_FILL_REQ;
                        end
                    end else begin
                        beat_q <= beat_q + 1'b1;
                    end
                end
            end

            // ---------------- refill burst --------------------------------
            S_FILL_REQ: begin
                beat_q  <= '0;
                state_q <= S_FILL_DATA;
            end

            S_FILL_DATA: begin
                if (mem_rvalid) begin
                    fill_q[beat_q*DATA_W +: DATA_W] <= mem_rdata;
                    if (beat_q == WORDS_PER_LINE-1) state_q <= S_ALLOC;
                    else                            beat_q  <= beat_q + 1'b1;
                end
            end

            // ---------------- install the line, answer the CPU ------------
            S_ALLOC: begin
                tag_q[r_idx][r_way] <= r_tag;
                vld_q[r_idx][r_way] <= 1'b1;
                if (r_we) begin                       // write-allocate: merge store
                    dat_q[r_idx][r_way] <= merge_word(fill_q, r_woff, r_wdata, r_be);
                    dty_q[r_idx][r_way] <= 1'b1;
                end else begin
                    dat_q[r_idx][r_way] <= fill_q;
                    dty_q[r_idx][r_way] <= 1'b0;
                end
                for (int k = 0; k < WAYS; k++)        // allocated way becomes MRU
                    if (age_q[r_idx][k] < age_q[r_idx][r_way])
                        age_q[r_idx][k] <= age_q[r_idx][k] + 1'b1;
                age_q[r_idx][r_way] <= '0;
                state_q <= S_IDLE;
            end

            // ---------------- flush walk ----------------------------------
            S_FL_SCAN: begin
                if (fl_set == SETS) begin
                    flush_pend <= 1'b0;
                    flush_done <= 1'b1;
                    state_q    <= S_IDLE;
                end else if (vld_q[fs][fl_way] && dty_q[fs][fl_way]) begin
                    wb_addr_q   <= line_addr(tag_q[fs][fl_way], fs);
                    wb_line_q   <= dat_q[fs][fl_way];
                    beat_q      <= '0;
                    wb_is_flush <= 1'b1;
                    state_q     <= S_WB_REQ;
                end else begin
                    state_q <= S_FL_NEXT;
                end
            end

            S_FL_NEXT: begin
                if (fl_way == WAYS-1) begin
                    fl_way <= '0;
                    fl_set <= fl_set + 1'b1;
                end else begin
                    fl_way <= fl_way + 1'b1;
                end
                state_q <= S_FL_SCAN;
            end

            default: state_q <= S_IDLE;

            endcase
        end
    end

endmodule

`default_nettype wire
