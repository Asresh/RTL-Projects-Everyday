// ============================================================================
//  i2c_master.sv
//  Day 8 - RTL Projects Everyday
//
//  Single-master I2C controller for one-byte read / write transactions to a
//  7-bit-addressed slave.  The core drives the bus as a true open-drain
//  master: it never forces a line high, it only pulls low (via *_oe) or
//  releases (line pulled up externally).  It samples SCL back in so that a
//  slave holding SCL low (clock stretching) transparently pauses the master.
//
//  Bit timing uses the classic 4-phase-per-bit scheme derived from the
//  system clock:
//
//        phase:   0        1        2        3
//        SCL  :  ___low___|___low___|__high___|__high__
//                 setup     hold     sample    hold
//        SDA changes while SCL is low (phase 0), is sampled while SCL is high.
//
//  START = SDA 1->0 while SCL high.   STOP = SDA 0->1 while SCL high.
//
//  Author: Asresh Kuricheti
// ============================================================================
`default_nettype none

module i2c_master #(
    // System clock and desired SCL frequency.  QUARTER = system clocks per
    // phase; the SCL period is 4*QUARTER system clocks.
    parameter int CLK_FREQ_HZ = 2_000_000,
    parameter int SCL_FREQ_HZ =   100_000
) (
    input  wire        clk,
    input  wire        rst_n,

    // ---- command interface -------------------------------------------------
    input  wire        start,      // 1-cycle pulse: latch a new transaction
    input  wire        rw,         // 0 = write wr_data, 1 = read one byte
    input  wire [6:0]  addr,       // 7-bit slave address
    input  wire [7:0]  wr_data,    // byte to transmit on a write
    output logic [7:0] rd_data,    // byte received on a read (valid at done)
    output logic       busy,       // high for the whole transaction
    output logic       done,       // 1-cycle pulse when the transaction ends
    output logic       ack_error,  // latched: a required ACK was missing (NACK)

    // ---- open-drain bus (resolve externally with pull-ups) ------------------
    input  wire        scl_i,      // sampled SCL (for clock stretching)
    output logic       scl_oe,     // 1 = pull SCL low, 0 = release SCL
    input  wire        sda_i,      // sampled SDA
    output logic       sda_oe      // 1 = pull SDA low, 0 = release SDA
);

    // ------------------------------------------------------------------------
    //  Timing: QUARTER system clocks per phase.
    // ------------------------------------------------------------------------
    localparam int QUARTER = (CLK_FREQ_HZ / (4 * SCL_FREQ_HZ) < 1)
                             ? 1 : CLK_FREQ_HZ / (4 * SCL_FREQ_HZ);
    localparam int QW      = (QUARTER <= 1) ? 1 : $clog2(QUARTER);

    // ------------------------------------------------------------------------
    //  FSM states.
    // ------------------------------------------------------------------------
    typedef enum logic [3:0] {
        S_IDLE,      // bus released, waiting for a command
        S_START,     // drive START condition
        S_ADDR,      // shift out {addr, rw}
        S_ADDR_ACK,  // release SDA, sample slave ACK
        S_WR,        // shift out wr_data
        S_WR_ACK,    // sample slave ACK for the written byte
        S_RD,        // shift in a byte from the slave
        S_RD_ACK,    // master sends NACK (single-byte read)
        S_STOP,      // drive STOP condition
        S_DONE       // pulse done, return to idle
    } state_t;

    state_t state;

    // ------------------------------------------------------------------------
    //  Phase / quarter timing and bit counting.
    // ------------------------------------------------------------------------
    logic [QW-1:0] q_cnt;   // counts system clocks inside one phase
    logic [1:0]    phase;   // 0..3 within a bit
    logic [2:0]    bit_idx; // 0..7 shift index

    logic [7:0] shreg;      // TX/RX shift register
    logic       rw_l;       // latched R/W
    logic [6:0] addr_l;     // latched address

    // We "want SCL high" during phases 2 and 3 of any transfer state and in
    // the corresponding START/STOP phases (see scl_drive below).  When we have
    // released SCL but scl_i is still low, a slave is stretching the clock, so
    // we freeze all timing until SCL actually rises.
    logic want_scl_high;
    logic stretch;
    logic q_tick;           // one system clock at the end of a phase

    assign stretch = want_scl_high && (scl_i == 1'b0);
    assign q_tick  = (q_cnt == QUARTER[QW-1:0] - 1'b1) && !stretch;

    // ------------------------------------------------------------------------
    //  Combinational bus drive.  oe = 1 pulls the line low; oe = 0 releases.
    //  Open-drain value v is emitted as oe = ~v.
    // ------------------------------------------------------------------------
    logic scl_drive;  // desired SCL level (1 = high/released)
    logic sda_drive;  // desired SDA level (1 = high/released)

    always_comb begin
        // Defaults: bus released (idle high).
        scl_drive = 1'b1;
        sda_drive = 1'b1;
        want_scl_high = 1'b1;

        unique case (state)
            // ---- idle: everything released --------------------------------
            S_IDLE: begin
                scl_drive = 1'b1;
                sda_drive = 1'b1;
                want_scl_high = 1'b1;
            end

            // ---- START: SDA 1->0 while SCL high, then SCL low --------------
            S_START: begin
                unique case (phase)
                    2'd0: begin scl_drive = 1'b1; sda_drive = 1'b1; end
                    2'd1: begin scl_drive = 1'b1; sda_drive = 1'b0; end // fall
                    default: begin scl_drive = 1'b0; sda_drive = 1'b0; end
                endcase
                want_scl_high = (phase <= 2'd1);
            end

            // ---- shift out address byte -----------------------------------
            S_ADDR: begin
                sda_drive = shreg[7];                 // MSB first
                scl_drive = (phase >= 2'd2);          // low, low, high, high
                want_scl_high = (phase >= 2'd2);
            end

            // ---- release SDA, read ACK ------------------------------------
            S_ADDR_ACK: begin
                sda_drive = 1'b1;                     // release for slave ACK
                scl_drive = (phase >= 2'd2);
                want_scl_high = (phase >= 2'd2);
            end

            // ---- shift out write data -------------------------------------
            S_WR: begin
                sda_drive = shreg[7];
                scl_drive = (phase >= 2'd2);
                want_scl_high = (phase >= 2'd2);
            end

            S_WR_ACK: begin
                sda_drive = 1'b1;                     // release for slave ACK
                scl_drive = (phase >= 2'd2);
                want_scl_high = (phase >= 2'd2);
            end

            // ---- shift in read data (slave drives SDA) --------------------
            S_RD: begin
                sda_drive = 1'b1;                     // release; slave drives
                scl_drive = (phase >= 2'd2);
                want_scl_high = (phase >= 2'd2);
            end

            // ---- master NACK after single-byte read -----------------------
            S_RD_ACK: begin
                sda_drive = 1'b1;                     // NACK = leave SDA high
                scl_drive = (phase >= 2'd2);
                want_scl_high = (phase >= 2'd2);
            end

            // ---- STOP: SDA 0->1 while SCL high -----------------------------
            S_STOP: begin
                unique case (phase)
                    2'd0: begin scl_drive = 1'b0; sda_drive = 1'b0; end
                    2'd1: begin scl_drive = 1'b1; sda_drive = 1'b0; end // SCL up
                    default: begin scl_drive = 1'b1; sda_drive = 1'b1; end // rise
                endcase
                want_scl_high = (phase >= 2'd1);
            end

            S_DONE: begin
                scl_drive = 1'b1;
                sda_drive = 1'b1;
                want_scl_high = 1'b1;
            end

            default: begin
                scl_drive = 1'b1;
                sda_drive = 1'b1;
                want_scl_high = 1'b1;
            end
        endcase
    end

    // Open-drain conversion.
    assign scl_oe = ~scl_drive;
    assign sda_oe = ~sda_drive;

    // ------------------------------------------------------------------------
    //  Sequential control.
    // ------------------------------------------------------------------------
    // Sample point: the tick that ends phase 2 (SCL has been high a full
    // quarter) is where incoming data / ACK are valid.
    wire sample_now = q_tick && (phase == 2'd2);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            q_cnt     <= '0;
            phase     <= 2'd0;
            bit_idx   <= 3'd0;
            shreg     <= 8'h00;
            rw_l      <= 1'b0;
            addr_l    <= 7'h00;
            rd_data   <= 8'h00;
            busy      <= 1'b0;
            done      <= 1'b0;
            ack_error <= 1'b0;
        end else begin
            done <= 1'b0;  // default: single-cycle pulse

            // ---- phase / quarter counter ----------------------------------
            if (state == S_IDLE || state == S_DONE) begin
                q_cnt <= '0;
                phase <= 2'd0;
            end else if (!stretch) begin
                if (q_cnt == QUARTER[QW-1:0] - 1'b1) begin
                    q_cnt <= '0;
                    phase <= phase + 2'd1;   // wraps 3->0
                end else begin
                    q_cnt <= q_cnt + 1'b1;
                end
            end

            // ---- capture read data / ACK ----------------------------------
            if (sample_now) begin
                case (state)
                    S_RD:      shreg <= {shreg[6:0], sda_i};
                    S_ADDR_ACK,
                    S_WR_ACK:  if (sda_i) ack_error <= 1'b1; // 1 = NACK
                    default:   ;
                endcase
            end

            // ---- state / bit sequencing (on phase-3 -> 0 wrap) ------------
            unique case (state)
                // --------------------------------------------------------
                S_IDLE: begin
                    ack_error <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        rw_l    <= rw;
                        addr_l  <= addr;
                        shreg   <= {addr, rw};       // first byte to send
                        bit_idx <= 3'd0;
                        phase   <= 2'd0;
                        q_cnt   <= '0;
                        state   <= S_START;
                    end
                end

                // --------------------------------------------------------
                S_START: begin
                    if (q_tick && phase == 2'd3) begin
                        bit_idx <= 3'd0;
                        state   <= S_ADDR;
                    end
                end

                // --------------------------------------------------------
                S_ADDR: begin
                    if (q_tick && phase == 2'd3) begin
                        shreg   <= {shreg[6:0], 1'b0}; // shift next bit up
                        bit_idx <= bit_idx + 3'd1;
                        if (bit_idx == 3'd7)
                            state <= S_ADDR_ACK;
                    end
                end

                // --------------------------------------------------------
                S_ADDR_ACK: begin
                    if (q_tick && phase == 2'd3) begin
                        if (ack_error) begin
                            state <= S_STOP;         // no slave -> abort
                        end else if (rw_l) begin
                            bit_idx <= 3'd0;
                            state   <= S_RD;
                        end else begin
                            shreg   <= wr_data;
                            bit_idx <= 3'd0;
                            state   <= S_WR;
                        end
                    end
                end

                // --------------------------------------------------------
                S_WR: begin
                    if (q_tick && phase == 2'd3) begin
                        shreg   <= {shreg[6:0], 1'b0};
                        bit_idx <= bit_idx + 3'd1;
                        if (bit_idx == 3'd7)
                            state <= S_WR_ACK;
                    end
                end

                // --------------------------------------------------------
                S_WR_ACK: begin
                    if (q_tick && phase == 2'd3)
                        state <= S_STOP;
                end

                // --------------------------------------------------------
                S_RD: begin
                    if (q_tick && phase == 2'd3) begin
                        bit_idx <= bit_idx + 3'd1;
                        if (bit_idx == 3'd7) begin
                            rd_data <= shreg;        // fully shifted byte
                            state   <= S_RD_ACK;
                        end
                    end
                end

                // --------------------------------------------------------
                S_RD_ACK: begin
                    if (q_tick && phase == 2'd3)
                        state <= S_STOP;
                end

                // --------------------------------------------------------
                S_STOP: begin
                    if (q_tick && phase == 2'd3)
                        state <= S_DONE;
                end

                // --------------------------------------------------------
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
