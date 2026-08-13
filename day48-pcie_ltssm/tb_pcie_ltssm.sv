`timescale 1ns/1ps

module tb_pcie_ltssm;
    localparam integer LANES = 4;
    localparam integer TS_REQUIRED = 4;
    localparam integer TIMEOUT_CYCLES = 12;
    localparam integer MAX_RETRIES = 2;

    localparam [3:0] ST_DISABLED=0, ST_DETECT=1, ST_POLL_ACTIVE=2,
                     ST_POLL_CONFIG=3, ST_CFG_WIDTH_START=4,
                     ST_CFG_WIDTH_ACCEPT=5, ST_CFG_LANENUM=6,
                     ST_CFG_COMPLETE=7, ST_L0=8, ST_RECOVERY_LOCK=9,
                     ST_RECOVERY_SPEED=10;

    logic clk = 0;
    logic rst_n = 0;
    logic enable_i, hot_reset_i, receiver_detected_i;
    logic rx_ts1_valid_i, rx_ts2_valid_i;
    logic [LANES-1:0] rx_lane_mask_i;
    logic link_loss_i, directed_speed_change_i;
    wire tx_electrical_idle_o, tx_ts1_o, tx_ts2_o, link_up_o;
    wire training_failed_o;
    wire [LANES-1:0] active_lane_mask_o;
    wire [2:0] negotiated_width_o;
    wire [1:0] retry_count_o;
    wire [3:0] state_o;

    integer errors = 0;
    integer checks = 0;
    integer seed = 32'h48c0ffee;
    integer n;

    logic [3:0] m_state;
    integer m_ts_count, m_timer, m_retry;
    logic m_failed;
    logic [LANES-1:0] m_candidate, m_active;
    integer m_width;

    pcie_ltssm #(
        .LANES(LANES), .TS_REQUIRED(TS_REQUIRED),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES), .MAX_RETRIES(MAX_RETRIES)
    ) dut (.*);

    always #5 clk = ~clk;

    function automatic integer countones(input logic [LANES-1:0] value);
        integer k;
        begin
            countones = 0;
            for (k = 0; k < LANES; k = k + 1)
                countones = countones + value[k];
        end
    endfunction

    function automatic logic model_qualified;
        begin
            case (m_state)
                ST_POLL_ACTIVE, ST_CFG_WIDTH_START, ST_CFG_WIDTH_ACCEPT,
                ST_RECOVERY_LOCK:
                    model_qualified = rx_ts1_valid_i && (|rx_lane_mask_i);
                ST_POLL_CONFIG, ST_CFG_LANENUM, ST_CFG_COMPLETE,
                ST_RECOVERY_SPEED:
                    model_qualified = rx_ts2_valid_i &&
                                      (|(rx_lane_mask_i & m_candidate));
                default: model_qualified = 1'b0;
            endcase
        end
    endfunction

    task automatic model_step;
        logic [3:0] old_state, next_state;
        logic qual, timed_out;
        begin
            if (!rst_n) begin
                m_state = ST_DISABLED;
                m_ts_count = 0;
                m_timer = 0;
                m_retry = 0;
                m_failed = 0;
                m_candidate = {LANES{1'b1}};
                m_active = 0;
                m_width = 0;
            end else begin
                old_state = m_state;
                qual = model_qualified();
                timed_out = (m_timer == TIMEOUT_CYCLES-1);
                next_state = old_state;
                case (old_state)
                    ST_DISABLED: if (enable_i && !m_failed) next_state = ST_DETECT;
                    ST_DETECT: if (receiver_detected_i) next_state = ST_POLL_ACTIVE;
                    ST_POLL_ACTIVE: if (qual && m_ts_count == TS_REQUIRED-1)
                                        next_state = ST_POLL_CONFIG;
                    ST_POLL_CONFIG: if (qual && m_ts_count == TS_REQUIRED-1)
                                        next_state = ST_CFG_WIDTH_START;
                    ST_CFG_WIDTH_START: if (qual) next_state = ST_CFG_WIDTH_ACCEPT;
                    ST_CFG_WIDTH_ACCEPT: if (qual &&
                        ((rx_lane_mask_i & m_candidate) != 0)) next_state = ST_CFG_LANENUM;
                    ST_CFG_LANENUM: if (qual && m_ts_count == TS_REQUIRED-1)
                                       next_state = ST_CFG_COMPLETE;
                    ST_CFG_COMPLETE: if (qual && m_ts_count == TS_REQUIRED-1)
                                        next_state = ST_L0;
                    ST_L0: if (link_loss_i) next_state = ST_RECOVERY_LOCK;
                           else if (directed_speed_change_i) next_state = ST_RECOVERY_SPEED;
                    ST_RECOVERY_LOCK: if (qual && m_ts_count == TS_REQUIRED-1)
                                         next_state = ST_RECOVERY_SPEED;
                    ST_RECOVERY_SPEED: if (qual && m_ts_count == TS_REQUIRED-1)
                                          next_state = ST_L0;
                    default: next_state = ST_DISABLED;
                endcase
                if (!enable_i) next_state = ST_DISABLED;
                else if (hot_reset_i) next_state = ST_DETECT;
                else if (timed_out && old_state != ST_DISABLED && old_state != ST_L0)
                    next_state = (m_retry == MAX_RETRIES) ? ST_DISABLED : ST_DETECT;

                if (!enable_i || hot_reset_i) begin
                    m_ts_count = 0;
                    m_timer = 0;
                    m_retry = 0;
                    m_failed = 0;
                end else if (timed_out && old_state != ST_DISABLED && old_state != ST_L0) begin
                    m_ts_count = 0;
                    m_timer = 0;
                end else if (old_state == ST_L0) begin
                    m_ts_count = 0;
                    m_timer = 0;
                    m_retry = 0;
                end else if (old_state != next_state) begin
                    m_ts_count = 0;
                    m_timer = 0;
                end else begin
                    m_ts_count = qual ? ((m_ts_count == TS_REQUIRED) ?
                                         m_ts_count : m_ts_count + 1) : 0;
                    m_timer = m_timer + 1;
                end

                if (timed_out && old_state != ST_DISABLED && old_state != ST_L0) begin
                    if (m_retry == MAX_RETRIES) m_failed = 1;
                    else m_retry = m_retry + 1;
                end
                if (old_state == ST_CFG_WIDTH_START && qual)
                    m_candidate = rx_lane_mask_i;
                if (old_state == ST_CFG_WIDTH_ACCEPT && qual) begin
                    m_active = rx_lane_mask_i & m_candidate;
                    m_width = countones(rx_lane_mask_i & m_candidate);
                end
                if (!enable_i || hot_reset_i) begin
                    m_candidate = {LANES{1'b1}};
                    m_active = 0;
                    m_width = 0;
                end
                m_state = next_state;
            end
        end
    endtask

    always @(posedge clk) model_step();

    task automatic check_equal;
        logic exp_idle, exp_ts1, exp_ts2, exp_up;
        begin
            exp_idle = (m_state == ST_DISABLED || m_state == ST_DETECT);
            exp_ts1 = (m_state == ST_POLL_ACTIVE || m_state == ST_CFG_WIDTH_START ||
                       m_state == ST_CFG_WIDTH_ACCEPT || m_state == ST_RECOVERY_LOCK);
            exp_ts2 = (m_state == ST_POLL_CONFIG || m_state == ST_CFG_LANENUM ||
                       m_state == ST_CFG_COMPLETE || m_state == ST_RECOVERY_SPEED);
            exp_up = (m_state == ST_L0);
            checks = checks + 1;
            if (state_o !== m_state || tx_electrical_idle_o !== exp_idle ||
                tx_ts1_o !== exp_ts1 || tx_ts2_o !== exp_ts2 || link_up_o !== exp_up ||
                training_failed_o !== m_failed || retry_count_o !== m_retry ||
                active_lane_mask_o !== m_active || negotiated_width_o !== m_width) begin
                errors = errors + 1;
                $error("model mismatch state dut=%0d ref=%0d retry=%0d/%0d width=%0d/%0d",
                       state_o, m_state, retry_count_o, m_retry,
                       negotiated_width_o, m_width);
            end
        end
    endtask

    always @(negedge clk) if (rst_n) check_equal();

    task automatic idle_inputs;
        begin
            hot_reset_i = 0; receiver_detected_i = 0;
            rx_ts1_valid_i = 0; rx_ts2_valid_i = 0; rx_lane_mask_i = 0;
            link_loss_i = 0; directed_speed_change_i = 0;
        end
    endtask

    task automatic cycle;
        begin
            @(negedge clk);
        end
    endtask

    task automatic send_ts1(input logic [LANES-1:0] mask, input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                rx_ts1_valid_i = 1; rx_ts2_valid_i = 0; rx_lane_mask_i = mask;
                cycle();
            end
            rx_ts1_valid_i = 0;
        end
    endtask

    task automatic send_ts2(input logic [LANES-1:0] mask, input integer count);
        integer k;
        begin
            for (k = 0; k < count; k = k + 1) begin
                rx_ts1_valid_i = 0; rx_ts2_valid_i = 1; rx_lane_mask_i = mask;
                cycle();
            end
            rx_ts2_valid_i = 0;
        end
    endtask

    task automatic train_x2_link;
        begin
            receiver_detected_i = 1; cycle(); receiver_detected_i = 0;
            send_ts1(4'b1111, TS_REQUIRED);
            send_ts2(4'b1111, TS_REQUIRED);
            send_ts1(4'b1111, 1);
            send_ts1(4'b0011, 1);
            send_ts2(4'b0011, TS_REQUIRED);
            send_ts2(4'b0011, TS_REQUIRED);
            if (!link_up_o || negotiated_width_o != 2 || active_lane_mask_o != 4'b0011) begin
                errors = errors + 1;
                $error("directed x2 link training failed");
            end
        end
    endtask

    initial begin
        $dumpfile("pcie_ltssm.vcd");
        $dumpvars(0, tb_pcie_ltssm);
        if ($value$plusargs("seed=%d", seed))
            $display("Using seed %0d", seed);
        enable_i = 0;
        idle_inputs();
        repeat (3) cycle();
        rst_n = 1;
        enable_i = 1;
        cycle();

        $display("PHASE 1: directed x4-to-x2 link training");
        train_x2_link();

        $display("PHASE 2: directed speed-change recovery");
        directed_speed_change_i = 1; cycle(); directed_speed_change_i = 0;
        send_ts2(4'b0011, TS_REQUIRED);
        if (!link_up_o) begin errors = errors + 1; $error("speed recovery failed"); end

        $display("PHASE 3: link-loss recovery through receiver lock");
        link_loss_i = 1; cycle(); link_loss_i = 0;
        send_ts1(4'b0011, TS_REQUIRED);
        send_ts2(4'b0011, TS_REQUIRED);
        if (!link_up_o) begin errors = errors + 1; $error("link-loss recovery failed"); end

        $display("PHASE 4: randomized ordered-set disturbance and recovery");
        hot_reset_i = 1; cycle(); hot_reset_i = 0;
        for (n = 0; n < 80; n = n + 1) begin
            receiver_detected_i = ($urandom(seed) % 5) == 0;
            rx_ts1_valid_i = ($urandom(seed) % 3) == 0;
            rx_ts2_valid_i = ($urandom(seed) % 3) == 0;
            rx_lane_mask_i = $urandom(seed);
            if (rx_lane_mask_i == 0) rx_lane_mask_i = 1;
            link_loss_i = (m_state == ST_L0) && (($urandom(seed) % 17) == 0);
            directed_speed_change_i = (m_state == ST_L0) && (($urandom(seed) % 19) == 0);
            cycle();
        end
        idle_inputs();

        $display("PHASE 5: timeout/retry/fail-safe path");
        enable_i = 0; cycle(); enable_i = 1; cycle();
        repeat ((MAX_RETRIES + 1) * (TIMEOUT_CYCLES + 1)) cycle();
        if (!training_failed_o || state_o != ST_DISABLED) begin
            errors = errors + 1;
            $error("timeout fail-safe did not latch");
        end

        if (errors == 0)
            $display("RESULT: *** PASS *** (%0d model checks)", checks);
        else begin
            $display("RESULT: *** FAIL *** (%0d errors, %0d checks)", errors, checks);
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "TIMEOUT: testbench did not finish");
    end
endmodule
