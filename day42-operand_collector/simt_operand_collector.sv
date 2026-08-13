`timescale 1ns/1ps
`default_nettype none

module simt_operand_collector #(
    parameter int DATA_WIDTH     = 32,
    parameter int REG_COUNT      = 32,
    parameter int WARP_COUNT     = 4,
    parameter int BANKS          = 4,
    parameter int COLLECTORS     = 4,
    parameter int TAG_WIDTH      = 12,
    parameter int SOURCES        = 3,
    localparam int REG_W         = $clog2(REG_COUNT),
    localparam int WARP_W        = $clog2(WARP_COUNT),
    localparam int COLL_W        = $clog2(COLLECTORS),
    localparam int BANK_W        = $clog2(BANKS)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         flush_i,

    input  logic                         wr_en_i,
    input  logic [WARP_W-1:0]            wr_warp_i,
    input  logic [REG_W-1:0]             wr_reg_i,
    input  logic [DATA_WIDTH-1:0]        wr_data_i,

    input  logic                         req_valid_i,
    output logic                         req_ready_o,
    input  logic [WARP_W-1:0]            req_warp_i,
    input  logic [TAG_WIDTH-1:0]         req_tag_i,
    input  logic [SOURCES-1:0]           req_src_valid_i,
    input  logic [SOURCES*REG_W-1:0]     req_src_reg_i,

    output logic                         issue_valid_o,
    input  logic                         issue_ready_i,
    output logic [WARP_W-1:0]            issue_warp_o,
    output logic [TAG_WIDTH-1:0]         issue_tag_o,
    output logic [SOURCES*DATA_WIDTH-1:0] issue_operand_o,
    output logic [SOURCES-1:0]           issue_src_valid_o,

    output logic [COLLECTORS-1:0]        dbg_busy_o,
    output logic [COLLECTORS*SOURCES-1:0] dbg_pending_o,
    output logic [31:0]                  perf_bank_reads_o,
    output logic [31:0]                  perf_reuse_hits_o,
    output logic [31:0]                  perf_conflict_cycles_o
);

    logic [DATA_WIDTH-1:0] regfile [0:WARP_COUNT-1][0:REG_COUNT-1];

    logic                   busy_q       [0:COLLECTORS-1];
    logic [WARP_W-1:0]      warp_q       [0:COLLECTORS-1];
    logic [TAG_WIDTH-1:0]   tag_q        [0:COLLECTORS-1];
    logic [SOURCES-1:0]     src_valid_q  [0:COLLECTORS-1];
    logic [REG_W-1:0]       src_reg_q    [0:COLLECTORS-1][0:SOURCES-1];
    logic [DATA_WIDTH-1:0]  operand_q    [0:COLLECTORS-1][0:SOURCES-1];
    logic [SOURCES-1:0]     pending_q    [0:COLLECTORS-1];

    // Two-entry, warp-private operand-reuse cache. Entry 0 is MRU.
    logic                   reuse_valid_q [0:WARP_COUNT-1][0:1];
    logic [REG_W-1:0]       reuse_reg_q   [0:WARP_COUNT-1][0:1];
    logic [DATA_WIDTH-1:0]  reuse_data_q  [0:WARP_COUNT-1][0:1];

    logic [COLL_W-1:0] bank_rr_q [0:BANKS-1];
    logic [COLL_W-1:0] issue_rr_q;
    logic [COLL_W-1:0] free_idx;
    logic               free_found;
    logic [COLL_W-1:0] issue_idx;
    logic               issue_found;
    logic [COLL_W-1:0] grant_coll [0:BANKS-1];
    logic [$clog2(SOURCES)-1:0] grant_src [0:BANKS-1];
    logic               grant_valid [0:BANKS-1];
    logic [7:0]         contenders [0:BANKS-1];

    integer c, s, b, off, idx;
    always_comb begin
        free_found = 1'b0;
        free_idx   = '0;
        for (c = 0; c < COLLECTORS; c = c + 1) begin
            if (!free_found && !busy_q[c]) begin
                free_found = 1'b1;
                free_idx   = COLL_W'(c);
            end
        end
        req_ready_o = free_found && !flush_i;

        issue_found = 1'b0;
        issue_idx   = '0;
        for (off = 0; off < COLLECTORS; off = off + 1) begin
            idx = issue_rr_q + off;
            if (idx >= COLLECTORS)
                idx = idx - COLLECTORS;
            if (!issue_found && busy_q[idx] && (pending_q[idx] == '0)) begin
                issue_found = 1'b1;
                issue_idx   = COLL_W'(idx);
            end
        end

        issue_valid_o     = issue_found && !flush_i;
        issue_warp_o      = '0;
        issue_tag_o       = '0;
        issue_operand_o   = '0;
        issue_src_valid_o = '0;
        if (issue_found) begin
            issue_warp_o      = warp_q[issue_idx];
            issue_tag_o       = tag_q[issue_idx];
            issue_src_valid_o = src_valid_q[issue_idx];
            for (s = 0; s < SOURCES; s = s + 1)
                issue_operand_o[s*DATA_WIDTH +: DATA_WIDTH] = operand_q[issue_idx][s];
        end

        for (b = 0; b < BANKS; b = b + 1) begin
            grant_valid[b] = 1'b0;
            grant_coll[b]  = '0;
            grant_src[b]   = '0;
            contenders[b]  = '0;
            for (off = 0; off < COLLECTORS; off = off + 1) begin
                idx = bank_rr_q[b] + off;
                if (idx >= COLLECTORS)
                    idx = idx - COLLECTORS;
                for (s = 0; s < SOURCES; s = s + 1) begin
                    if (busy_q[idx] && pending_q[idx][s] &&
                        ((src_reg_q[idx][s] & (BANKS-1)) == b)) begin
                        contenders[b] = contenders[b] + 1'b1;
                        if (!grant_valid[b]) begin
                            grant_valid[b] = 1'b1;
                            grant_coll[b]  = COLL_W'(idx);
                            grant_src[b]   = s[$clog2(SOURCES)-1:0];
                        end
                    end
                end
            end
        end

        for (c = 0; c < COLLECTORS; c = c + 1) begin
            dbg_busy_o[c] = busy_q[c];
            for (s = 0; s < SOURCES; s = s + 1)
                dbg_pending_o[c*SOURCES+s] = pending_q[c][s];
        end
    end

    integer w, r, way;
    integer cycle_bank_reads, cycle_conflicts, cycle_reuse_hits;
    logic [WARP_COUNT-1:0] cache_fill_seen;
    logic [REG_W-1:0] dispatch_reg;
    logic hit0, hit1;
    logic [DATA_WIDTH-1:0] read_value;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            issue_rr_q            <= '0;
            perf_bank_reads_o     <= '0;
            perf_reuse_hits_o     <= '0;
            perf_conflict_cycles_o<= '0;
            for (c = 0; c < COLLECTORS; c = c + 1) begin
                busy_q[c]      <= 1'b0;
                warp_q[c]      <= '0;
                tag_q[c]       <= '0;
                src_valid_q[c] <= '0;
                pending_q[c]   <= '0;
                for (s = 0; s < SOURCES; s = s + 1) begin
                    src_reg_q[c][s] <= '0;
                    operand_q[c][s] <= '0;
                end
            end
            for (b = 0; b < BANKS; b = b + 1)
                bank_rr_q[b] <= '0;
            for (w = 0; w < WARP_COUNT; w = w + 1)
                for (way = 0; way < 2; way = way + 1) begin
                    reuse_valid_q[w][way] <= 1'b0;
                    reuse_reg_q[w][way]   <= '0;
                    reuse_data_q[w][way]  <= '0;
                end
        end else begin
            if (wr_en_i)
                regfile[wr_warp_i][wr_reg_i] <= wr_data_i;

            if (flush_i) begin
                issue_rr_q <= '0;
                for (c = 0; c < COLLECTORS; c = c + 1) begin
                    busy_q[c]    <= 1'b0;
                    pending_q[c] <= '0;
                end
                for (b = 0; b < BANKS; b = b + 1)
                    bank_rr_q[b] <= '0;
                for (w = 0; w < WARP_COUNT; w = w + 1)
                    for (way = 0; way < 2; way = way + 1)
                        reuse_valid_q[w][way] <= 1'b0;
            end else begin
                cycle_bank_reads = 0;
                cycle_conflicts  = 0;
                cycle_reuse_hits = 0;
                cache_fill_seen  = '0;
                if (wr_en_i) begin
                    // A writeback makes any cached copy obsolete. A bank read
                    // below may immediately refill entry 0 with forwarded data.
                    reuse_valid_q[wr_warp_i][0] <= 1'b0;
                    reuse_valid_q[wr_warp_i][1] <= 1'b0;
                end
                if (issue_valid_o && issue_ready_i) begin
                    busy_q[issue_idx]    <= 1'b0;
                    pending_q[issue_idx] <= '0;
                    issue_rr_q <= (issue_idx == COLLECTORS-1) ? '0 : issue_idx + 1'b1;
                end

                // One winning operand per physical bank per cycle.
                for (b = 0; b < BANKS; b = b + 1) begin
                    if (grant_valid[b]) begin
                        read_value = regfile[warp_q[grant_coll[b]]]
                                             [src_reg_q[grant_coll[b]][grant_src[b]]];
                        if (wr_en_i &&
                            (wr_warp_i == warp_q[grant_coll[b]]) &&
                            (wr_reg_i == src_reg_q[grant_coll[b]][grant_src[b]]))
                            read_value = wr_data_i;
                        operand_q[grant_coll[b]][grant_src[b]] <= read_value;
                        pending_q[grant_coll[b]][grant_src[b]] <= 1'b0;
                        bank_rr_q[b] <= (grant_coll[b] == COLLECTORS-1) ? '0 :
                                        grant_coll[b] + 1'b1;
                        cycle_bank_reads = cycle_bank_reads + 1;

                        w = warp_q[grant_coll[b]];
                        // At most one fill per warp per cycle; all physical
                        // reads still complete, but this avoids a multiwriter
                        // cache structure when several banks serve one warp.
                        if (!cache_fill_seen[w]) begin
                            cache_fill_seen[w] = 1'b1;
                            if (wr_en_i && (wr_warp_i == w)) begin
                                reuse_valid_q[w][1] <= 1'b0;
                            end else begin
                                reuse_valid_q[w][1] <= reuse_valid_q[w][0];
                                reuse_reg_q[w][1]   <= reuse_reg_q[w][0];
                                reuse_data_q[w][1]  <= reuse_data_q[w][0];
                            end
                            reuse_valid_q[w][0] <= 1'b1;
                            reuse_reg_q[w][0]   <= src_reg_q[grant_coll[b]][grant_src[b]];
                            reuse_data_q[w][0]  <= read_value;
                        end
                    end
                    if (contenders[b] > 1)
                        cycle_conflicts = cycle_conflicts + 1;
                end

                if (req_valid_i && req_ready_o) begin
                    busy_q[free_idx]      <= 1'b1;
                    warp_q[free_idx]      <= req_warp_i;
                    tag_q[free_idx]       <= req_tag_i;
                    src_valid_q[free_idx] <= req_src_valid_i;
                    for (s = 0; s < SOURCES; s = s + 1) begin
                        dispatch_reg = req_src_reg_i[s*REG_W +: REG_W];
                        hit0 = reuse_valid_q[req_warp_i][0] &&
                               (reuse_reg_q[req_warp_i][0] == dispatch_reg);
                        hit1 = reuse_valid_q[req_warp_i][1] &&
                               (reuse_reg_q[req_warp_i][1] == dispatch_reg);
                        if (wr_en_i && (wr_warp_i == req_warp_i) &&
                            (wr_reg_i == dispatch_reg)) begin
                            hit0 = 1'b0;
                            hit1 = 1'b0;
                        end
                        src_reg_q[free_idx][s] <= dispatch_reg;
                        if (!req_src_valid_i[s]) begin
                            pending_q[free_idx][s] <= 1'b0;
                            operand_q[free_idx][s] <= '0;
                        end else if (hit0 || hit1) begin
                            pending_q[free_idx][s] <= 1'b0;
                            operand_q[free_idx][s] <= hit0 ? reuse_data_q[req_warp_i][0]
                                                           : reuse_data_q[req_warp_i][1];
                            cycle_reuse_hits = cycle_reuse_hits + 1;
                        end else begin
                            pending_q[free_idx][s] <= 1'b1;
                            operand_q[free_idx][s] <= '0;
                        end
                    end
                end
                perf_bank_reads_o      <= perf_bank_reads_o + cycle_bank_reads;
                perf_conflict_cycles_o <= perf_conflict_cycles_o + cycle_conflicts;
                perf_reuse_hits_o      <= perf_reuse_hits_o + cycle_reuse_hits;
            end
        end
    end

    initial begin
        if (BANKS < 2 || (BANKS & (BANKS-1)) != 0)
            $fatal(1, "BANKS must be a power of two and >= 2");
        if (REG_COUNT < BANKS || (REG_COUNT & (REG_COUNT-1)) != 0)
            $fatal(1, "REG_COUNT must be a power of two and >= BANKS");
        if (COLLECTORS < 2 || SOURCES < 2)
            $fatal(1, "COLLECTORS and SOURCES must both be >= 2");
    end

endmodule

`default_nettype wire
