// -----------------------------------------------------------------------------
// Day 6 : seq_divider  --  parameterized sequential integer divider
// -----------------------------------------------------------------------------
// An N-bit *unsigned* integer divider using the classic shift-subtract
// **restoring** algorithm, one iteration per clock, driven by a small
// multicycle FSM with a start / busy / done handshake.  It produces both the
// quotient and the remainder of `dividend / divisor`.
//
// Algorithm (restoring), for WIDTH = N:
//   acc = 0;  quo = dividend;                       // combined 2N-bit register
//   repeat N times:
//       {acc, quo} <<= 1;                           // shift dividend bit up
//       if (acc >= divisor) { acc -= divisor; q_bit = 1; }
//       else                {                  q_bit = 0; }
//       quo[0] = q_bit;
//   quotient  = quo;   remainder = acc;
//
// Because `acc` is kept strictly below `divisor` after every restore step, the
// remainder always fits in N bits; one guard bit on `acc` covers the pre-
// compare shift.  The datapath is one adder/subtractor and a shift register;
// the control path is a 3-state FSM (IDLE -> CALC -> DONE) plus a down-counter.
//
// Divide-by-zero policy (documented, matches RISC-V DIVU/REMU):
//   dividend / 0  ->  quotient  = all-ones (2^N - 1)
//                     remainder = dividend
//   `div_by_zero` is asserted alongside `done` so callers can detect it.  The
//   restoring algorithm produces exactly this result for divisor == 0 with no
//   special-casing: every compare passes (>= 0), so `quo` fills with ones and
//   the dividend shifts intact into `acc`.
// -----------------------------------------------------------------------------

`default_nettype none

module seq_divider #(
    parameter int WIDTH = 8            // operand width (>= 2)
) (
    input  wire              clk,
    input  wire              rst_n,     // active-low async reset

    input  wire              start,     // pulse high (while !busy) to begin
    input  wire [WIDTH-1:0]  dividend,  // numerator
    input  wire [WIDTH-1:0]  divisor,   // denominator

    output reg  [WIDTH-1:0]  quotient,  // dividend / divisor
    output reg  [WIDTH-1:0]  remainder, // dividend % divisor
    output reg               busy,      // high while a division is running
    output reg               done,      // one-cycle strobe when result is ready
    output reg               div_by_zero// divisor was zero (asserted with done)
);
    localparam int CNT_W = $clog2(WIDTH + 1);

    typedef enum logic [1:0] {
        S_IDLE,      // waiting for 'start'
        S_CALC,      // one restoring step per clock
        S_DONE       // one-cycle completion state
    } state_t;

    state_t                 state;

    reg  [WIDTH:0]          acc;    // partial remainder (N+1 bits: one guard bit)
    reg  [WIDTH-1:0]        quo;    // holds dividend, becomes the quotient
    reg  [WIDTH-1:0]        divi;   // latched divisor
    reg  [CNT_W-1:0]        count;  // iterations remaining
    reg                     dbz;    // latched divide-by-zero

    // ---- combinational one restoring step -----------------------------------
    // Shift the combined {acc, quo} register left by one; the new remainder MSB
    // comes from the top quotient bit.
    wire [WIDTH:0]   acc_shift = {acc[WIDTH-1:0], quo[WIDTH-1]};
    wire             ge        = (acc_shift >= {1'b0, divi});
    wire [WIDTH:0]   acc_next  = ge ? (acc_shift - {1'b0, divi}) : acc_shift;
    wire [WIDTH-1:0] quo_next  = {quo[WIDTH-2:0], ge};   // shift in the quotient bit

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            acc         <= '0;
            quo         <= '0;
            divi        <= '0;
            count       <= '0;
            dbz         <= 1'b0;
            quotient    <= '0;
            remainder   <= '0;
            busy        <= 1'b0;
            done        <= 1'b0;
            div_by_zero <= 1'b0;
        end else begin
            done <= 1'b0;    // default: 'done' is a single-cycle strobe

            case (state)
                // ---------------------------------------------------------- IDLE
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        divi  <= divisor;
                        quo   <= dividend;    // dividend loaded into the low half
                        acc   <= '0;
                        dbz   <= (divisor == '0);
                        count <= WIDTH[CNT_W-1:0];
                        busy  <= 1'b1;
                        state <= S_CALC;
                    end
                end

                // ---------------------------------------------------------- CALC
                S_CALC: begin
                    acc   <= acc_next;
                    quo   <= quo_next;
                    count <= count - 1'b1;
                    if (count == 1)          // this cycle is the last iteration
                        state <= S_DONE;
                end

                // ---------------------------------------------------------- DONE
                S_DONE: begin
                    busy        <= 1'b0;
                    done        <= 1'b1;
                    div_by_zero <= dbz;
                    quotient    <= quo;            // all-ones automatically if dbz
                    remainder   <= acc[WIDTH-1:0]; // == dividend automatically if dbz
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
