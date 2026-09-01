// Author: Asresh Kuricheti
// Parameterized multi-context RISC-V PLIC-style interrupt controller.

module riscv_plic #(
    parameter int SOURCES        = 8,
    parameter int CONTEXTS       = 2,
    parameter int PRIORITY_WIDTH = 3,
    parameter logic [SOURCES-1:0] EDGE_MASK = '0,
    parameter int COUNT_WIDTH    = 16,
    parameter int ID_WIDTH       = $clog2(SOURCES + 1),
    parameter int CTX_WIDTH      = (CONTEXTS <= 1) ? 1 : $clog2(CONTEXTS)
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  logic                                      clear_status,

    input  logic [SOURCES-1:0]                        irq_source,

    input  logic                                      priority_we,
    input  logic [ID_WIDTH-1:0]                       priority_id,
    input  logic [PRIORITY_WIDTH-1:0]                 priority_value,
    input  logic                                      enable_we,
    input  logic [CTX_WIDTH-1:0]                      enable_context,
    input  logic [SOURCES-1:0]                        enable_value,
    input  logic                                      threshold_we,
    input  logic [CTX_WIDTH-1:0]                      threshold_context,
    input  logic [PRIORITY_WIDTH-1:0]                 threshold_value,

    input  logic [CONTEXTS-1:0]                       claim_req,
    output logic [CONTEXTS-1:0]                       claim_valid,
    output logic [CONTEXTS-1:0][ID_WIDTH-1:0]         claim_id,
    input  logic [CONTEXTS-1:0]                       complete_valid,
    input  logic [CONTEXTS-1:0][ID_WIDTH-1:0]         complete_id,

    output logic [CONTEXTS-1:0]                       irq_notify,
    output logic [SOURCES-1:0]                        pending_bitmap,
    output logic [SOURCES-1:0]                        in_service_bitmap,
    output logic                                      protocol_error,
    output logic                                      event_overflow,
    output logic [ID_WIDTH-1:0]                       first_error_id,
    output logic [CONTEXTS-1:0][COUNT_WIDTH-1:0]      claim_count
);

    timeunit 1ns;
    timeprecision 1ps;

    logic [SOURCES-1:0] irq_source_q;
    logic [SOURCES-1:0] pending;
    logic [SOURCES-1:0] in_service;
    logic [PRIORITY_WIDTH-1:0] source_priority [0:SOURCES-1];
    logic [SOURCES-1:0] enable_mask [0:CONTEXTS-1];
    logic [PRIORITY_WIDTH-1:0] threshold [0:CONTEXTS-1];
    logic [CTX_WIDTH-1:0] owner [0:SOURCES-1];

    logic [SOURCES-1:0] reserved;
    logic [CONTEXTS-1:0][PRIORITY_WIDTH-1:0] selected_priority;
    logic [CONTEXTS-1:0][PRIORITY_WIDTH-1:0] notify_priority;

    assign pending_bitmap    = pending;
    assign in_service_bitmap = in_service;

    always_comb begin
        reserved = '0;
        claim_valid = '0;
        claim_id = '0;
        irq_notify = '0;
        selected_priority = '0;
        notify_priority = '0;

        for (int ctx = 0; ctx < CONTEXTS; ctx++) begin
            for (int src = 0; src < SOURCES; src++) begin
                if (pending[src] && !in_service[src] && enable_mask[ctx][src] &&
                    (source_priority[src] > threshold[ctx]) &&
                    (source_priority[src] > notify_priority[ctx])) begin
                    notify_priority[ctx] = source_priority[src];
                    irq_notify[ctx] = 1'b1;
                end
            end

            if (claim_req[ctx]) begin
                for (int src = 0; src < SOURCES; src++) begin
                    if (pending[src] && !in_service[src] && !reserved[src] &&
                        enable_mask[ctx][src] &&
                        (source_priority[src] > threshold[ctx]) &&
                        (source_priority[src] > selected_priority[ctx])) begin
                        selected_priority[ctx] = source_priority[src];
                        claim_valid[ctx] = 1'b1;
                        claim_id[ctx] = ID_WIDTH'(src + 1);
                    end
                end
                if (claim_valid[ctx])
                    reserved[claim_id[ctx] - 1'b1] = 1'b1;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_source_q  <= '0;
            pending       <= '0;
            in_service    <= '0;
            protocol_error <= 1'b0;
            event_overflow <= 1'b0;
            first_error_id <= '0;
            for (int src = 0; src < SOURCES; src++) begin
                source_priority[src] <= '0;
                owner[src] <= '0;
            end
            for (int ctx = 0; ctx < CONTEXTS; ctx++) begin
                enable_mask[ctx] <= '0;
                threshold[ctx] <= '0;
                claim_count[ctx] <= '0;
            end
        end else begin
            irq_source_q <= irq_source;

            if (clear_status) begin
                protocol_error <= 1'b0;
                event_overflow <= 1'b0;
                first_error_id <= '0;
                for (int ctx = 0; ctx < CONTEXTS; ctx++)
                    claim_count[ctx] <= '0;
            end

            if (priority_we) begin
                if ((priority_id > 0) && (priority_id <= SOURCES))
                    source_priority[priority_id - 1'b1] <= priority_value;
                else begin
                    protocol_error <= 1'b1;
                    if (!protocol_error)
                        first_error_id <= priority_id;
                end
            end
            if (enable_we) begin
                if (enable_context < CONTEXTS)
                    enable_mask[enable_context] <= enable_value;
                else begin
                    protocol_error <= 1'b1;
                    if (!protocol_error)
                        first_error_id <= '0;
                end
            end
            if (threshold_we) begin
                if (threshold_context < CONTEXTS)
                    threshold[threshold_context] <= threshold_value;
                else begin
                    protocol_error <= 1'b1;
                    if (!protocol_error)
                        first_error_id <= '0;
                end
            end

            for (int src = 0; src < SOURCES; src++) begin
                if (EDGE_MASK[src]) begin
                    if (irq_source[src] && !irq_source_q[src]) begin
                        if (pending[src])
                            event_overflow <= 1'b1;
                        else
                            pending[src] <= 1'b1;
                    end
                end else if (!in_service[src]) begin
                    pending[src] <= irq_source[src];
                end
            end

            for (int ctx = 0; ctx < CONTEXTS; ctx++) begin
                if (complete_valid[ctx]) begin
                    if ((complete_id[ctx] > 0) && (complete_id[ctx] <= SOURCES) &&
                        in_service[complete_id[ctx] - 1'b1] &&
                        (owner[complete_id[ctx] - 1'b1] == ctx)) begin
                        in_service[complete_id[ctx] - 1'b1] <= 1'b0;
                        if (!EDGE_MASK[complete_id[ctx] - 1'b1] &&
                            irq_source[complete_id[ctx] - 1'b1])
                            pending[complete_id[ctx] - 1'b1] <= 1'b1;
                    end else begin
                        protocol_error <= 1'b1;
                        if (!protocol_error)
                            first_error_id <= complete_id[ctx];
                    end
                end
            end

            for (int ctx = 0; ctx < CONTEXTS; ctx++) begin
                if (claim_valid[ctx]) begin
                    pending[claim_id[ctx] - 1'b1] <= 1'b0;
                    in_service[claim_id[ctx] - 1'b1] <= 1'b1;
                    owner[claim_id[ctx] - 1'b1] <= CTX_WIDTH'(ctx);
                    if (!(&claim_count[ctx]))
                        claim_count[ctx] <= claim_count[ctx] + 1'b1;
                end
            end
        end
    end

    initial begin
        if (SOURCES < 1)
            $error("SOURCES must be at least one");
        if (CONTEXTS < 1)
            $error("CONTEXTS must be at least one");
        if (PRIORITY_WIDTH < 1)
            $error("PRIORITY_WIDTH must be at least one");
    end

endmodule
