// =============================================================================
// Day 34 : SHA-256 Cryptographic Hash Core (iterative, FIPS 180-4)
// -----------------------------------------------------------------------------
// A compact, synthesizable SHA-256 engine. It absorbs one 512-bit, ALREADY-
// PADDED message block per launch and folds it into a 256-bit running digest in
// a fixed, data-independent 66 clocks (1 load + 64 rounds + 1 feed-forward),
// chaining an arbitrary number of blocks (Merkle-Damgren construction) to hash a
// message of any length.
//
//   H := IV                                   (on the FIRST block)
//   for each 512-bit block M:
//       (a..h) := H                           (Davies-Meyer working state)
//       for t = 0..63:                        (64 compression rounds)
//           T1 = h + Sigma1(e) + Ch(e,f,g) + K[t] + W[t]
//           T2 = Sigma0(a) + Maj(a,b,c)
//           h=g; g=f; f=e; e=d+T1; d=c; c=b; b=a; a=T1+T2
//       H := H + (a..h)                        (feed-forward add)
//   digest = H
//
// THE HARDWARE STANDOUT is the message schedule. The 64 expanded words W[0..63]
// are NEVER stored as 64 registers: the core keeps a 16-word CIRCULAR WINDOW
// (w[0..15]) that shift-registers by one word per round. Round t consumes w[0]
// (== W[t]); in the same clock the recurrence
//       W[t+16] = sigma1(W[t+14]) + W[t+9] + sigma0(W[t+1]) + W[t]
//               = sigma1(w[14])   + w[9]   + sigma0(w[1])   + w[0]
// is evaluated combinationally and shifted into w[15]. So the whole schedule
// costs exactly 16 registers + one small adder cone, not a 2 Kbit W-RAM.
//
// Latency is OUTCOME-INDEPENDENT: every block takes the same 66 clocks (worst
// == typical), so there is no data-dependent timing side channel -- the property
// a MACsec / IPsec / TLS-record / HMAC / Bitcoin-style hashing datapath needs.
//
// The eight 32-bit hash registers H0..H7 do double duty: they hold the running
// (chaining) digest AND serve as the Davies-Meyer feed-forward input, so a fresh
// working state is loaded from them at each block and the final add commits back
// into them -- no separate feed-forward shadow copy required.
//
// STRICT: no vendor primitives, latch-free, `default_nettype none`.
// =============================================================================
`default_nettype none

module sha256_core #(
    parameter int unsigned NROUND = 64      // SHA-256: 64 rounds (do not change)
) (
    input  wire         clk,
    input  wire         rst_n,              // synchronous-use, active-low reset

    input  wire         start_i,            // 1-cycle pulse: latch block_i
    input  wire         first_i,            // 1 => reset chaining state to IV first
    input  wire [511:0] block_i,            // one 512-bit padded block (word0 = [511:480])

    output wire         busy_o,             // high while a block is in flight
    output reg          done_o,             // 1-cycle pulse when digest_o updated
    output reg          valid_o,            // sticky: digest_o holds a valid result
    output wire [255:0] digest_o            // running/final digest (H0..H7, H0 = MSBs)
);

    // ---- SHA-256 initial hash value (FIPS 180-4 sec 5.3.3) ------------------
    localparam logic [31:0] IV0 = 32'h6a09e667, IV1 = 32'hbb67ae85;
    localparam logic [31:0] IV2 = 32'h3c6ef372, IV3 = 32'ha54ff53a;
    localparam logic [31:0] IV4 = 32'h510e527f, IV5 = 32'h9b05688c;
    localparam logic [31:0] IV6 = 32'h1f83d9ab, IV7 = 32'h5be0cd19;

    // ---- combinational helper functions (pure GF(2)/mod-2^32 arithmetic) ----
    function automatic logic [31:0] rotr(input logic [31:0] x, input int n);
        rotr = (x >> n) | (x << (32 - n));
    endfunction
    // big-sigma (compression) and small-sigma (schedule) mixing functions
    function automatic logic [31:0] bsig0(input logic [31:0] x);
        bsig0 = rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
    endfunction
    function automatic logic [31:0] bsig1(input logic [31:0] x);
        bsig1 = rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
    endfunction
    function automatic logic [31:0] ssig0(input logic [31:0] x);
        ssig0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
    endfunction
    function automatic logic [31:0] ssig1(input logic [31:0] x);
        ssig1 = rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
    endfunction

    // ---- 64 SHA-256 round constants K[t] (FIPS 180-4 sec 4.2.2) -------------
    // first 32 bits of the fractional parts of the cube roots of the first 64
    // primes. Kept as a constant case (elaboration ROM) -> portable, no $readmem.
    function automatic logic [31:0] k_const(input logic [5:0] t);
        case (t)
            6'd00: k_const=32'h428a2f98; 6'd01: k_const=32'h71374491;
            6'd02: k_const=32'hb5c0fbcf; 6'd03: k_const=32'he9b5dba5;
            6'd04: k_const=32'h3956c25b; 6'd05: k_const=32'h59f111f1;
            6'd06: k_const=32'h923f82a4; 6'd07: k_const=32'hab1c5ed5;
            6'd08: k_const=32'hd807aa98; 6'd09: k_const=32'h12835b01;
            6'd10: k_const=32'h243185be; 6'd11: k_const=32'h550c7dc3;
            6'd12: k_const=32'h72be5d74; 6'd13: k_const=32'h80deb1fe;
            6'd14: k_const=32'h9bdc06a7; 6'd15: k_const=32'hc19bf174;
            6'd16: k_const=32'he49b69c1; 6'd17: k_const=32'hefbe4786;
            6'd18: k_const=32'h0fc19dc6; 6'd19: k_const=32'h240ca1cc;
            6'd20: k_const=32'h2de92c6f; 6'd21: k_const=32'h4a7484aa;
            6'd22: k_const=32'h5cb0a9dc; 6'd23: k_const=32'h76f988da;
            6'd24: k_const=32'h983e5152; 6'd25: k_const=32'ha831c66d;
            6'd26: k_const=32'hb00327c8; 6'd27: k_const=32'hbf597fc7;
            6'd28: k_const=32'hc6e00bf3; 6'd29: k_const=32'hd5a79147;
            6'd30: k_const=32'h06ca6351; 6'd31: k_const=32'h14292967;
            6'd32: k_const=32'h27b70a85; 6'd33: k_const=32'h2e1b2138;
            6'd34: k_const=32'h4d2c6dfc; 6'd35: k_const=32'h53380d13;
            6'd36: k_const=32'h650a7354; 6'd37: k_const=32'h766a0abb;
            6'd38: k_const=32'h81c2c92e; 6'd39: k_const=32'h92722c85;
            6'd40: k_const=32'ha2bfe8a1; 6'd41: k_const=32'ha81a664b;
            6'd42: k_const=32'hc24b8b70; 6'd43: k_const=32'hc76c51a3;
            6'd44: k_const=32'hd192e819; 6'd45: k_const=32'hd6990624;
            6'd46: k_const=32'hf40e3585; 6'd47: k_const=32'h106aa070;
            6'd48: k_const=32'h19a4c116; 6'd49: k_const=32'h1e376c08;
            6'd50: k_const=32'h2748774c; 6'd51: k_const=32'h34b0bcb5;
            6'd52: k_const=32'h391c0cb3; 6'd53: k_const=32'h4ed8aa4a;
            6'd54: k_const=32'h5b9cca4f; 6'd55: k_const=32'h682e6ff3;
            6'd56: k_const=32'h748f82ee; 6'd57: k_const=32'h78a5636f;
            6'd58: k_const=32'h84c87814; 6'd59: k_const=32'h8cc70208;
            6'd60: k_const=32'h90befffa; 6'd61: k_const=32'ha4506ceb;
            6'd62: k_const=32'hbef9a3f7; 6'd63: k_const=32'hc67178f2;
        endcase
    endfunction

    // ---- FSM ----------------------------------------------------------------
    localparam logic [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_FINAL = 2'd2;
    reg [1:0] state;
    reg [6:0] rnd;                              // round counter 0..63 (7b headroom)

    // running/chaining hash (also the Davies-Meyer feed-forward source)
    reg [31:0] h0, h1, h2, h3, h4, h5, h6, h7;
    // working variables a..h  (hh = 'h', avoids clashing with h4..h7 names)
    reg [31:0] a, b, c, d, e, f, g, hh;
    // 16-word circular message-schedule window: w[0] == W[current round]
    reg [31:0] w [0:15];

    integer i;

    assign busy_o   = (state != S_IDLE);
    assign digest_o = {h0, h1, h2, h3, h4, h5, h6, h7};

    // ---- per-round combinational datapath -----------------------------------
    wire [31:0] wt   = w[0];                                     // W[t]
    wire [31:0] t1   = hh + bsig1(e) + ((e & f) ^ (~e & g))      // Ch(e,f,g)
                          + k_const(rnd[5:0]) + wt;
    wire [31:0] t2   = bsig0(a) + ((a & b) ^ (a & c) ^ (b & c)); // Maj(a,b,c)
    // next schedule word to shift into w[15] (recurrence for W[t+16])
    wire [31:0] neww = ssig1(w[14]) + w[9] + ssig0(w[1]) + w[0];

    always @(posedge clk) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            rnd     <= 7'd0;
            done_o  <= 1'b0;
            valid_o <= 1'b0;
            {h0,h1,h2,h3,h4,h5,h6,h7} <= {IV0,IV1,IV2,IV3,IV4,IV5,IV6,IV7};
        end else begin
            done_o <= 1'b0;                     // default: 1-cycle pulse

            case (state)
                // -------------------------------------------------------------
                S_IDLE: begin
                    if (start_i) begin
                        // choose chaining state: IV for the first block, else
                        // the running digest held in h0..h7
                        if (first_i) begin
                            h0 <= IV0; h1 <= IV1; h2 <= IV2; h3 <= IV3;
                            h4 <= IV4; h5 <= IV5; h6 <= IV6; h7 <= IV7;
                            a  <= IV0; b  <= IV1; c  <= IV2; d  <= IV3;
                            e  <= IV4; f  <= IV5; g  <= IV6; hh <= IV7;
                        end else begin
                            a  <= h0; b  <= h1; c  <= h2; d  <= h3;
                            e  <= h4; f  <= h5; g  <= h6; hh <= h7;
                        end
                        // load the 512-bit block into the schedule window,
                        // word0 (M0) = block_i[511:480] = w[0]
                        for (i = 0; i < 16; i = i + 1)
                            w[i] <= block_i[511 - i*32 -: 32];
                        rnd   <= 7'd0;
                        state <= S_RUN;
                    end
                end
                // -------------------------------------------------------------
                S_RUN: begin
                    // one compression round
                    hh <= g;  g <= f;  f <= e;  e <= d + t1;
                    d  <= c;  c <= b;  b <= a;  a <= t1 + t2;
                    // shift the schedule window by one word
                    for (i = 0; i < 15; i = i + 1)
                        w[i] <= w[i+1];
                    w[15] <= neww;

                    if (rnd == 7'd63) state <= S_FINAL;
                    else              rnd   <= rnd + 7'd1;
                end
                // -------------------------------------------------------------
                S_FINAL: begin
                    // Davies-Meyer feed-forward add -> commit running digest
                    h0 <= h0 + a;  h1 <= h1 + b;  h2 <= h2 + c;  h3 <= h3 + d;
                    h4 <= h4 + e;  h5 <= h5 + f;  h6 <= h6 + g;  h7 <= h7 + hh;
                    done_o  <= 1'b1;
                    valid_o <= 1'b1;
                    state   <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
