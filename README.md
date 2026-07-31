# RTL Projects Everyday

A daily series of small, self-contained **RTL design projects** in
SystemVerilog / Verilog — one hands-on hardware design per day. Each day lives in
its own folder with the synthesizable design, a self-checking testbench, a
`Makefile` for common simulators, and a short write-up.

The goal: stay sharp on digital design and verification by shipping one clean,
documented, simulate-able project every day.

---

## Index

| Day | Project | Concepts | Folder |
|-----|---------|----------|--------|
| 1 | Parameterized Synchronous FIFO | pointers, occupancy counter, full/empty flags, self-checking TB | [`Day1`](./Day1) |
| 2 | Parameterized Round-Robin Arbiter | fair rotating priority, one-hot grant, priority mask, wrap-around, self-checking TB | [`Day2`](./Day2) |
| 3 | Configurable SPI Master (all 4 modes) | CPOL/CPHA modes, programmable SCLK divider, full-duplex shift engine, FSM, chip-select framing, self-checking TB + slave model | [`Day3`](./Day3) |
| 4 | Asynchronous (dual-clock) FIFO | clock-domain crossing, Gray-code pointers, two-flop synchronizers, safe full/empty flags, golden-queue self-checking TB | [`Day4`](./Day4) |
| 5 | Configurable UART (TX + RX) | 8-N-1 framing, LSB-first, run-time baud divider, mid-bit sampling, two-flop line sync, TX→RX loopback self-checking TB | [`Day5`](./Day5) |
| 6 | Parameterized Sequential Integer Divider | restoring shift-subtract, multicycle FSM, start/busy/done handshake, quotient+remainder, divide-by-zero policy, golden `/`&`%` self-checking TB | [`Day6`](./Day6) |
| 7 | AXI4-Lite Slave Register Block | AW/W/B/AR/R VALID/READY handshakes, WSTRB byte strobes, OKAY/SLVERR, RW/RO/W1C registers, task-based master BFM + golden-model self-checking TB | [`Day7`](./Day7) |
| 8 | I2C Master Controller | open-drain wired-AND bus, START/STOP, 7-bit addr + R/W̅, per-byte ACK/NACK, 4-phase SCL timing, clock-stretch aware, behavioral slave-model self-checking TB | [`Day8`](./Day8) |
| 9 | Pipelined CORDIC Sine/Cosine Engine | rotation-mode CORDIC, multiplier-free (add/sub + shifts), fully-unrolled pipeline, quadrant folding for full [-π, π] range, 1/K gain pre-scale, fixed-point Q2.13, golden `$sin`/`$cos` self-checking TB | [`Day9`](./Day9) |
| 10 | SECDED Hamming ECC Codec | (72,64) single-error-correct/double-error-detect, interleaved parity positions, syndrome decode, overall-parity bit, 1-of-72 corrector, parameterized width, 2-stage pipeline, error-injection scoreboard TB | [`Day10`](./Day10) |
| 11 | Pipelined Bitonic Sorting Network | data-independent compare-exchange network, log²-depth pipeline (S=6 stages, 24 CEs for N=8), 1 vector/clock throughput, constant 7-cycle latency, signed/unsigned + asc/desc, elaboration-generated wiring, golden-sort scoreboard TB | [`Day11`](./Day11) |
| 12 | Pipelined Radix-4 Booth Multiplier | modified-Booth recoding (halves partial products to 8 for W=16), signed digits {−2,−1,0,+1,+2}, Wallace 3:2 carry-save reduction tree (8→6→4→3→2), final carry-propagate adder, 4-stage pipeline (1 multiply/clock), signed/unsigned, golden-`*` scoreboard TB | [`Day12`](./Day12) |
| 13 | Pipelined IEEE-754 FP Adder (binary32) | single-precision add/subtract, exponent-compare + alignment barrel shift, guard/round/sticky **round-to-nearest-even**, leading-zero-count normalize, gradual underflow (subnormals), signed zeros, Inf/NaN special-case unit, overflow→Inf, 3-stage pipeline (1 add/clock), width-generic, host-FPU (`shortreal`) golden scoreboard TB | [`Day13`](./Day13) |
| 14 | Output-Stationary Systolic-Array GEMM Accelerator | N×N MAC mesh (TPU-tile dataflow), output-stationary accumulators, A-east / B-south nearest-neighbour streaming, automatic diagonal space-time skew scheduler, activation-valid strobe, signed MAC with overflow-proof accumulator width, start/busy/done handshake, per-launch accumulator clear, golden-`longint`-matmul scoreboard TB | [`Day14`](./Day14) |
| 15 | Pipelined Kogge-Stone Parallel Prefix-Sum (Segmented Scan) Engine | warp-level GPU scan primitive (stream compaction, radix-sort counts, sparse/segmented reduction), log2(N)-depth Kogge-Stone network, 1 vector/clock throughput at log2(N)-cycle latency, segmented scan with per-lane head flags + OR-scan flag propagation, overflow-proof widened accumulators, signed/unsigned, elaboration-generated network, golden segmented-scan scoreboard TB | [`Day15`](./Day15) |
| 16 | SIMT Shared-Memory Bank-Conflict Resolution Crossbar | GPU shared-memory (CUDA `__shared__`/LDS) bank-conflict + broadcast hardware, word-interleaved bank mapping, per-bank leader-select conflict scheduler, same-address broadcast collapsing, pending-mask retire loop with guaranteed forward progress, `resp_phases` = measured conflict degree, warp-wide read gather, per-lane active mask, parameterized LANES/BANKS/depth, golden-model scoreboard TB (directed corners + 200 random warps) | [`Day16`](./Day16) |
| 17 | GPU Warp Scheduler (Greedy-Then-Oldest) + Register Scoreboard | NVIDIA-class SM instruction-issue front-end, per-warp register scoreboard with RAW + WAW interlocks, fixed-latency writeback pipeline that sets/clears pending bits, Greedy-Then-Oldest arbitration (greedy hold on `last_warp`, oldest = lowest ready warp), single-cycle combinational ready→select path, one issue/cycle with one-hot consume strobe, guaranteed-progress (no deadlock) proof, parameterized NW/NREG/WB_LATENCY, independent golden-model TB asserting greedy/progress/no-hazard-escape over directed + randomized programs | [`Day17`](./Day17) |
| 18 | SIMT Branch-Divergence Reconvergence (IPDOM) Stack | GPU SIMT control-flow hardware, per-warp LIFO of `{pc, rpc, active_mask}` groups, immediate-post-dominator reconvergence, divergent branch reuses TOS as the reconv entry + pushes not-taken/taken sub-groups (taken first), exact lane conservation (`t\|n==parent`, `t&n==0`), uniform-branch collapse (no push), combinational `reconverge` (`pc==rpc`) + `active_lanes=popcount(mask)` divergence-penalty monitor, sticky overflow/underflow guards, parameterized NLANES/PCW/DEPTH, independent golden-stack scoreboard TB (uniform + nested divergence + overflow/underflow + 4000 random legal commands) | [`Day18`](./Day18) |

_More days coming._

---

## Repository layout

```
RTL-Projects-Everyday/
├── Day1/
│   ├── sync_fifo.sv       # RTL design
│   ├── tb_sync_fifo.sv    # self-checking testbench
│   ├── Makefile           # simulator run targets
│   └── README.md          # project write-up
├── Day2/
│   ├── round_robin_arbiter.sv     # RTL design
│   ├── tb_round_robin_arbiter.sv  # self-checking testbench
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # waveform image
│   └── README.md                  # project write-up
├── Day3/
│   ├── spi_master.sv              # RTL design
│   ├── tb_spi_master.sv           # self-checking testbench + slave model
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day4/
│   ├── async_fifo.sv              # RTL design (dual-clock FIFO, Gray-pointer CDC)
│   ├── tb_async_fifo.sv           # self-checking testbench (golden-queue model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day5/
│   ├── uart.sv                    # RTL design (uart_tx + uart_rx + full-duplex top)
│   ├── tb_uart.sv                 # self-checking testbench (TX→RX loopback)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day6/
│   ├── seq_divider.sv             # RTL design (restoring shift-subtract divider)
│   ├── tb_seq_divider.sv          # self-checking testbench (golden / and % model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day7/
│   ├── axi4lite_regs.sv           # RTL design (AXI4-Lite slave register block)
│   ├── tb_axi4lite_regs.sv        # self-checking testbench (master BFM + golden model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day8/
│   ├── i2c_master.sv              # RTL design (open-drain single-master I2C)
│   ├── tb_i2c_master.sv           # self-checking testbench (behavioral slave model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day9/
│   ├── cordic_sincos.sv           # RTL design (pipelined rotation-mode CORDIC)
│   ├── tb_cordic_sincos.sv        # self-checking testbench (golden $sin/$cos model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day10/
│   ├── hamming_secded.sv          # RTL design (SECDED (72,64) ECC encoder/decoder)
│   ├── tb_hamming_secded.sv       # self-checking testbench (error-injection scoreboard)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day11/
│   ├── bitonic_sorter.sv          # RTL design (pipelined bitonic sorting network)
│   ├── tb_bitonic_sorter.sv       # self-checking testbench (golden-sort scoreboard)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # CE-network diagram + captured waveform
│   └── README.md                  # project write-up
├── Day12/
│   ├── booth_multiplier.sv        # RTL design (pipelined radix-4 Booth multiplier)
│   ├── tb_booth_multiplier.sv     # self-checking testbench (golden-* scoreboard)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
├── Day13/
│   ├── fp_add.sv                  # RTL design (pipelined IEEE-754 binary32 adder)
│   ├── tb_fp_add.sv               # self-checking testbench (host-FPU golden model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
├── Day14/
│   ├── systolic_matmul.sv         # RTL design (output-stationary systolic GEMM tile)
│   ├── tb_systolic_matmul.sv      # self-checking testbench (golden longint matmul)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # array diagram + captured waveform
│   └── README.md                  # project write-up
├── Day15/
│   ├── prefix_scan.sv             # RTL design (pipelined Kogge-Stone segmented scan)
│   ├── tb_prefix_scan.sv          # self-checking testbench (golden segmented-scan model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # Kogge-Stone network diagram + captured waveform
│   └── README.md                  # project write-up
├── Day16/
│   ├── smem_xbar.sv               # RTL design (SIMT shared-memory bank-conflict crossbar)
│   ├── tb_smem_xbar.sv            # self-checking testbench (golden bank-conflict model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
├── Day17/
│   ├── warp_scheduler.sv          # RTL design (GTO warp scheduler + register scoreboard)
│   ├── tb_warp_scheduler.sv       # self-checking testbench (independent golden model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
├── Day18/
│   ├── simt_stack.sv              # RTL design (SIMT branch-divergence IPDOM stack)
│   ├── tb_simt_stack.sv           # self-checking testbench (independent golden stack)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
└── README.md
```

## Running any project

Each day's folder has a `Makefile`. From inside a day's folder:

```bash
make verilator   # or: make vcs / make questa / make icarus
```

---

## Tech

`SystemVerilog` · `Verilog` · `RTL Design` · `Functional Verification` · `Self-checking Testbenches`

## Author

**Asresh Kuricheti** — Hardware Engineer
