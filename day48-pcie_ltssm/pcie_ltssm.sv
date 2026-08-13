`timescale 1ns/1ps

module pcie_ltssm #(
    parameter integer LANES             = 4,
    parameter integer TS_REQUIRED       = 4,
    parameter integer TIMEOUT_CYCLES    = 32,
    parameter integer MAX_RETRIES       = 2,
    parameter integer LANE_W            = (LANES <= 1) ? 1 : $clog2(LANES + 1),
    parameter integer TS_W              = (TS_REQUIRED <= 1) ? 1 : $clog2(TS_REQUIRED + 1),
    parameter integer TIMER_W           = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES),
    parameter integer RETRY_W           = (MAX_RETRIES <= 1) ? 1 : $clog2(MAX_RETRIES + 1)
) (
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   enable_i,
    input  wire                   hot_reset_i,
    input  wire                   receiver_detected_i,
    input  wire                   rx_ts1_valid_i,
    input  wire                   rx_ts2_valid_i,
    input  wire [LANES-1:0]       rx_lane_mask_i,
    input  wire                   link_loss_i,
    input  wire                   directed_speed_change_i,

    output logic                  tx_electrical_idle_o,
    output logic                  tx_ts1_o,
    output logic                  tx_ts2_o,
    output logic                  link_up_o,
    output logic                  training_failed_o,
    output logic [LANES-1:0]      active_lane_mask_o,
    output logic [LANE_W-1:0]     negotiated_width_o,
    output logic [RETRY_W-1:0]    retry_count_o,
    output logic [3:0]            state_o
);

    localparam logic [3:0] ST_DISABLED       = 4'd0;
    localparam logic [3:0] ST_DETECT         = 4'd1;
    localparam logic [3:0] ST_POLL_ACTIVE    = 4'd2;
    localparam logic [3:0] ST_POLL_CONFIG    = 4'd3;
    localparam logic [3:0] ST_CFG_WIDTH_START= 4'd4;
    localparam logic [3:0] ST_CFG_WIDTH_ACCEPT=4'd5;
    localparam logic [3:0] ST_CFG_LANENUM    = 4'd6;
    localparam logic [3:0] ST_CFG_COMPLETE   = 4'd7;
    localparam logic [3:0] ST_L0             = 4'd8;
    localparam logic [3:0] ST_RECOVERY_LOCK  = 4'd9;
    localparam logic [3:0] ST_RECOVERY_SPEED = 4'd10;

    logic [3:0] state_q, state_d;
    logic [TS_W-1:0] ts_count_q;
    logic [TIMER_W-1:0] timer_q;
    logic [LANES-1:0] candidate_lanes_q;
    logic qualified_ts;
    logic timeout;
    integer i;

    function automatic [LANE_W-1:0] popcount(input logic [LANES-1:0] value);
        integer k;
        begin
            popcount = '0;
            for (k = 0; k < LANES; k = k + 1)
                popcount = popcount + value[k];
        end
    endfunction

    always_comb begin
        qualified_ts = 1'b0;
        case (state_q)
            ST_POLL_ACTIVE, ST_CFG_WIDTH_START, ST_CFG_WIDTH_ACCEPT,
            ST_RECOVERY_LOCK: qualified_ts = rx_ts1_valid_i && (|rx_lane_mask_i);
            ST_POLL_CONFIG, ST_CFG_LANENUM, ST_CFG_COMPLETE,
            ST_RECOVERY_SPEED: qualified_ts = rx_ts2_valid_i &&
                                (|(rx_lane_mask_i & candidate_lanes_q));
            default: qualified_ts = 1'b0;
        endcase
    end

    assign timeout = (timer_q == TIMEOUT_CYCLES-1);

    always_comb begin
        state_d = state_q;
        case (state_q)
            ST_DISABLED: if (enable_i && !training_failed_o) state_d = ST_DETECT;
            ST_DETECT: if (receiver_detected_i) state_d = ST_POLL_ACTIVE;
            ST_POLL_ACTIVE: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                state_d = ST_POLL_CONFIG;
            ST_POLL_CONFIG: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                state_d = ST_CFG_WIDTH_START;
            ST_CFG_WIDTH_START: if (qualified_ts) state_d = ST_CFG_WIDTH_ACCEPT;
            ST_CFG_WIDTH_ACCEPT: if (qualified_ts &&
                                     ((rx_lane_mask_i & candidate_lanes_q) != '0))
                                     state_d = ST_CFG_LANENUM;
            ST_CFG_LANENUM: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                state_d = ST_CFG_COMPLETE;
            ST_CFG_COMPLETE: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                 state_d = ST_L0;
            ST_L0: if (link_loss_i) state_d = ST_RECOVERY_LOCK;
                   else if (directed_speed_change_i) state_d = ST_RECOVERY_SPEED;
            ST_RECOVERY_LOCK: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                  state_d = ST_RECOVERY_SPEED;
            ST_RECOVERY_SPEED: if (qualified_ts && (ts_count_q == TS_REQUIRED-1))
                                   state_d = ST_L0;
            default: state_d = ST_DISABLED;
        endcase

        if (!enable_i)
            state_d = ST_DISABLED;
        else if (hot_reset_i)
            state_d = ST_DETECT;
        else if (timeout && (state_q != ST_DISABLED) && (state_q != ST_L0))
            state_d = (retry_count_o == MAX_RETRIES) ? ST_DISABLED : ST_DETECT;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q            <= ST_DISABLED;
            ts_count_q         <= '0;
            timer_q            <= '0;
            retry_count_o      <= '0;
            training_failed_o  <= 1'b0;
            candidate_lanes_q  <= {LANES{1'b1}};
            active_lane_mask_o <= '0;
            negotiated_width_o <= '0;
        end else begin
            state_q <= state_d;

            if (!enable_i || hot_reset_i) begin
                ts_count_q <= '0;
                timer_q <= '0;
                retry_count_o <= '0;
                training_failed_o <= 1'b0;
            end else if (timeout && (state_q != ST_DISABLED) && (state_q != ST_L0)) begin
                ts_count_q <= '0;
                timer_q <= '0;
            end else if (state_q == ST_L0) begin
                ts_count_q <= '0;
                timer_q <= '0;
                retry_count_o <= '0;
            end else if (state_q != state_d) begin
                ts_count_q <= '0;
                timer_q <= '0;
            end else begin
                if (qualified_ts) begin
                    if (ts_count_q != TS_REQUIRED)
                        ts_count_q <= ts_count_q + 1'b1;
                end else begin
                    ts_count_q <= '0;
                end
                timer_q <= timer_q + 1'b1;
            end

            if (timeout && (state_q != ST_DISABLED) && (state_q != ST_L0)) begin
                if (retry_count_o == MAX_RETRIES) begin
                    training_failed_o <= 1'b1;
                end else begin
                    retry_count_o <= retry_count_o + 1'b1;
                end
            end

            if ((state_q == ST_CFG_WIDTH_START) && qualified_ts)
                candidate_lanes_q <= rx_lane_mask_i;

            if ((state_q == ST_CFG_WIDTH_ACCEPT) && qualified_ts) begin
                active_lane_mask_o <= rx_lane_mask_i & candidate_lanes_q;
                negotiated_width_o <= popcount(rx_lane_mask_i & candidate_lanes_q);
            end

            if (!enable_i || hot_reset_i) begin
                candidate_lanes_q  <= {LANES{1'b1}};
                active_lane_mask_o <= '0;
                negotiated_width_o <= '0;
            end
        end
    end

    always_comb begin
        tx_electrical_idle_o = 1'b0;
        tx_ts1_o = 1'b0;
        tx_ts2_o = 1'b0;
        link_up_o = 1'b0;
        case (state_q)
            ST_DISABLED, ST_DETECT: tx_electrical_idle_o = 1'b1;
            ST_POLL_ACTIVE, ST_CFG_WIDTH_START, ST_CFG_WIDTH_ACCEPT,
            ST_RECOVERY_LOCK: tx_ts1_o = 1'b1;
            ST_POLL_CONFIG, ST_CFG_LANENUM, ST_CFG_COMPLETE,
            ST_RECOVERY_SPEED: tx_ts2_o = 1'b1;
            ST_L0: link_up_o = 1'b1;
            default: tx_electrical_idle_o = 1'b1;
        endcase
    end

    assign state_o = state_q;

`ifndef SYNTHESIS
    initial begin
        if (LANES < 1 || TS_REQUIRED < 1 || TIMEOUT_CYCLES < 2 || MAX_RETRIES < 1)
            $fatal(1, "Illegal PCIe LTSSM parameterization");
    end
`endif

endmodule
