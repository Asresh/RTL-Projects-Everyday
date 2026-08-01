// =============================================================================
// Day 33 : AES-128 Block-Cipher Encryption Core (iterative, FIPS-197)
// -----------------------------------------------------------------------------
// A compact, synthesizable AES-128 encryptor. One 128-bit block is enciphered
// in a fixed, data-independent 11 clocks (load + 10 rounds) with the round keys
// generated ON THE FLY (no 176-byte key-schedule RAM): every cycle the current
// round key is transformed into the next by RotWord/SubWord/Rcon, so the core
// stores exactly one 128-bit key register, not the whole expanded schedule.
//
//   round r (1..9) :  AddRoundKey( MixColumns( ShiftRows( SubBytes(state) ) ) )
//   round 10       :  AddRoundKey(             ShiftRows( SubBytes(state) )   )
//   pre-round      :  state = plaintext XOR key            (initial AddRoundKey)
//
// The datapath is a textbook round-transform built from four combinational
// primitives (SubBytes / ShiftRows / MixColumns / AddRoundKey) over GF(2^8) with
// the AES reduction polynomial x^8 + x^4 + x^3 + x + 1 (0x11B). Byte ordering
// follows FIPS-197: byte 0 of every 128-bit port lives in bits [127:120] and
// maps to state column 0, row 0; byte i -> state[row = i%4][col = i/4].
//
// Latency is OUTCOME-INDEPENDENT: every key/plaintext pair takes the same 11
// clocks (worst-case == typical), the property a line-rate MACsec / IPsec /
// self-encrypting-drive datapath needs.
//
// STRICT: no vendor primitives, latch-free, `default_nettype none`.
// =============================================================================
`default_nettype none

module aes128_enc #(
    parameter int unsigned NR = 10      // AES-128 : 10 rounds (do not change)
) (
    input  wire         clk,
    input  wire         rst_n,          // synchronous-use, active-low reset

    input  wire         start_i,        // 1-cycle pulse: latch key_i + pt_i
    input  wire [127:0] key_i,          // 128-bit cipher key   (byte0 = [127:120])
    input  wire [127:0] pt_i,           // 128-bit plaintext    (byte0 = [127:120])

    output wire         busy_o,         // high while a block is in flight
    output reg          done_o,         // 1-cycle pulse when ct_o is valid
    output reg          valid_o,        // sticky: ct_o holds a valid result
    output reg  [127:0] ct_o            // 128-bit ciphertext   (byte0 = [127:120])
);

    // -------------------------------------------------------------------------
    // AES S-box (FIPS-197 Fig. 7) as a packed 2048-bit constant, indexed by the
    // input byte. Synthesizes to a small ROM; the testbench proves every entry
    // by DERIVING the S-box from the GF(2^8) multiplicative inverse + affine
    // transform, independently of this table. Byte 0x00 is the leftmost slice.
    // (A packed constant is used instead of an unpacked-array parameter so the
    //  source elaborates on Icarus/Verilator as well as the big-3 simulators.)
    // -------------------------------------------------------------------------
    localparam logic [0:2047] SBOX = {
        8'h63,8'h7c,8'h77,8'h7b,8'hf2,8'h6b,8'h6f,8'hc5,8'h30,8'h01,8'h67,8'h2b,8'hfe,8'hd7,8'hab,8'h76,
        8'hca,8'h82,8'hc9,8'h7d,8'hfa,8'h59,8'h47,8'hf0,8'had,8'hd4,8'ha2,8'haf,8'h9c,8'ha4,8'h72,8'hc0,
        8'hb7,8'hfd,8'h93,8'h26,8'h36,8'h3f,8'hf7,8'hcc,8'h34,8'ha5,8'he5,8'hf1,8'h71,8'hd8,8'h31,8'h15,
        8'h04,8'hc7,8'h23,8'hc3,8'h18,8'h96,8'h05,8'h9a,8'h07,8'h12,8'h80,8'he2,8'heb,8'h27,8'hb2,8'h75,
        8'h09,8'h83,8'h2c,8'h1a,8'h1b,8'h6e,8'h5a,8'ha0,8'h52,8'h3b,8'hd6,8'hb3,8'h29,8'he3,8'h2f,8'h84,
        8'h53,8'hd1,8'h00,8'hed,8'h20,8'hfc,8'hb1,8'h5b,8'h6a,8'hcb,8'hbe,8'h39,8'h4a,8'h4c,8'h58,8'hcf,
        8'hd0,8'hef,8'haa,8'hfb,8'h43,8'h4d,8'h33,8'h85,8'h45,8'hf9,8'h02,8'h7f,8'h50,8'h3c,8'h9f,8'ha8,
        8'h51,8'ha3,8'h40,8'h8f,8'h92,8'h9d,8'h38,8'hf5,8'hbc,8'hb6,8'hda,8'h21,8'h10,8'hff,8'hf3,8'hd2,
        8'hcd,8'h0c,8'h13,8'hec,8'h5f,8'h97,8'h44,8'h17,8'hc4,8'ha7,8'h7e,8'h3d,8'h64,8'h5d,8'h19,8'h73,
        8'h60,8'h81,8'h4f,8'hdc,8'h22,8'h2a,8'h90,8'h88,8'h46,8'hee,8'hb8,8'h14,8'hde,8'h5e,8'h0b,8'hdb,
        8'he0,8'h32,8'h3a,8'h0a,8'h49,8'h06,8'h24,8'h5c,8'hc2,8'hd3,8'hac,8'h62,8'h91,8'h95,8'he4,8'h79,
        8'he7,8'hc8,8'h37,8'h6d,8'h8d,8'hd5,8'h4e,8'ha9,8'h6c,8'h56,8'hf4,8'hea,8'h65,8'h7a,8'hae,8'h08,
        8'hba,8'h78,8'h25,8'h2e,8'h1c,8'ha6,8'hb4,8'hc6,8'he8,8'hdd,8'h74,8'h1f,8'h4b,8'hbd,8'h8b,8'h8a,
        8'h70,8'h3e,8'hb5,8'h66,8'h48,8'h03,8'hf6,8'h0e,8'h61,8'h35,8'h57,8'hb9,8'h86,8'hc1,8'h1d,8'h9e,
        8'he1,8'hf8,8'h98,8'h11,8'h69,8'hd9,8'h8e,8'h94,8'h9b,8'h1e,8'h87,8'he9,8'hce,8'h55,8'h28,8'hdf,
        8'h8c,8'ha1,8'h89,8'h0d,8'hbf,8'he6,8'h42,8'h68,8'h41,8'h99,8'h2d,8'h0f,8'hb0,8'h54,8'hbb,8'h16
    };

    // Round constant Rcon[i] (low byte), i = 1..NR : {rc,24'b0} XORs into word 0.
    function automatic [7:0] rcon (input int i);
        logic [7:0] c;
        c = 8'h01;
        for (int k = 1; k < i; k++)
            c = c[7] ? ((c << 1) ^ 8'h1b) : (c << 1);
        return c;
    endfunction

    // -------------------------------------------------------------------------
    // Combinational round-transform helpers.
    // -------------------------------------------------------------------------
    function automatic [7:0] sbox (input [7:0] b);
        sbox = SBOX[b*8 +: 8];          // byte b -> its 8-bit slice
    endfunction

    // xtime : multiply by x (0x02) in GF(2^8) mod 0x11B
    function automatic [7:0] xtime (input [7:0] b);
        xtime = (b << 1) ^ (b[7] ? 8'h1b : 8'h00);
    endfunction

    // SubBytes : S-box every one of the 16 state bytes
    function automatic [127:0] sub_bytes (input [127:0] s);
        for (int i = 0; i < 16; i++)
            sub_bytes[i*8 +: 8] = sbox(s[i*8 +: 8]);
    endfunction

    // Byte accessor : FIPS byte index i (0 = MSB) -> [127-8i -: 8]
    function automatic [7:0] gb (input [127:0] s, input int i);
        gb = s[(15-i)*8 +: 8];
    endfunction

    // ShiftRows : row r cyclically left-rotated by r  (new[r+4c]=old[r+4((c+r)%4)])
    function automatic [127:0] shift_rows (input [127:0] s);
        logic [7:0] o [0:15];
        for (int c = 0; c < 4; c++) begin
            for (int r = 0; r < 4; r++) begin
                int src = r + 4*((c + r) % 4);
                o[r + 4*c] = gb(s, src);
            end
        end
        for (int i = 0; i < 16; i++)
            shift_rows[(15-i)*8 +: 8] = o[i];
    endfunction

    // MixColumns : per-column matrix multiply by the fixed AES polynomial
    function automatic [127:0] mix_columns (input [127:0] s);
        logic [7:0] a0, a1, a2, a3, b0, b1, b2, b3;
        for (int c = 0; c < 4; c++) begin
            a0 = gb(s, 4*c+0); a1 = gb(s, 4*c+1);
            a2 = gb(s, 4*c+2); a3 = gb(s, 4*c+3);
            b0 = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;         // 2 3 1 1
            b1 = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;         // 1 2 3 1
            b2 = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);         // 1 1 2 3
            b3 = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);         // 3 1 1 2
            mix_columns[(15-(4*c+0))*8 +: 8] = b0;
            mix_columns[(15-(4*c+1))*8 +: 8] = b1;
            mix_columns[(15-(4*c+2))*8 +: 8] = b2;
            mix_columns[(15-(4*c+3))*8 +: 8] = b3;
        end
    endfunction

    // One key-expansion step : W[4k..4k+3] from W[4k-4..4k-1] + Rcon[k]
    function automatic [127:0] key_expand (input [127:0] k, input [7:0] rc);
        logic [31:0] w0, w1, w2, w3, t, n0, n1, n2, n3;
        w0 = k[127:96]; w1 = k[95:64]; w2 = k[63:32]; w3 = k[31:0];
        // t = SubWord(RotWord(w3)) ^ {rc,24'b0}
        t = {w3[23:0], w3[31:24]};                               // RotWord
        t = {sbox(t[31:24]), sbox(t[23:16]), sbox(t[15:8]), sbox(t[7:0])};
        t = t ^ {rc, 24'h000000};
        n0 = w0 ^ t;
        n1 = w1 ^ n0;
        n2 = w2 ^ n1;
        n3 = w3 ^ n2;
        key_expand = {n0, n1, n2, n3};
    endfunction

    // -------------------------------------------------------------------------
    // Iterative datapath : one round per clock, keys generated on the fly.
    // -------------------------------------------------------------------------
    localparam int unsigned RCW = $clog2(NR + 1);

    reg  [127:0]     state_r;            // running cipher state
    reg  [127:0]     key_r;              // current round key
    reg  [RCW-1:0]   round_r;            // 1..NR while active, 0 = idle
    reg              busy_r;

    assign busy_o = busy_r;

    // combinational next-round computation
    wire [127:0] sb    = sub_bytes(state_r);
    wire [127:0] sr    = shift_rows(sb);
    wire         lastr = (round_r == NR[RCW-1:0]);
    wire [127:0] body  = lastr ? sr : mix_columns(sr);
    wire [127:0] rk    = key_expand(key_r, rcon(round_r));
    wire [127:0] nstate = body ^ rk;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r <= '0;
            key_r   <= '0;
            round_r <= '0;
            busy_r  <= 1'b0;
            done_o  <= 1'b0;
            valid_o <= 1'b0;
            ct_o    <= '0;
        end else begin
            done_o <= 1'b0;             // default: one-cycle pulse
            if (!busy_r) begin
                if (start_i) begin
                    state_r <= pt_i ^ key_i;   // initial AddRoundKey (W0 = key)
                    key_r   <= key_i;
                    round_r <= {{(RCW-1){1'b0}}, 1'b1};
                    busy_r  <= 1'b1;
                    valid_o <= 1'b0;
                end
            end else begin
                state_r <= nstate;
                key_r   <= rk;
                if (lastr) begin
                    ct_o    <= nstate;
                    done_o  <= 1'b1;
                    valid_o <= 1'b1;
                    busy_r  <= 1'b0;
                    round_r <= '0;
                end else begin
                    round_r <= round_r + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
