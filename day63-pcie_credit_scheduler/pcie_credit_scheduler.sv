// Author: Asresh Kuricheti
// PCIe-style Transaction Layer credit manager and virtual-channel scheduler.

module pcie_credit_scheduler #(
    parameter int VCS          = 2,
    parameter int DEPTH        = 4,
    parameter int ID_WIDTH     = 12,
    parameter int CREDIT_WIDTH = 8,
    parameter int DATA_WIDTH   = 8,
    parameter int COUNT_WIDTH  = 16,
    parameter int VC_WIDTH     = (VCS <= 1) ? 1 : $clog2(VCS),
    parameter int PTR_WIDTH    = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int OCC_WIDTH    = $clog2(DEPTH + 1),
    parameter int RR_WIDTH     = (VCS * 3 <= 1) ? 1 : $clog2(VCS * 3)
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         clear_status,

    input  logic                         in_valid,
    output logic                         in_ready,
    input  logic [VC_WIDTH-1:0]          in_vc,
    input  logic [1:0]                   in_class,
    input  logic [ID_WIDTH-1:0]          in_id,
    input  logic [DATA_WIDTH-1:0]        in_data_credits,

    input  logic                         fc_valid,
    input  logic [VC_WIDTH-1:0]          fc_vc,
    input  logic [1:0]                   fc_class,
    input  logic [CREDIT_WIDTH-1:0]      fc_header_inc,
    input  logic [CREDIT_WIDTH-1:0]      fc_data_inc,

    output logic                         out_valid,
    input  logic                         out_ready,
    output logic [VC_WIDTH-1:0]          out_vc,
    output logic [1:0]                   out_class,
    output logic [ID_WIDTH-1:0]          out_id,
    output logic [DATA_WIDTH-1:0]        out_data_credits,

    output logic                         completion_urgent,
    output logic                         credit_blocked,
    output logic                         protocol_error,
    output logic                         queue_overflow,
    output logic [COUNT_WIDTH-1:0]       accepted_count,
    output logic [COUNT_WIDTH-1:0]       transmitted_count
);

    timeunit 1ns;
    timeprecision 1ps;

    localparam int CLASSES = 3;
    localparam int QUEUES  = VCS * CLASSES;
    localparam logic [1:0] CLASS_CPL = 2'd2;

    logic [ID_WIDTH-1:0]   id_mem   [0:QUEUES-1][0:DEPTH-1];
    logic [DATA_WIDTH-1:0] data_mem [0:QUEUES-1][0:DEPTH-1];
    logic [PTR_WIDTH-1:0]  wr_ptr   [0:QUEUES-1];
    logic [PTR_WIDTH-1:0]  rd_ptr   [0:QUEUES-1];
    logic [OCC_WIDTH-1:0]  count    [0:QUEUES-1];
    logic [CREDIT_WIDTH-1:0] header_credit [0:QUEUES-1];
    logic [CREDIT_WIDTH-1:0] data_credit   [0:QUEUES-1];
    logic [RR_WIDTH-1:0] rr_ptr;

    logic slot_available;
    logic select_valid;
    logic [RR_WIDTH-1:0] select_q;
    logic [ID_WIDTH-1:0] select_id;
    logic [DATA_WIDTH-1:0] select_data;
    logic enqueue_fire;
    logic dequeue_fire;
    integer in_q;
    integer fc_q;

    always_comb begin
        in_q = (in_vc * CLASSES) + in_class;
        fc_q = (fc_vc * CLASSES) + fc_class;
        in_ready = 1'b0;
        if ((in_vc < VCS) && (in_class < CLASSES))
            in_ready = (count[in_q] < DEPTH);
        enqueue_fire = in_valid && in_ready;
    end

    always_comb begin
        completion_urgent = 1'b0;
        credit_blocked = 1'b0;
        for (int q = 0; q < QUEUES; q++) begin
            if ((q % CLASSES == CLASS_CPL) && (count[q] >= (DEPTH - 1)))
                completion_urgent = 1'b1;
            if ((count[q] != 0) &&
                ((header_credit[q] == 0) ||
                 (data_credit[q] < data_mem[q][rd_ptr[q]])))
                credit_blocked = 1'b1;
        end
    end

    always_comb begin
        slot_available = !out_valid || out_ready;
        select_valid = 1'b0;
        select_q = '0;
        select_id = '0;
        select_data = '0;

        // When completions approach a full queue, service them before ordinary
        // round-robin traffic so completions cannot deadlock non-posted reads.
        if (slot_available && completion_urgent) begin
            for (int step = QUEUES; step > 0; step--) begin
                int q;
                q = (rr_ptr + step) % QUEUES;
                if (!select_valid && (q % CLASSES == CLASS_CPL) &&
                    (count[q] != 0) && (header_credit[q] != 0) &&
                    (data_credit[q] >= data_mem[q][rd_ptr[q]]) &&
                    !(fc_valid && (fc_vc < VCS) && (fc_class < CLASSES) &&
                      (q == fc_q))) begin
                    select_valid = 1'b1;
                    select_q = RR_WIDTH'(q);
                end
            end
        end

        if (slot_available && !select_valid) begin
            for (int step = QUEUES; step > 0; step--) begin
                int q;
                q = (rr_ptr + step) % QUEUES;
                if (!select_valid && (count[q] != 0) &&
                    (header_credit[q] != 0) &&
                    (data_credit[q] >= data_mem[q][rd_ptr[q]]) &&
                    !(fc_valid && (fc_vc < VCS) && (fc_class < CLASSES) &&
                      (q == fc_q))) begin
                    select_valid = 1'b1;
                    select_q = RR_WIDTH'(q);
                end
            end
        end

        if (select_valid) begin
            select_id = id_mem[select_q][rd_ptr[select_q]];
            select_data = data_mem[select_q][rd_ptr[select_q]];
        end
        dequeue_fire = slot_available && select_valid;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0;
            out_vc <= '0;
            out_class <= '0;
            out_id <= '0;
            out_data_credits <= '0;
            rr_ptr <= '0;
            protocol_error <= 1'b0;
            queue_overflow <= 1'b0;
            accepted_count <= '0;
            transmitted_count <= '0;
            for (int q = 0; q < QUEUES; q++) begin
                wr_ptr[q] <= '0;
                rd_ptr[q] <= '0;
                count[q] <= '0;
                header_credit[q] <= '0;
                data_credit[q] <= '0;
            end
        end else begin
            if (clear_status) begin
                protocol_error <= 1'b0;
                queue_overflow <= 1'b0;
                accepted_count <= '0;
                transmitted_count <= '0;
            end

            if (out_valid && out_ready) begin
                out_valid <= 1'b0;
                if (!(&transmitted_count))
                    transmitted_count <= transmitted_count + 1'b1;
            end

            if (in_valid && ((in_vc >= VCS) || (in_class >= CLASSES)))
                protocol_error <= 1'b1;
            else if (in_valid && !in_ready)
                queue_overflow <= 1'b1;

            if (fc_valid) begin
                if ((fc_vc < VCS) && (fc_class < CLASSES)) begin
                    if (({1'b0, header_credit[fc_q]} + fc_header_inc) > {CREDIT_WIDTH{1'b1}})
                        header_credit[fc_q] <= {CREDIT_WIDTH{1'b1}};
                    else
                        header_credit[fc_q] <= header_credit[fc_q] + fc_header_inc;
                    if (({1'b0, data_credit[fc_q]} + fc_data_inc) > {CREDIT_WIDTH{1'b1}})
                        data_credit[fc_q] <= {CREDIT_WIDTH{1'b1}};
                    else
                        data_credit[fc_q] <= data_credit[fc_q] + fc_data_inc;
                end else begin
                    protocol_error <= 1'b1;
                end
            end

            if (enqueue_fire) begin
                id_mem[in_q][wr_ptr[in_q]] <= in_id;
                data_mem[in_q][wr_ptr[in_q]] <= in_data_credits;
                if (wr_ptr[in_q] == DEPTH - 1)
                    wr_ptr[in_q] <= '0;
                else
                    wr_ptr[in_q] <= wr_ptr[in_q] + 1'b1;
                if (!(&accepted_count))
                    accepted_count <= accepted_count + 1'b1;
            end

            if (dequeue_fire) begin
                out_valid <= 1'b1;
                out_vc <= VC_WIDTH'(select_q / CLASSES);
                out_class <= 2'(select_q % CLASSES);
                out_id <= select_id;
                out_data_credits <= select_data;
                header_credit[select_q] <= header_credit[select_q] - 1'b1;
                data_credit[select_q] <= data_credit[select_q] - select_data;
                if (rd_ptr[select_q] == DEPTH - 1)
                    rd_ptr[select_q] <= '0;
                else
                    rd_ptr[select_q] <= rd_ptr[select_q] + 1'b1;
                if (select_q == QUEUES - 1)
                    rr_ptr <= '0;
                else
                    rr_ptr <= select_q + 1'b1;
            end

            for (int q = 0; q < QUEUES; q++) begin
                if (enqueue_fire && (in_q == q) && dequeue_fire && (select_q == q))
                    count[q] <= count[q];
                else if (enqueue_fire && (in_q == q))
                    count[q] <= count[q] + 1'b1;
                else if (dequeue_fire && (select_q == q))
                    count[q] <= count[q] - 1'b1;
            end
        end
    end

    initial begin
        if (VCS < 1) $error("VCS must be at least one");
        if (DEPTH < 2) $error("DEPTH must be at least two");
        if (CREDIT_WIDTH < DATA_WIDTH)
            $error("CREDIT_WIDTH must cover DATA_WIDTH");
    end

endmodule
