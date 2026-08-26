// Author: Asresh Kuricheti
`timescale 1ns/1ps

module tb_power_domain_sequencer;
    localparam integer DOMAINS = 4;
    localparam integer ACTION_DELAY = 2;
    localparam integer TIMEOUT_CYCLES = 12;

    logic clk = 1'b0;
    logic arst_n = 1'b0;
    logic cmd_valid = 1'b0;
    logic cmd_power_up = 1'b0;
    logic clear_fault = 1'b0;
    logic [DOMAINS-1:0] power_good_async = '0;
    logic cmd_ready;
    logic [DOMAINS-1:0] power_switch_en;
    logic [DOMAINS-1:0] isolation_en;
    logic [DOMAINS-1:0] domain_reset_n;
    logic busy, done, fault;
    logic [$clog2(DOMAINS)-1:0] fault_domain;
    logic [3:0] state_debug;

    integer checks = 0;
    integer seed = 32'h57c0ffee;
    integer csv;
    integer cycle = 0;
    integer i;

    always #5 clk = ~clk;

    power_domain_sequencer #(
        .DOMAINS(DOMAINS),
        .ACTION_DELAY(ACTION_DELAY),
        .TIMEOUT_CYCLES(TIMEOUT_CYCLES)
    ) dut (.*);

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("ERROR: %s at cycle %0d", message, cycle);
                $fatal(1);
            end
        end
    endtask

    task automatic issue_command(input logic power_up);
        begin
            while (!cmd_ready) @(posedge clk);
            cmd_power_up <= power_up;
            cmd_valid    <= 1'b1;
            @(posedge clk);
            cmd_valid    <= 1'b0;
        end
    endtask

    task automatic wait_cycles(input integer count);
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) @(posedge clk);
        end
    endtask

    task automatic golden_power_up(input integer max_latency);
        integer d;
        integer latency;
        logic [DOMAINS-1:0] expected_switch;
        logic [DOMAINS-1:0] expected_iso;
        logic [DOMAINS-1:0] expected_reset;
        begin
            expected_switch = power_switch_en;
            expected_iso    = isolation_en;
            expected_reset  = domain_reset_n;
            issue_command(1'b1);
            for (d = 0; d < DOMAINS; d = d + 1) begin
                wait (power_switch_en[d] === 1'b1);
                expected_switch[d] = 1'b1;
                check(power_switch_en == expected_switch, "power-up switch order");
                check(isolation_en == expected_iso, "isolation held during ramp");
                check(domain_reset_n == expected_reset, "reset held during ramp");
                latency = 1 + ($urandom(seed) % max_latency);
                wait_cycles(latency);
                power_good_async[d] <= 1'b1;
                wait (domain_reset_n[d] === 1'b1);
                expected_reset[d] = 1'b1;
                check(domain_reset_n == expected_reset, "power-up reset release order");
                check(isolation_en[d], "isolation remains before reset release");
                wait (isolation_en[d] === 1'b0);
                expected_iso[d] = 1'b0;
                check(isolation_en == expected_iso, "power-up isolation removal order");
            end
            wait (done === 1'b1);
            check(!fault, "power-up completes without fault");
            check(power_switch_en == {DOMAINS{1'b1}}, "all switches enabled");
            check(isolation_en == '0, "all isolation removed");
            check(domain_reset_n == {DOMAINS{1'b1}}, "all resets released");
            @(posedge clk);
            #1;
            check(!done, "done is a one-cycle pulse");
        end
    endtask

    task automatic golden_power_down(input integer max_latency);
        integer d;
        integer latency;
        logic [DOMAINS-1:0] expected_switch;
        logic [DOMAINS-1:0] expected_iso;
        logic [DOMAINS-1:0] expected_reset;
        begin
            expected_switch = power_switch_en;
            expected_iso    = isolation_en;
            expected_reset  = domain_reset_n;
            issue_command(1'b0);
            for (d = DOMAINS - 1; d >= 0; d = d - 1) begin
                wait (isolation_en[d] === 1'b1);
                expected_iso[d] = 1'b1;
                check(isolation_en == expected_iso, "power-down isolation order");
                check(domain_reset_n[d], "reset not asserted before isolation");
                wait (domain_reset_n[d] === 1'b0);
                expected_reset[d] = 1'b0;
                check(domain_reset_n == expected_reset, "power-down reset order");
                wait (power_switch_en[d] === 1'b0);
                expected_switch[d] = 1'b0;
                check(power_switch_en == expected_switch, "power-down switch order");
                latency = 1 + ($urandom(seed) % max_latency);
                wait_cycles(latency);
                power_good_async[d] <= 1'b0;
            end
            wait (done === 1'b1);
            check(!fault, "power-down completes without fault");
            check(power_switch_en == '0, "all switches disabled");
            check(isolation_en == {DOMAINS{1'b1}}, "all isolation asserted");
            check(domain_reset_n == '0, "all resets asserted");
            @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        cycle = cycle + 1;
        if (csv != 0 && cycle <= 200)
            $fwrite(csv, "%0d,%0d,%0d,%0d,%0h,%0h,%0h,%0h,%0d,%0d,%0d,%0d,%0d\n",
                    cycle, arst_n, cmd_valid, cmd_power_up,
                    power_good_async, power_switch_en,
                    isolation_en, domain_reset_n, state_debug,
                    busy, done, fault, fault_domain);
        if (arst_n) begin
            check(((~domain_reset_n) & (~isolation_en)) == '0,
                  "isolation may not be removed while reset is asserted");
            check((domain_reset_n & ~power_switch_en) == '0,
                  "released domain reset requires its power switch");
        end
    end

    initial begin
        $dumpfile("power_domain_sequencer.vcd");
        $dumpvars(0, tb_power_domain_sequencer);
        csv = $fopen("timing.csv", "w");
        $fwrite(csv, "cycle,arst_n,cmd_valid,cmd_power_up,power_good,power_switch,isolation,reset_n,state,busy,done,fault,fault_domain\n");

        repeat (3) @(posedge clk);
        arst_n <= 1'b1;
        repeat (3) @(posedge clk);
        check(cmd_ready, "controller ready after reset");
        check(power_switch_en == '0, "reset switch state");
        check(isolation_en == {DOMAINS{1'b1}}, "reset isolation state");
        check(domain_reset_n == '0, "reset domain state");

        golden_power_up(4);
        golden_power_down(4);

        // Directed timeout: domain 0 never reports power-good.
        issue_command(1'b1);
        wait (power_switch_en[0]);
        wait (fault);
        check(fault_domain == 0, "timeout identifies domain zero");
        check(!busy && !cmd_ready, "sticky fault blocks commands");
        check(!power_switch_en[0], "failed startup removes the switch request");

        clear_fault <= 1'b1;
        @(posedge clk);
        clear_fault <= 1'b0;
        @(posedge clk);
        check(!fault && cmd_ready, "fault clear restores readiness");

        // Randomized recovery run with variable power-good response times.
        golden_power_up(5);
        golden_power_down(5);

        check(checks > 150, "substantial check count");
        $display("Checks completed: %0d", checks);
        $display("RESULT: *** PASS ***");
        $fclose(csv);
        $finish;
    end

    initial begin
        #20000;
        $display("ERROR: simulation timeout");
        $fatal(1);
    end

endmodule
