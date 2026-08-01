// ============================================================================
// Day 32 : Parameterized Reed-Solomon RS(n, k) Systematic Encoder over GF(2^M)
// ----------------------------------------------------------------------------
// A streaming, systematic Reed-Solomon encoder.  For each block of K message
// symbols it appends 2*T parity symbols so the resulting N = K + 2*T symbol
// codeword is a multiple of the generator polynomial
//
//     g(x) = PROD_{i=0}^{2T-1} ( x - alpha^(FCR + i) )        (degree 2T, monic)
//
// which is exactly the condition that guarantees the code can correct up to T
// symbol errors (and detect 2T erasures).  Systematic means the K message
// symbols pass through unchanged and are simply followed by the 2T parity
// symbols -- the decoder recovers the payload directly when there are no errors.
//
// Everything about the finite field GF(2^M) -- the arithmetic AND the generator
// polynomial coefficients -- is derived at ELABORATION time from the parameters
// by constant SystemVerilog functions.  Change M / T / K / the primitive
// polynomial and the whole datapath (field size, number of parity taps, the tap
// constants themselves) re-derives itself.  There are no hand-coded lookup
// tables.
//
//   * GF(2^M) multiply : synthesizable shift-and-reduce ("Russian peasant")
//                        cone using the primitive polynomial PRIM.
//   * Generator g(x)   : built at elaboration by iteratively multiplying the
//                        monomials (x - alpha^(FCR+i)) in GF(2^M).
//   * Encoder core     : a length-2T LFSR (polynomial-division circuit) that
//                        streams the systematic codeword, message-first, at one
//                        symbol/clock; the 2T remainder registers are the parity.
//
// Reset-safe, latch-free, registered outputs.  Default parameters give a
// shortened RS(16, 8) over GF(256) (poly 0x11D) that corrects T = 4 symbol
// errors; the same source elaborates to DVB's RS(255, 239) with K = 239,T = 8.
// ============================================================================
`default_nettype none

module rs_encoder #(
    parameter int unsigned M    = 8,        // symbol width : field is GF(2^M)
    parameter int unsigned T    = 4,        // correction power -> P = 2*T parity syms
    parameter int unsigned K    = 8,        // message symbols per codeword block
    parameter int unsigned PRIM = 'h11D,    // primitive polynomial (bit M is set)
    parameter int unsigned FCR  = 0,        // first consecutive root exponent
    parameter int unsigned ALG  = 2         // primitive element alpha (x == 2)
) (
    input  wire                 clk,
    input  wire                 rst,        // synchronous, active-high

    input  wire                 start_i,    // pulse: begin a fresh codeword block
    input  wire                 msg_valid_i,// a message symbol is offered this clk
    input  wire [M-1:0]         msg_data_i, // message symbol (payload), MSB-symbol first

    output wire                 msg_ready_o,// encoder is in the message-accept phase

    // Systematic codeword stream (registered): K message symbols, then P parity.
    output reg                  cw_valid_o,
    output reg  [M-1:0]         cw_data_o,
    output reg                  cw_is_parity_o, // 0 = payload symbol, 1 = parity symbol
    output reg                  cw_last_o,      // asserted on the final (Nth) symbol

    // Parallel view of the parity block, valid from the first parity beat to done.
    output reg  [2*T*M-1:0]     par_flat_o,     // symbol i occupies [i*M +: M]
    output reg                  par_valid_o,

    output reg                  busy_o,     // a block is in flight
    output reg                  done_o      // 1-clk pulse when the codeword completes
);

    // ---- derived sizes ------------------------------------------------------
    localparam int unsigned P    = 2*T;             // number of parity symbols
    localparam int unsigned N    = K + P;           // codeword length in symbols
    localparam int unsigned CW_W = (K > P) ? K : P; // wide enough symbol counter
    localparam int unsigned CB   = (CW_W <= 1) ? 1 : $clog2(CW_W + 1);

    // ========================================================================
    // GF(2^M) arithmetic -- pure combinational, parameter-general.
    // ========================================================================
    // Multiply two field elements: for each bit of b, conditionally add (XOR) a
    // shifted-and-reduced copy of a.  Reduction folds in PRIM whenever the top
    // bit would overflow past x^(M-1).  Works for any M and any primitive PRIM.
    function automatic [M-1:0] gf_mul(input [M-1:0] a, input [M-1:0] b);
        integer      i;
        reg [M-1:0]  prod;
        reg [M-1:0]  acc;
        begin
            prod = {M{1'b0}};
            acc  = a;
            for (i = 0; i < M; i = i + 1) begin
                if (b[i]) prod = prod ^ acc;
                if (acc[M-1]) acc = (acc << 1) ^ PRIM[M-1:0];
                else          acc = (acc << 1);
            end
            gf_mul = prod;
        end
    endfunction

    // alpha raised to an integer power in GF(2^M) (used only at elaboration).
    function automatic [M-1:0] gf_pow(input [M-1:0] base, input integer e);
        integer      i;
        reg [M-1:0]  r;
        begin
            r = {{(M-1){1'b0}}, 1'b1};              // GF one
            for (i = 0; i < e; i = i + 1)
                r = gf_mul(r, base);
            gf_pow = r;
        end
    endfunction

    // ========================================================================
    // Generator polynomial g(x) = PROD (x - alpha^(FCR+i)), built at elaboration.
    // Returned flat: coefficient of x^i occupies bits [i*M +: M]; g[P] == 1.
    // ========================================================================
    function automatic [(P+1)*M-1:0] gen_poly();
        integer               i, j;
        reg [M-1:0]           g   [0:P];
        reg [M-1:0]           root;
        reg [(P+1)*M-1:0]     flat;
        begin
            for (i = 0; i <= P; i = i + 1) g[i] = {M{1'b0}};
            g[0] = {{(M-1){1'b0}}, 1'b1};           // start with g(x) = 1
            // multiply the running polynomial (currently degree i) by (x + root)
            for (i = 0; i < P; i = i + 1) begin
                root = gf_pow(ALG[M-1:0], FCR + i);
                for (j = i + 1; j > 0; j = j - 1)
                    g[j] = g[j-1] ^ gf_mul(g[j], root);
                g[0] = gf_mul(g[0], root);
            end
            for (i = 0; i <= P; i = i + 1)
                flat[i*M +: M] = g[i];
            gen_poly = flat;
        end
    endfunction

    localparam [(P+1)*M-1:0] GPOLY = gen_poly();

    // pick tap g[j] (0 <= j < P) out of the flat generator constant.
    function automatic [M-1:0] gtap(input integer j);
        gtap = GPOLY[j*M +: M];
    endfunction

    // ========================================================================
    // Control FSM
    // ========================================================================
    localparam logic [1:0] S_IDLE = 2'd0,   // waiting for start_i
                           S_MSG  = 2'd1,   // absorbing K message symbols
                           S_PAR  = 2'd2;   // shifting out P parity symbols

    reg [1:0]      state;
    reg [CB-1:0]   cnt;                      // symbols processed in current phase

    // 2T-symbol LFSR remainder registers (the parity accumulator).
    reg [M-1:0]    lfsr [0:P-1];

    // combinational next-state of the LFSR when a message symbol is absorbed.
    reg [M-1:0]    lfsr_nx [0:P-1];
    reg [M-1:0]    fb;                       // feedback term = data XOR top register
    integer        j;

    always @* begin
        fb = msg_data_i ^ lfsr[P-1];
        // b[j] <= b[j-1] ^ (fb * g[j]);   b[0] <= fb * g[0]
        lfsr_nx[0] = gf_mul(fb, gtap(0));
        for (j = 1; j < P; j = j + 1)
            lfsr_nx[j] = lfsr[j-1] ^ gf_mul(fb, gtap(j));
    end

    assign msg_ready_o = (state == S_MSG);

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            cnt            <= '0;
            cw_valid_o     <= 1'b0;
            cw_data_o      <= '0;
            cw_is_parity_o <= 1'b0;
            cw_last_o      <= 1'b0;
            par_valid_o    <= 1'b0;
            par_flat_o     <= '0;
            busy_o         <= 1'b0;
            done_o         <= 1'b0;
            for (k = 0; k < P; k = k + 1) lfsr[k] <= '0;
        end else begin
            // default single-cycle strobes
            cw_valid_o <= 1'b0;
            cw_last_o  <= 1'b0;
            done_o     <= 1'b0;

            case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    if (start_i) begin
                        for (k = 0; k < P; k = k + 1) lfsr[k] <= '0;
                        cnt         <= '0;
                        busy_o      <= 1'b1;
                        par_valid_o <= 1'b0;
                        state       <= S_MSG;
                    end
                end
                // --------------------------------------------------------
                S_MSG: begin
                    if (msg_valid_i) begin
                        // absorb symbol into the divider, pass it through
                        for (k = 0; k < P; k = k + 1) lfsr[k] <= lfsr_nx[k];
                        cw_valid_o     <= 1'b1;
                        cw_data_o      <= msg_data_i;
                        cw_is_parity_o <= 1'b0;
                        cnt            <= cnt + 1'b1;
                        if (cnt == CB'(K-1)) begin
                            // that was the last message symbol -> emit parity next
                            cnt   <= '0;
                            state <= S_PAR;
                        end
                    end
                end
                // --------------------------------------------------------
                S_PAR: begin
                    // parity emitted highest-degree first: b[P-1] .. b[0]
                    cw_valid_o     <= 1'b1;
                    cw_is_parity_o <= 1'b1;
                    cw_data_o      <= lfsr[P-1 - cnt];
                    if (cnt == 0) begin
                        // publish the whole parity block in parallel
                        for (k = 0; k < P; k = k + 1)
                            par_flat_o[k*M +: M] <= lfsr[k];
                        par_valid_o <= 1'b1;
                    end
                    if (cnt == CB'(P-1)) begin
                        cw_last_o <= 1'b1;
                        done_o    <= 1'b1;
                        busy_o    <= 1'b0;
                        state     <= S_IDLE;
                    end
                    cnt <= cnt + 1'b1;
                end
                // --------------------------------------------------------
                default: state <= S_IDLE;
            endcase
        end
    end

`ifdef RS_DUMP_GEN
    // elaboration-time visibility of the derived generator (simulation only)
    initial begin
        integer d;
        $display("[rs_encoder] GF(2^%0d) prim=0x%0h  RS(%0d,%0d) T=%0d  P=%0d parity",
                 M, PRIM, N, K, T, P);
        for (d = 0; d <= P; d = d + 1)
            $display("            g[%0d] = 0x%0h", d, GPOLY[d*M +: M]);
    end
`endif

endmodule

`default_nettype wire
