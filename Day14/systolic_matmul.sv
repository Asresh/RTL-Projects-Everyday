// ---------------------------------------------------------------------------
// Day 14 : Output-Stationary Systolic-Array GEMM Accelerator
// ---------------------------------------------------------------------------
// Computes the signed integer matrix product  C = A x B  on an N x N mesh of
// multiply-accumulate processing elements (PEs) -- the canonical "TPU tile"
// dataflow.  Each PE(i,j) permanently owns output element C[i][j] and holds it
// stationary in a local accumulator (hence *output-stationary*).  Operands are
// streamed through the mesh:
//
//     * A rows enter the WEST edge and march EAST  (one register hop / cycle)
//     * B cols enter the NORTH edge and march SOUTH (one register hop / cycle)
//
// A built-in skew scheduler launches row i of A delayed by i cycles and column
// j of B delayed by j cycles so that, at PE(i,j), the k-th activation A[i][k]
// and the k-th weight B[k][j] land on the very same clock edge and get
// accumulated.  This is the classic space-time skew that makes a 2-D systolic
// array correct with purely local, nearest-neighbour wiring (no global buses).
//
//   A : N x K   (signed)          C = A x B : N x N   (signed, ACC_W wide)
//   B : K x N   (signed)
//
// Latency for the whole tile:  2*(N-1) + (K-1) + 1  cycles after `start`.
// Throughput: one full N x N result per invocation (start/done handshake).
//
// Fully parameterized (N, K, DW), reset-safe, and lint-friendly.
// ---------------------------------------------------------------------------
`default_nettype none

module systolic_matmul #(
    parameter int N  = 4,   // systolic array dimension (rows/cols of C)
    parameter int K  = 4,   // contraction (inner) dimension
    parameter int DW = 8,   // signed operand bit width
    // Accumulator width: product is 2*DW, growing by ceil(log2 K) for the sum.
    // Derived -- leave at default; not intended to be overridden.
    parameter int ACC_W = 2*DW + $clog2(K + 1)
) (
    input  wire                             clk,
    input  wire                             rst_n,   // active-low sync reset

    input  wire                             start,   // pulse: latch A,B and run
    output logic                            busy,    // high while streaming
    output logic                            done,    // 1-cycle pulse: C valid

    // Flattened signed operand matrices (row-major).
    //   A[i][k] = a_flat[(i*K + k)*DW +: DW]
    //   B[k][j] = b_flat[(k*N + j)*DW +: DW]
    input  wire [N*K*DW-1:0]                a_flat,
    input  wire [K*N*DW-1:0]                b_flat,

    // Flattened signed result matrix (row-major), each element ACC_W bits.
    //   C[i][j] = c_flat[(i*N + j)*ACC_W +: ACC_W]
    output logic [N*N*ACC_W-1:0]            c_flat
);
    // Total space-time depth: last MAC (PE[N-1][N-1], k=K-1) fires at this cycle
    // index measured from the first injection cycle (t = 0).
    localparam int LAST_MAC = 2*(N-1) + (K-1);
    // Cycle counter needs to reach LAST_MAC + 1 (drain the final registered MAC).
    localparam int CW       = $clog2(LAST_MAC + 3);

    // ---------------------------------------------------------------------
    // Operand storage: captured at `start` so the caller may free the inputs.
    // ---------------------------------------------------------------------
    logic signed [DW-1:0] a_mem [N][K];
    logic signed [DW-1:0] b_mem [K][N];

    // ---------------------------------------------------------------------
    // Control FSM
    // ---------------------------------------------------------------------
    typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
    state_t             state;
    logic [CW-1:0]      t;        // space-time cycle index (injection time)

    wire run = (state == S_RUN);

    // ---------------------------------------------------------------------
    // Skew scheduler -- combinational edge injections for cycle `t`.
    // West feed for row i presents A[i][ t-i ] (valid only when t-i in [0,K)).
    // North feed for col j presents B[ t-j ][j] (valid only when t-j in [0,K)).
    // ---------------------------------------------------------------------
    logic signed [DW-1:0] west_a   [N];
    logic                 west_v   [N];
    logic signed [DW-1:0] north_b  [N];

    always_comb begin
        for (int i = 0; i < N; i++) begin
            // present A[i][k] with k = t-i, valid only while k is in [0,K)
            if (run && (int'(t) >= i) && (int'(t) - i < K)) begin
                west_a[i] = a_mem[i][int'(t) - i];
                west_v[i] = 1'b1;
            end else begin
                west_a[i] = '0;
                west_v[i] = 1'b0;
            end
        end
        for (int j = 0; j < N; j++) begin
            // present B[k][j] with k = t-j, valid only while k is in [0,K)
            if (run && (int'(t) >= j) && (int'(t) - j < K)) begin
                north_b[j] = b_mem[int'(t) - j][j];
            end else begin
                north_b[j] = '0;
            end
        end
    end

    // ---------------------------------------------------------------------
    // Systolic PE mesh.  Inter-PE nets carry the *registered* neighbour output.
    //   a_bus[i][j] : activation entering PE(i,j) from the west
    //   b_bus[i][j] : weight     entering PE(i,j) from the north
    //   v_bus[i][j] : accumulate-enable travelling east with the activation
    // Column 0 / row 0 take the edge injections; interior PEs chain neighbours.
    // ---------------------------------------------------------------------
    logic signed [DW-1:0]    a_bus [N][N+1];
    logic                    v_bus [N][N+1];
    logic signed [DW-1:0]    b_bus [N+1][N];
    logic signed [ACC_W-1:0] acc   [N][N];

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi++) begin : g_row
            // West edge feed for this row.
            assign a_bus[gi][0] = west_a[gi];
            assign v_bus[gi][0] = west_v[gi];
        end
        for (gj = 0; gj < N; gj++) begin : g_col
            // North edge feed for this column.
            assign b_bus[0][gj] = north_b[gj];
        end

        for (gi = 0; gi < N; gi++) begin : g_pe_row
            for (gj = 0; gj < N; gj++) begin : g_pe_col
                // One MAC processing element.
                always_ff @(posedge clk) begin
                    if (!rst_n) begin
                        a_bus[gi][gj+1] <= '0;
                        v_bus[gi][gj+1] <= 1'b0;
                        b_bus[gi+1][gj] <= '0;
                        acc  [gi][gj]   <= '0;
                    end else begin
                        // Nearest-neighbour forwarding (systolic hops).
                        a_bus[gi][gj+1] <= a_bus[gi][gj];
                        v_bus[gi][gj+1] <= v_bus[gi][gj];
                        b_bus[gi+1][gj] <= b_bus[gi][gj];
                        // Clear the stationary accumulator on a fresh launch.
                        if (start) begin
                            acc[gi][gj] <= '0;
                        end else if (v_bus[gi][gj]) begin
                            acc[gi][gj] <= acc[gi][gj]
                                         + $signed(a_bus[gi][gj]) * $signed(b_bus[gi][gj]);
                        end
                    end
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------------
    // Control / result exposure
    // ---------------------------------------------------------------------
    integer ci, cj, ck;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            t     <= '0;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        // Latch operands into local memories.
                        for (ci = 0; ci < N; ci++)
                            for (ck = 0; ck < K; ck++)
                                a_mem[ci][ck] <= $signed(a_flat[(ci*K + ck)*DW +: DW]);
                        for (ck = 0; ck < K; ck++)
                            for (cj = 0; cj < N; cj++)
                                b_mem[ck][cj] <= $signed(b_flat[(ck*N + cj)*DW +: DW]);
                        t     <= '0;
                        busy  <= 1'b1;
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    busy <= 1'b1;
                    if (t == LAST_MAC + 1) begin
                        state <= S_DONE;
                    end else begin
                        t <= t + 1'b1;
                    end
                end
                S_DONE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;   // 1-cycle result-valid pulse
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // Flatten the stationary accumulators onto the output bus.
    genvar fi, fj;
    generate
        for (fi = 0; fi < N; fi++) begin : g_flat_row
            for (fj = 0; fj < N; fj++) begin : g_flat_col
                assign c_flat[(fi*N + fj)*ACC_W +: ACC_W] = acc[fi][fj];
            end
        end
    endgenerate

endmodule

`default_nettype wire
