// Author: Asresh Kuricheti
// Multi-lane PCS deskew and elastic-buffer receiver.

module serdes_deskew_buffer #(
    parameter int LANES            = 4,
    parameter int DATA_WIDTH       = 8,
    parameter int FIFO_DEPTH       = 8,
    parameter int DROP_COUNT_WIDTH = 16
) (
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  retrain,

    input  logic [LANES-1:0]                      rx_valid,
    output logic [LANES-1:0]                      rx_ready,
    input  logic [LANES-1:0][DATA_WIDTH-1:0]      rx_data,
    input  logic [LANES-1:0]                      rx_marker,

    output logic                                  aligned_valid,
    input  logic                                  aligned_ready,
    output logic [LANES-1:0][DATA_WIDTH-1:0]      aligned_data,
    output logic [LANES-1:0]                      aligned_marker,

    output logic                                  locked,
    output logic                                  deskew_error,
    output logic [LANES-1:0]                      fifo_overflow,
    output logic [LANES-1:0][DROP_COUNT_WIDTH-1:0] drop_count
);

    timeunit 1ns;
    timeprecision 1ps;

    localparam int PTR_WIDTH   = (FIFO_DEPTH <= 2) ? 1 : $clog2(FIFO_DEPTH);
    localparam int COUNT_WIDTH = $clog2(FIFO_DEPTH + 1);

    logic [DATA_WIDTH-1:0] data_mem   [0:LANES-1][0:FIFO_DEPTH-1];
    logic                  marker_mem [0:LANES-1][0:FIFO_DEPTH-1];
    logic [PTR_WIDTH-1:0]   write_ptr  [0:LANES-1];
    logic [PTR_WIDTH-1:0]   read_ptr   [0:LANES-1];
    logic [COUNT_WIDTH-1:0] count      [0:LANES-1];

    logic [LANES-1:0] head_marker;
    logic [LANES-1:0] push_lane;
    logic [LANES-1:0] pop_lane;
    logic [LANES-1:0] acquire_pop;
    logic all_nonempty;
    logic all_head_marker;
    logic any_head_marker;
    logic marker_mismatch;
    logic vector_pop;

    function automatic logic [PTR_WIDTH-1:0] ptr_next(
        input logic [PTR_WIDTH-1:0] ptr
    );
        if (ptr == FIFO_DEPTH-1)
            ptr_next = '0;
        else
            ptr_next = ptr + 1'b1;
    endfunction

    always_comb begin
        all_nonempty  = 1'b1;
        all_head_marker = 1'b1;
        any_head_marker = 1'b0;

        for (int lane = 0; lane < LANES; lane++) begin
            aligned_data[lane]   = data_mem[lane][read_ptr[lane]];
            aligned_marker[lane] = (count[lane] != 0) ?
                                   marker_mem[lane][read_ptr[lane]] : 1'b0;
            head_marker[lane]    = aligned_marker[lane];
            all_nonempty         = all_nonempty && (count[lane] != 0);
            all_head_marker      = all_head_marker &&
                                   (count[lane] != 0) && head_marker[lane];
            any_head_marker      = any_head_marker ||
                                   ((count[lane] != 0) && head_marker[lane]);
        end

        marker_mismatch = all_nonempty && any_head_marker && !all_head_marker;
        aligned_valid   = locked && all_nonempty && !marker_mismatch;
        vector_pop      = aligned_valid && aligned_ready;

        for (int lane = 0; lane < LANES; lane++) begin
            acquire_pop[lane] = !locked && (count[lane] != 0) &&
                                !head_marker[lane];
            pop_lane[lane]     = acquire_pop[lane] || vector_pop;
            rx_ready[lane]     = (count[lane] < FIFO_DEPTH) || pop_lane[lane];
            push_lane[lane]    = rx_valid[lane] && rx_ready[lane];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            locked        <= 1'b0;
            deskew_error  <= 1'b0;
            fifo_overflow <= '0;
            for (int lane = 0; lane < LANES; lane++) begin
                write_ptr[lane] <= '0;
                read_ptr[lane]  <= '0;
                count[lane]     <= '0;
                drop_count[lane] <= '0;
            end
        end else if (retrain) begin
            locked <= 1'b0;
            for (int lane = 0; lane < LANES; lane++) begin
                write_ptr[lane] <= '0;
                read_ptr[lane]  <= '0;
                count[lane]     <= '0;
            end
        end else begin
            if (!locked && all_head_marker)
                locked <= 1'b1;
            else if (locked && marker_mismatch) begin
                locked       <= 1'b0;
                deskew_error <= 1'b1;
            end

            for (int lane = 0; lane < LANES; lane++) begin
                if (rx_valid[lane] && !rx_ready[lane]) begin
                    fifo_overflow[lane] <= 1'b1;
                    deskew_error        <= 1'b1;
                end

                if (push_lane[lane]) begin
                    data_mem[lane][write_ptr[lane]]   <= rx_data[lane];
                    marker_mem[lane][write_ptr[lane]] <= rx_marker[lane];
                    write_ptr[lane]                   <= ptr_next(write_ptr[lane]);
                end

                if (pop_lane[lane]) begin
                    read_ptr[lane] <= ptr_next(read_ptr[lane]);
                    if (acquire_pop[lane] && !(&drop_count[lane]))
                        drop_count[lane] <= drop_count[lane] + 1'b1;
                end

                case ({push_lane[lane], pop_lane[lane]})
                    2'b10: count[lane] <= count[lane] + 1'b1;
                    2'b01: count[lane] <= count[lane] - 1'b1;
                    default: count[lane] <= count[lane];
                endcase
            end
        end
    end

    initial begin
        if (LANES < 2)
            $error("LANES must be at least 2");
        if (FIFO_DEPTH < 2)
            $error("FIFO_DEPTH must be at least 2");
    end

endmodule
