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
| 19 | Streaming Top-K Selection Engine (systolic sorted-insertion array) | GPU top-K primitive (LLM top-K sampling, beam search, k-NN, radix-select) + HFT top-of-book / best-N-quote engine, keeps the K largest `(key, tag)` pairs of a 1-elem/clock stream, parallel compare against all K slots → **monotone** `ge[]` priority-encoded to a single insertion index `pos`, single-cycle conditional shift/insert (hold / insert / shift-neighbour), empty slots = −∞ so the array stays sorted-descending with tag/ID tracked per entry, newer-wins tie rule, provably equal to global top-K (no re-sort), synchronous reset + `flush`, `count_o`/`full_o` occupancy, parameterized K/DW/TW, independent scalar golden-model scoreboard TB (reset, ascending/descending fill+overflow, duplicates, negatives, mid-stream flush, 4000 random) | [`Day19`](./Day19) |
| 20 | Warp Global-Memory Coalescing Unit (GPU LSU front-end) | GPU load/store-unit memory coalescing (the #1 driver of achievable DRAM bandwidth) + HFT scattered-gather fold-in, warp of per-lane byte addresses → minimum aligned cache-line/sector transactions, single-pass **parallel leader detection** (lane leads its segment iff no lower-indexed active lane shares it; `num_txn = popcount(leaders)`), exact-partition `txn_lane_mask`s (pairwise-disjoint, union == `req_mask`), aligned `txn_base = seg << log2(SEG_BYTES)`, sequenced 1-txn/cycle emit in ascending leader order with `txn_index`/`txn_last`, coalescing-efficiency perf counters (`perf_lanes/perf_txns` lanes-per-txn), IDLE→DECODE→EMIT FSM, parameterized LANES/ADDRW/SEG_BYTES, independent golden set-partition scoreboard TB (directed corners + 300 random warps, partition & counter assertions) | [`Day20`](./Day20) |
| 21 | Pipelined 2:4 Structured-Sparsity Dot-Product Engine | GPU sparse Tensor Core operand/datapath primitive, compressed two-nonzero weights per four activations, per-group dual-index metadata decode + 4:1 selection, `2*GROUPS` signed multipliers, local pair sums + widened final reduction, 1 fragment/clock throughput at fixed 3-cycle latency, duplicate-index validation with zero-contribution containment, parameterized GROUPS/DW, independent signed golden-model scoreboard TB (directed extremes + 1,000 randomized attempts) | [`Day21`](./Day21) |
| 22 | Parameterized Parallel CRC-32 Engine (Ethernet FCS) | line-rate FPGA/SmartNIC frame-integrity primitive (10G/25G NIC FCS gen+check, HFT tick-to-trade path), reflected IEEE-802.3 CRC-32 (poly `0xEDB88320`, init/xor `0xFFFFFFFF`), bit-serial LFSR step **unrolled `DATA_WIDTH`× at elaboration** into one combinational GF(2) cone → 1 slice/clock (W=8→1 B/clk, W=32→4 B/clk, W=64→8 B/clk), `init`-aware seed mux folded into the combinational current-state so single-beat `init&last` frames match multi-beat behaviour, `en`/`last` frame handshake with registered `result_o`+`result_valid_o`, live `crc_o`, width-generic, independent **bit-serial golden model** + hard-coded `"123456789"→0xCBF43926` IEEE vector + empty-frame + W8-vs-W32 cross-check scoreboard TB (127 checks, directed + 120 random frames) | [`Day22`](./Day22) |
| 23 | Systolic Register-Array Hardware Priority Queue (min-queue) | FPGA packet-scheduler + HFT price-time order-book / event-timer-wheel primitive, single-cycle **enqueue AND extract-min** (both together = replace-min) at deterministic occupancy-independent latency — no heap-in-RAM sift loop, shift-register array kept **sorted ascending** so slot 0 is always the global minimum available combinationally, per-cycle datapath = optional extract-min shift-down → `base[]` → N parallel comparators `gt[i]=(base_key[i]>enq_key)` (monotone) → priority-encoder insertion index `pos` → one-shot conditional shift/insert network, **strict-`>` FIFO-among-equals** tie rule, `DW` payload (order ID/pointer) tracked per entry, `full`/`empty` guards + registered `overflow`/`underflow` pulses, synchronous `flush`, parameterized `N`/`KW`/`DW`, independent scalar golden-PQ scoreboard TB checking head+whole sorted array+counters+flags (4082 checks: reset, fill/overflow, drain/underflow, replace-min, asc/desc/duplicate streams, flush, 4000 random) | [`Day23`](./Day23) |
| 24 | Pipelined Ternary CAM (TCAM) Lookup Engine | line-rate networking + HFT/FPGA "search-in-hardware" primitive (router forwarding tables / ACLs / longest-prefix-match, HFT symbol→internal-ID lookup + order/quote-tag classification), `DEPTH`-entry ternary array — each entry `{value key, per-bit care mask, valid}` where `mask=1`⇒care, `0`⇒don't-care/wildcard — searched **all entries in parallel in one shot**: combinational cone `match[i]=valid[i]&(((skey^key[i])&mask[i])==0)` → `DEPTH` match lines → **priority encoder (lowest index wins)** → `win_index`+`any_match`, `mask=0` catch-all default route, contiguous-prefix masks loaded longest-first ⇒ ready-made **LPM**, full parallel `hit_map_o` bitmap (all matches, not just winner), one-per-cycle configure port with nonblocking write coherency, registered result = deterministic **1-cycle occupancy-independent latency**, `default_nettype none`/latch-free/parameterized `DEPTH`/`KEY_WIDTH`, independent golden-shadow linear-priority-scan scoreboard TB (2556 checks: reset, empty-miss, exact, priority, wildcard default, /24-/16-/8 LPM, invalidate, overwrite, back-to-back burst, 3000 random) | [`Day24`](./Day24) |
| 25 | Cut-Through Streaming Market-Data Feed Parser | **front door of the HFT tick-to-trade path** — a line-rate FPGA feed handler that turns raw exchange bytes into normalized market-data events *inline on the wire*, never via a CPU (dodges interrupt/cache/DMA jitter), simplified-**NASDAQ-ITCH** schema (Add `A` / Exec `E` / Cancel `X` / Delete `D`), length-framed byte stream (`[LEN][body…]`, `LEN` flagged by `in_sop`; `body[0]`=type), **cut-through `(type × offset)` byte-router** steers each byte straight into its big-endian field register (`ref`/`side`/`shares`/`price`) with **no store-and-forward and no content-dependent stall** ⇒ *worst-case latency == typical latency*, `ev_valid` fires **exactly 1 cycle after the final byte** (deterministic, jitter-free — the metric that wins in HFT), schema-table `exp_len()` + length/type check ⇒ single `ev_error` event on unknown-type/bad-length (fields normalized), **self-resync** framing (mid-message `in_sop` aborts + re-frames so a garbled feed can't wedge the pipe), latch-free `default_nettype none`, independent golden-decoder pointer-scoreboard TB (2020 events: one-of-each, unknown type, wrong/over length, mid-message abort, back-to-back, 2000 random w/ gaps + corrupted lengths) — waveform is a **real captured VCD** | [`Day25`](./Day25) |

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
├── Day19/
│   ├── topk_stream_engine.sv      # RTL design (streaming Top-K selection engine)
│   ├── tb_topk_stream_engine.sv   # self-checking testbench (independent golden Top-K)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # circuit diagram + captured waveform
│   └── README.md                  # project write-up
├── Day22/
│   ├── crc32_parallel.sv          # RTL design (parameterized unrolled CRC-32 / Ethernet FCS)
│   ├── tb_crc32_parallel.sv       # self-checking testbench (bit-serial golden + IEEE vector)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # block diagram + captured waveform
│   └── README.md                  # project write-up
├── Day23/
│   ├── priority_queue.sv          # RTL design (systolic register-array min priority queue)
│   ├── tb_priority_queue.sv       # self-checking testbench (independent scalar golden PQ)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # circuit diagram + captured waveform
│   └── README.md                  # project write-up
├── Day24/
│   ├── tcam.sv                    # RTL design (pipelined ternary CAM lookup engine)
│   ├── tb_tcam.sv                 # self-checking testbench (independent golden-shadow scan)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # circuit diagram + captured waveform
│   └── README.md                  # project write-up
├── Day25/
│   ├── md_feed_parser.sv          # RTL design (cut-through market-data feed parser)
│   ├── tb_md_feed_parser.sv       # self-checking testbench (independent golden decoder)
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
