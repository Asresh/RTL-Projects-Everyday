// Author: Asresh Kuricheti
`timescale 1ns/1ps

module power_domain_sequencer #(
    parameter integer DOMAINS        = 4,
    parameter integer ACTION_DELAY   = 2,
    parameter integer TIMEOUT_CYCLES = 12,
    parameter integer INDEX_WIDTH    = (DOMAINS <= 1) ? 1 : $clog2(DOMAINS),
    parameter integer COUNT_MAX      = (TIMEOUT_CYCLES > ACTION_DELAY) ? TIMEOUT_CYCLES : ACTION_DELAY,
    parameter integer COUNT_WIDTH    = (COUNT_MAX <= 1) ? 1 : $clog2(COUNT_MAX + 1)
) (
    input  logic                    clk,
    input  logic                    arst_n,
    input  logic                    cmd_valid,
    output logic                    cmd_ready,
    input  logic                    cmd_power_up,
    input  logic                    clear_fault,
    input  logic [DOMAINS-1:0]      power_good_async,
    output logic [DOMAINS-1:0]      power_switch_en,
    output logic [DOMAINS-1:0]      isolation_en,
    output logic [DOMAINS-1:0]      domain_reset_n,
    output logic                    busy,
    output logic                    done,
    output logic                    fault,
    output logic [INDEX_WIDTH-1:0]  fault_domain,
    output logic [3:0]              state_debug
);

    typedef enum logic [3:0] {
        ST_IDLE          = 4'd0,
        ST_UP_SWITCH     = 4'd1,
        ST_UP_WAIT_GOOD  = 4'd2,
        ST_UP_RESET_WAIT = 4'd3,
        ST_UP_ISO_WAIT   = 4'd4,
        ST_DN_ISOLATE    = 4'd5,
        ST_DN_RESET_WAIT = 4'd6,
        ST_DN_SWITCH     = 4'd7,
        ST_DN_WAIT_OFF   = 4'd8
    } state_t;

    state_t state;
    logic [DOMAINS-1:0] power_good_meta;
    logic [DOMAINS-1:0] power_good_sync;
    logic [INDEX_WIDTH-1:0] domain_index;
    logic [COUNT_WIDTH-1:0] wait_count;

    assign cmd_ready   = (state == ST_IDLE) && !fault;
    assign state_debug = state;

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            power_good_meta <= '0;
            power_good_sync <= '0;
        end else begin
            power_good_meta <= power_good_async;
            power_good_sync <= power_good_meta;
        end
    end

    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            state           <= ST_IDLE;
            domain_index    <= '0;
            wait_count      <= '0;
            power_switch_en <= '0;
            isolation_en    <= '1;
            domain_reset_n  <= '0;
            busy            <= 1'b0;
            done            <= 1'b0;
            fault           <= 1'b0;
            fault_domain    <= '0;
        end else begin
            done <= 1'b0;

            if (clear_fault && (state == ST_IDLE)) begin
                fault <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    busy       <= 1'b0;
                    wait_count <= '0;
                    if (cmd_valid && cmd_ready) begin
                        busy <= 1'b1;
                        if (cmd_power_up) begin
                            domain_index <= '0;
                            state        <= ST_UP_SWITCH;
                        end else begin
                            domain_index <= DOMAINS - 1;
                            state        <= ST_DN_ISOLATE;
                        end
                    end
                end

                ST_UP_SWITCH: begin
                    power_switch_en[domain_index] <= 1'b1;
                    wait_count                    <= '0;
                    state                         <= ST_UP_WAIT_GOOD;
                end

                ST_UP_WAIT_GOOD: begin
                    if (power_good_sync[domain_index]) begin
                        wait_count <= '0;
                        state      <= ST_UP_RESET_WAIT;
                    end else if (wait_count == TIMEOUT_CYCLES - 1) begin
                        power_switch_en[domain_index] <= 1'b0;
                        fault_domain                  <= domain_index;
                        fault                         <= 1'b1;
                        busy                          <= 1'b0;
                        state                         <= ST_IDLE;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_UP_RESET_WAIT: begin
                    if (wait_count == ACTION_DELAY - 1) begin
                        domain_reset_n[domain_index] <= 1'b1;
                        wait_count                   <= '0;
                        state                        <= ST_UP_ISO_WAIT;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_UP_ISO_WAIT: begin
                    if (wait_count == ACTION_DELAY - 1) begin
                        isolation_en[domain_index] <= 1'b0;
                        wait_count                 <= '0;
                        if (domain_index == DOMAINS - 1) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            domain_index <= domain_index + 1'b1;
                            state        <= ST_UP_SWITCH;
                        end
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_DN_ISOLATE: begin
                    isolation_en[domain_index] <= 1'b1;
                    wait_count                 <= '0;
                    state                      <= ST_DN_RESET_WAIT;
                end

                ST_DN_RESET_WAIT: begin
                    if (wait_count == ACTION_DELAY - 1) begin
                        domain_reset_n[domain_index] <= 1'b0;
                        wait_count                   <= '0;
                        state                        <= ST_DN_SWITCH;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                ST_DN_SWITCH: begin
                    power_switch_en[domain_index] <= 1'b0;
                    wait_count                    <= '0;
                    state                         <= ST_DN_WAIT_OFF;
                end

                ST_DN_WAIT_OFF: begin
                    if (!power_good_sync[domain_index]) begin
                        wait_count <= '0;
                        if (domain_index == 0) begin
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            state <= ST_IDLE;
                        end else begin
                            domain_index <= domain_index - 1'b1;
                            state        <= ST_DN_ISOLATE;
                        end
                    end else if (wait_count == TIMEOUT_CYCLES - 1) begin
                        fault_domain <= domain_index;
                        fault        <= 1'b1;
                        busy         <= 1'b0;
                        state        <= ST_IDLE;
                    end else begin
                        wait_count <= wait_count + 1'b1;
                    end
                end

                default: begin
                    power_switch_en <= '0;
                    isolation_en    <= '1;
                    domain_reset_n  <= '0;
                    busy            <= 1'b0;
                    fault           <= 1'b1;
                    fault_domain    <= '0;
                    state           <= ST_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (DOMAINS < 2) $error("DOMAINS must be at least 2");
        if (ACTION_DELAY < 1) $error("ACTION_DELAY must be at least 1");
        if (TIMEOUT_CYCLES < 2) $error("TIMEOUT_CYCLES must be at least 2");
    end

endmodule
