`timescale 1ns/1ps
`default_nettype none

module tb_sparse_dot2of4;
    localparam int GROUPS = 4;
    localparam int DW     = 8;
    localparam int PROD_W = 2 * DW;
    localparam int SUM_W  = PROD_W + $clog2(2 * GROUPS) + 1;
    localparam int LATENCY = 3;
    localparam int MAX_CYCLES = 5000;

    logic clk;
    logic rst_n;
    logic in_valid;
    logic [GROUPS*4*DW-1:0] dense_a;
    logic [GROUPS*2*DW-1:0] sparse_w;
    logic [GROUPS*4-1:0] meta;
    wire out_valid;
    wire signed [SUM_W-1:0] dot_product;
    wire meta_error;

    sparse_dot2of4 #(.GROUPS(GROUPS), .DW(DW)) dut (.*);

    integer cycle;
    integer tests;
    integer errors;
    integer seed;
    logic due_valid [0:MAX_CYCLES-1];
    logic due_error [0:MAX_CYCLES-1];
    logic signed [SUM_W-1:0] due_value [0:MAX_CYCLES-1];

    always #5 clk = ~clk;

    task automatic golden_model(
        input  logic [GROUPS*4*DW-1:0] a_bus,
        input  logic [GROUPS*2*DW-1:0] w_bus,
        input  logic [GROUPS*4-1:0]    m_bus,
        output logic signed [SUM_W-1:0] answer,
        output logic                    bad_meta
    );
        integer gg;
        integer ii0;
        integer ii1;
        integer signed aa0;
        integer signed aa1;
        integer signed ww0;
        integer signed ww1;
        longint signed total;
        begin
            total = 0;
            bad_meta = 1'b0;
            for (gg = 0; gg < GROUPS; gg = gg + 1) begin
                ii0 = m_bus[gg*4 +: 2];
                ii1 = m_bus[gg*4+2 +: 2];
                if (ii0 == ii1) begin
                    bad_meta = 1'b1;
                end else begin
                    aa0 = $signed(a_bus[(4*gg+ii0)*DW +: DW]);
                    aa1 = $signed(a_bus[(4*gg+ii1)*DW +: DW]);
                    ww0 = $signed(w_bus[(2*gg)*DW +: DW]);
                    ww1 = $signed(w_bus[(2*gg+1)*DW +: DW]);
                    total = total + aa0*ww0 + aa1*ww1;
                end
            end
            answer = total[SUM_W-1:0];
        end
    endtask

    task automatic drive_fragment(
        input logic [GROUPS*4*DW-1:0] a_bus,
        input logic [GROUPS*2*DW-1:0] w_bus,
        input logic [GROUPS*4-1:0]    m_bus
    );
        begin
            @(negedge clk);
            in_valid = 1'b1;
            dense_a  = a_bus;
            sparse_w = w_bus;
            meta     = m_bus;
        end
    endtask

    task automatic drive_bubble;
        begin
            @(negedge clk);
            in_valid = 1'b0;
            dense_a  = '0;
            sparse_w = '0;
            meta     = '0;
        end
    endtask

    logic signed [SUM_W-1:0] model_value;
    logic model_error;
    integer i;

    // Independent cycle-due scoreboard. Inputs are sampled at a rising edge;
    // their result must emerge exactly LATENCY rising edges later.
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (rst_n && in_valid) begin
            golden_model(dense_a, sparse_w, meta, model_value, model_error);
            due_valid[cycle + LATENCY] = 1'b1;
            due_value[cycle + LATENCY] = model_value;
            due_error[cycle + LATENCY] = model_error;
            tests = tests + 1;
        end

        #1;
        if (rst_n) begin
            if (out_valid !== due_valid[cycle]) begin
                $display("ERROR cycle %0d: out_valid=%b expected=%b",
                         cycle, out_valid, due_valid[cycle]);
                errors = errors + 1;
            end
            if (out_valid) begin
                if (dot_product !== due_value[cycle]) begin
                    $display("ERROR cycle %0d: dot=%0d expected=%0d",
                             cycle, $signed(dot_product), $signed(due_value[cycle]));
                    errors = errors + 1;
                end
                if (meta_error !== due_error[cycle]) begin
                    $display("ERROR cycle %0d: meta_error=%b expected=%b",
                             cycle, meta_error, due_error[cycle]);
                    errors = errors + 1;
                end
            end
        end
    end

    logic [GROUPS*4*DW-1:0] a_vec;
    logic [GROUPS*2*DW-1:0] w_vec;
    logic [GROUPS*4-1:0] m_vec;
    integer g;
    integer lane;
    integer idx_a;
    integer idx_b;
    integer rv;

    initial begin
        $dumpfile("sparse_dot2of4.vcd");
        $dumpvars(0, tb_sparse_dot2of4);

        clk = 1'b0;
        rst_n = 1'b0;
        in_valid = 1'b0;
        dense_a = '0;
        sparse_w = '0;
        meta = '0;
        cycle = 0;
        tests = 0;
        errors = 0;
        seed = 32'h2f4a_2026;
        for (i = 0; i < MAX_CYCLES; i = i + 1) begin
            due_valid[i] = 1'b0;
            due_error[i] = 1'b0;
            due_value[i] = '0;
        end

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // Directed 1: all selected activations and weights are +1 => 8.
        a_vec = '0; w_vec = '0; m_vec = '0;
        for (g = 0; g < GROUPS; g = g + 1) begin
            for (lane = 0; lane < 4; lane = lane + 1)
                a_vec[(4*g+lane)*DW +: DW] = 8'sd1;
            w_vec[(2*g)*DW +: DW] = 8'sd1;
            w_vec[(2*g+1)*DW +: DW] = 8'sd1;
            m_vec[g*4 +: 2] = 2'd0;
            m_vec[g*4+2 +: 2] = 2'd3;
        end
        drive_fragment(a_vec, w_vec, m_vec);

        // Directed 2: signed extremes and different index pairs per group.
        a_vec = '0; w_vec = '0; m_vec = '0;
        for (g = 0; g < GROUPS; g = g + 1) begin
            a_vec[(4*g)*DW +: DW]   = -8'sd128;
            a_vec[(4*g+1)*DW +: DW] =  8'sd127;
            a_vec[(4*g+2)*DW +: DW] = -8'sd3;
            a_vec[(4*g+3)*DW +: DW] =  8'sd5;
            w_vec[(2*g)*DW +: DW]   = -8'sd128;
            w_vec[(2*g+1)*DW +: DW] =  8'sd127;
            m_vec[g*4 +: 2]         = g[1:0];
            m_vec[g*4+2 +: 2]       = (3-g);
        end
        drive_fragment(a_vec, w_vec, m_vec);

        // Directed 3: duplicate indices flag malformed metadata and suppress
        // only the bad group's contribution; the other groups remain valid.
        m_vec[4 +: 2] = 2'd2;
        m_vec[6 +: 2] = 2'd2;
        drive_fragment(a_vec, w_vec, m_vec);
        drive_bubble();

        // Randomized back-to-back traffic with bubbles and ~12.5% bad groups.
        for (i = 0; i < 1000; i = i + 1) begin
            a_vec = '0; w_vec = '0; m_vec = '0;
            for (g = 0; g < GROUPS; g = g + 1) begin
                for (lane = 0; lane < 4; lane = lane + 1) begin
                    rv = $urandom(seed);
                    a_vec[(4*g+lane)*DW +: DW] = rv[DW-1:0];
                end
                rv = $urandom(seed);
                w_vec[(2*g)*DW +: DW] = rv[DW-1:0];
                rv = $urandom(seed);
                w_vec[(2*g+1)*DW +: DW] = rv[DW-1:0];
                idx_a = $urandom(seed) % 4;
                if (($urandom(seed) % 8) == 0)
                    idx_b = idx_a;
                else begin
                    idx_b = $urandom(seed) % 3;
                    if (idx_b >= idx_a)
                        idx_b = idx_b + 1;
                end
                m_vec[g*4 +: 2] = idx_a[1:0];
                m_vec[g*4+2 +: 2] = idx_b[1:0];
            end
            if (($urandom(seed) % 5) == 0)
                drive_bubble();
            else
                drive_fragment(a_vec, w_vec, m_vec);
        end

        // Drain the pipeline.
        repeat (LATENCY + 3) drive_bubble();
        if (errors == 0) begin
            $display("Fragments checked: %0d", tests);
            $display("RESULT: *** PASS ***");
        end else begin
            $display("Fragments checked: %0d", tests);
            $display("Errors: %0d", errors);
            $display("RESULT: *** FAIL ***");
            $fatal(1);
        end
        $finish;
    end

    initial begin
        #1000000;
        $display("RESULT: *** FAIL *** (timeout)");
        $fatal(1);
    end
endmodule

`default_nettype wire
