// ---------------------------------------------------------------------------
// Day 29 : Self-checking testbench for oe_egress_serializer
// ---------------------------------------------------------------------------
// Strategy
//   * An INDEPENDENT golden model (gmodel) re-assembles the expected big-endian
//     wire frame + XOR checksum for every descriptor and pushes {byte,last}
//     onto reference queues.
//   * A byte SINK samples the egress bus every clock, applies RANDOM backpressure
//     on m_ready, and on each accepted beat pops the reference queue and checks
//     data, last-flag position, and (implicitly) the checksum trailer.
//   * Directed corners + 300 randomized orders under random stalls, a global
//     timeout watchdog, and a VCD dump.
// Prints "RESULT: *** PASS ***" only if every byte check passes and the exact
// expected number of bytes was drained.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_oe_egress_serializer;

    // fixed instance widths (defaults)
    localparam int TOKEN_W = 32, PRICE_W = 32, QTY_W = 32, SYM_W = 16;
    localparam logic [7:0] MSG_TYPE = 8'h4F, SIDE_BUY = 8'h42, SIDE_SELL = 8'h53;
    localparam int BODY_BYTES  = 1 + TOKEN_W/8 + 1 + PRICE_W/8 + QTY_W/8 + SYM_W/8; // 16
    localparam int TOTAL_BYTES = BODY_BYTES + 1;                                     // 17

    // ---- DUT I/O -----------------------------------------------------------
    logic                 clk = 1'b0, rst = 1'b1;
    logic                 in_valid = 1'b0;
    wire                  in_ready;
    logic [TOKEN_W-1:0]   token_i  = '0;
    logic                 side_i   = 1'b0;
    logic [PRICE_W-1:0]   price_i  = '0;
    logic [QTY_W-1:0]     shares_i = '0;
    logic [SYM_W-1:0]     symbol_i = '0;
    wire                  m_valid;
    logic                 m_ready  = 1'b0;
    wire  [7:0]           m_data;
    wire                  m_last;

    oe_egress_serializer #(
        .TOKEN_W(TOKEN_W), .PRICE_W(PRICE_W), .QTY_W(QTY_W), .SYM_W(SYM_W)
    ) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_ready(in_ready),
        .token_i(token_i), .side_i(side_i), .price_i(price_i),
        .shares_i(shares_i), .symbol_i(symbol_i),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data), .m_last(m_last)
    );

    // ---- clock -------------------------------------------------------------
    always #5 clk = ~clk;

    // ---- reference queues + bookkeeping -----------------------------------
    byte unsigned exp_byte [$];
    bit           exp_last [$];
    int           checks   = 0;
    int           errors   = 0;
    int           issued   = 0;
    int           bytes_pushed = 0;

    // Independent golden assembler: push one frame's {byte,last} pairs.
    task automatic gmodel(input logic [31:0] token, input logic side,
                          input logic [31:0] price, input logic [31:0] shares,
                          input logic [15:0] symbol);
        byte unsigned b [TOTAL_BYTES];
        byte unsigned cs;
        int p;
        begin
            b[0] = MSG_TYPE;
            b[1] = token[31:24]; b[2] = token[23:16]; b[3] = token[15:8]; b[4] = token[7:0];
            b[5] = side ? SIDE_SELL : SIDE_BUY;
            b[6] = price[31:24]; b[7] = price[23:16]; b[8] = price[15:8]; b[9] = price[7:0];
            b[10]= shares[31:24];b[11]= shares[23:16];b[12]= shares[15:8];b[13]= shares[7:0];
            b[14]= symbol[15:8]; b[15]= symbol[7:0];
            cs = 8'h00;
            for (p = 0; p < BODY_BYTES; p++) cs = cs ^ b[p];
            b[16] = cs;
            for (p = 0; p < TOTAL_BYTES; p++) begin
                exp_byte.push_back(b[p]);
                exp_last.push_back(p == TOTAL_BYTES-1);
                bytes_pushed++;
            end
        end
    endtask

    // Driver: present one descriptor, push its golden frame, let it be accepted.
    task automatic send(input logic [31:0] token, input logic side,
                        input logic [31:0] price, input logic [31:0] shares,
                        input logic [15:0] symbol);
        begin
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            in_valid <= 1'b1;
            token_i  <= token; side_i <= side; price_i <= price;
            shares_i <= shares; symbol_i <= symbol;
            gmodel(token, side, price, shares, symbol);   // push expected first
            @(posedge clk);                               // <-- accepting edge
            @(negedge clk);
            in_valid <= 1'b0;
            issued++;
        end
    endtask

    // ---- SINK : random backpressure + per-beat checking --------------------
    // Read m_valid/m_ready/m_data/m_last at the edge (pre-NBA), then choose the
    // next m_ready. This matches the beat the DUT consumes at this same edge.
    always @(posedge clk) begin
        if (!rst) begin
            if (m_valid && m_ready) begin
                byte unsigned eb; bit el;
                if (exp_byte.size() == 0) begin
                    errors++;
                    $error("[%0t] egress produced a byte with EMPTY reference queue (data=%02x)", $time, m_data);
                end else begin
                    eb = exp_byte.pop_front();
                    el = exp_last.pop_front();
                    checks++;
                    if (m_data !== eb) begin
                        errors++;
                        $error("[%0t] byte mismatch: got %02x exp %02x (check #%0d)", $time, m_data, eb, checks);
                    end
                    if (m_last !== el) begin
                        errors++;
                        $error("[%0t] last mismatch: got %0b exp %0b at check #%0d (data %02x)", $time, m_last, el, checks, m_data);
                    end
                end
            end
        end
        // choose next-cycle ready: ~75% ready => exercises stalls & full-skid
        m_ready <= (($urandom % 4) != 0);
    end

    // ---- stimulus ----------------------------------------------------------
    initial begin
        int i;
        logic [31:0] tok, prc, shr;
        logic [15:0] sym;
        logic        sd;

        $dumpfile("oe_egress_serializer.vcd");
        $dumpvars(0, tb_oe_egress_serializer);

        // reset
        rst = 1'b1; m_ready = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk); rst = 1'b0;

        // ---- directed corners ---------------------------------------------
        send(32'h0000_0000, 1'b0, 32'h0000_0000, 32'h0000_0000, 16'h0000); // all-zero, buy
        send(32'hFFFF_FFFF, 1'b1, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 16'hFFFF); // all-ones, sell
        send(32'hDEAD_BEEF, 1'b0, 32'h0001_86A0, 32'h0000_0064, 16'h00AA); // typical buy 100@100000
        send(32'h1234_5678, 1'b1, 32'h7FFF_FFFF, 32'h8000_0000, 16'h00FF); // max price, MSB qty, sell
        send(32'hA5A5_A5A5, 1'b0, 32'h5A5A_5A5A, 32'hA5A5_A5A5, 16'h5A5A); // alternating pattern
        send(32'h0000_0001, 1'b1, 32'h0000_0001, 32'h0000_0001, 16'h0001); // unit fields
        send(32'hCAFE_F00D, 1'b0, 32'h0000_FFFF, 32'hFFFF_0000, 16'hBEEF); // split
        send(32'h8000_0000, 1'b1, 32'h0000_0000, 32'hFFFF_FFFF, 16'h8000); // sign corners

        // ---- randomized burst under random backpressure -------------------
        for (i = 0; i < 300; i++) begin
            tok = {$urandom};
            prc = {$urandom};
            shr = {$urandom};
            sym = $urandom;
            sd  = $urandom & 1'b1;
            send(tok, sd, prc, shr, sym);
        end

        // let the pipeline fully drain
        while (exp_byte.size() != 0) @(posedge clk);
        repeat (8) @(posedge clk);

        // ---- final scoreboard ---------------------------------------------
        $display("--------------------------------------------------------");
        $display("orders issued : %0d", issued);
        $display("bytes expected: %0d", bytes_pushed);
        $display("byte checks   : %0d", checks);
        $display("errors        : %0d", errors);
        $display("residual queue: %0d", exp_byte.size());
        if (errors == 0 && checks == bytes_pushed && exp_byte.size() == 0 &&
            issued == 308 && checks == 308*TOTAL_BYTES) begin
            $display("RESULT: *** PASS ***");
        end else begin
            $display("RESULT: *** FAIL ***");
        end
        $display("--------------------------------------------------------");
        $finish;
    end

    // ---- timeout watchdog --------------------------------------------------
    initial begin
        #2_000_000;
        $display("RESULT: *** FAIL *** (TIMEOUT)");
        $finish;
    end

endmodule

`default_nettype wire
