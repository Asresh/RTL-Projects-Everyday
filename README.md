# RTL Projects Everyday

A daily series of small, self-contained **RTL design projects** in
SystemVerilog / Verilog — one hands-on hardware design per day. Each day lives in
its own folder with the synthesizable design, a self-checking testbench, a
`Makefile` for common simulators, and a short write-up.

The goal: stay sharp on digital design and verification by shipping one clean,
documented, simulate-able project every day.

---

## Index

| Day | Project | Description | Folder |
|-----|---------|-------------|--------|
| 1 | Parameterized Synchronous FIFO | Pointer-based FIFO with an occupancy counter and full/empty flags, verified with a self-checking testbench. | [`day01-sync_fifo`](./day01-sync_fifo) |
| 2 | Parameterized Round-Robin Arbiter | Fair rotating-priority arbiter producing one-hot grants with wrap-around priority masking. | [`day02-round_robin_arbiter`](./day02-round_robin_arbiter) |
| 3 | Configurable SPI Master (all 4 modes) | Supports all CPOL/CPHA modes with a programmable clock divider and a full-duplex shift engine. | [`day03-spi_master`](./day03-spi_master) |
| 4 | Asynchronous (dual-clock) FIFO | Clock-domain-crossing FIFO using Gray-coded pointers and two-flop synchronizers for safe full/empty detection. | [`day04-async_fifo`](./day04-async_fifo) |
| 5 | Configurable UART (TX + RX) | 8-N-1 framing UART with a runtime baud divider and mid-bit sampling, verified via TX→RX loopback. | [`day05-uart_transceiver`](./day05-uart_transceiver) |
| 6 | Parameterized Sequential Integer Divider | Restoring shift-subtract divider with a multicycle start/busy/done handshake and divide-by-zero policy. | [`day06-sequential_divider`](./day06-sequential_divider) |
| 7 | AXI4-Lite Slave Register Block | Implements the AW/W/B/AR/R handshakes with byte strobes, OKAY/SLVERR, and RW/RO/W1C register types. | [`day07-axi4lite_regs`](./day07-axi4lite_regs) |
| 8 | I2C Master Controller | Open-drain wired-AND I2C bus master with START/STOP framing and per-byte ACK/NACK handling. | [`day08-i2c_master`](./day08-i2c_master) |
| 9 | Pipelined CORDIC Sine/Cosine Engine | Multiplier-free rotation-mode CORDIC computing sine/cosine in fixed-point Q2.13 over the full angle range. | [`day09-cordic_sincos`](./day09-cordic_sincos) |
| 10 | SECDED Hamming ECC Codec | (72,64) single-error-correct/double-error-detect encoder/decoder with syndrome decoding and error injection testing. | [`day10-hamming_secded`](./day10-hamming_secded) |
| 11 | Pipelined Bitonic Sorting Network | Data-independent compare-exchange sorting network delivering one sorted vector per clock. | [`day11-bitonic_sorter`](./day11-bitonic_sorter) |
| 12 | Pipelined Radix-4 Booth Multiplier | Modified-Booth recoding with a Wallace carry-save reduction tree for signed/unsigned multiply. | [`day12-booth_multiplier`](./day12-booth_multiplier) |
| 13 | Pipelined IEEE-754 FP Adder (binary32) | Single-precision floating-point add/subtract with guard/round/sticky round-to-nearest-even and subnormal support. | [`day13-fp_adder`](./day13-fp_adder) |
| 14 | Output-Stationary Systolic-Array GEMM Accelerator | TPU-style N×N MAC mesh with diagonal skew scheduling for matrix multiplication. | [`day14-systolic_gemm`](./day14-systolic_gemm) |
| 15 | Pipelined Kogge-Stone Prefix-Sum (Segmented Scan) Engine | Log-depth parallel-prefix scan supporting segmented reductions for GPU-style workloads. | [`day15-prefix_sum_scan`](./day15-prefix_sum_scan) |
| 16 | SIMT Shared-Memory Bank-Conflict Resolution Crossbar | Resolves GPU shared-memory bank conflicts and broadcasts with a leader-select scheduler. | [`day16-bank_conflict_crossbar`](./day16-bank_conflict_crossbar) |
| 17 | GPU Warp Scheduler (Greedy-Then-Oldest) + Register Scoreboard | Instruction-issue front end with RAW/WAW hazard tracking and guaranteed-progress arbitration. | [`day17-warp_scheduler`](./day17-warp_scheduler) |
| 18 | SIMT Branch-Divergence Reconvergence (IPDOM) Stack | Per-warp divergence stack managing active-lane masks through nested branches. | [`day18-simt_divergence_stack`](./day18-simt_divergence_stack) |
| 19 | Streaming Top-K Selection Engine | Systolic sorted-insertion array that maintains the K largest keys from a streaming input. | [`day19-top_k_selection`](./day19-top_k_selection) |
| 20 | Warp Global-Memory Coalescing Unit | GPU load/store front end that folds per-lane addresses into minimal aligned memory transactions. | [`day20-memory_coalescing_unit`](./day20-memory_coalescing_unit) |
| 21 | Pipelined 2:4 Structured-Sparsity Dot-Product Engine | Compressed sparse-weight dot-product datapath used in GPU tensor cores. | [`day21-sparse_dot_product`](./day21-sparse_dot_product) |
| 22 | Parameterized Parallel CRC-32 Engine (Ethernet FCS) | Elaboration-unrolled parallel CRC-32 for line-rate frame integrity checking. | [`day22-crc32_engine`](./day22-crc32_engine) |
| 23 | Systolic Register-Array Hardware Priority Queue | Single-cycle enqueue/extract-min shift-register priority queue for scheduling and order books. | [`day23-priority_queue`](./day23-priority_queue) |
| 24 | Pipelined Ternary CAM (TCAM) Lookup Engine | Fully parallel ternary content-addressable memory for longest-prefix-match lookups. | [`day24-tcam_lookup`](./day24-tcam_lookup) |
| 25 | Cut-Through Streaming Market-Data Feed Parser | Line-rate byte-router that decodes a simplified ITCH-style feed with deterministic latency. | [`day25-market_data_parser`](./day25-market_data_parser) |
| 26 | Pre-Trade Risk Check Gate (Market-Access Firewall) | Parallel five-limit market-access risk firewall with single-cycle accept/reject decisions. | [`day26-risk_check_gate`](./day26-risk_check_gate) |
| 27 | Direct-Mapped L2 Limit Order Book + BBO Engine | Price-indexed order book with combinational best-bid/best-offer extraction every cycle. | [`day27-limit_order_book`](./day27-limit_order_book) |
| 28 | Redundant A/B Market-Data Feed Arbiter | Deduplicates and reorders two redundant exchange feed lines into one in-order stream. | [`day28-feed_arbiter`](./day28-feed_arbiter) |
| 29 | Cut-Through Order-Entry Egress Serializer | Serializes an order descriptor into an OUCH-style wire message with a skid-buffer backpressure interface. | [`day29-order_entry_serializer`](./day29-order_entry_serializer) |
| 30 | Hardware Nanosecond-Timestamp & Tick-to-Trade Latency Monitor | NCO-based nanosecond timestamping with tag-matched latency histogram capture. | [`day30-latency_monitor`](./day30-latency_monitor) |
| 31 | Tick-to-Trade Marketable-Order Trigger Engine | Evaluates resting strategy rules against live BBO and fires child orders with throttling. | [`day31-order_trigger_engine`](./day31-order_trigger_engine) |
| 32 | Reed–Solomon RS(n,k) Systematic Encoder over GF(2^M) | Elaboration-derived Galois-field LFSR encoder generating parity symbols for burst-error correction. | [`day32-reed_solomon_encoder`](./day32-reed_solomon_encoder) |
| 33 | AES-128 Block-Cipher Encryption Core (FIPS-197) | Iterative 11-cycle AES-128 encryptor with an on-the-fly key schedule. | [`day33-aes128_encryption`](./day33-aes128_encryption) |
| 34 | SHA-256 Cryptographic Hash Core (FIPS 180-4) | Iterative 66-cycle SHA-256 compression function with a circular-window message schedule. | [`day34-sha256_hash_core`](./day34-sha256_hash_core) |
| 35 | 8b/10b Line Encoder (Widmer/Franaszek) | DC-balanced, transition-rich line coding with running-disparity tracking for SerDes PHYs. | [`day35-line_encoder_8b10b`](./day35-line_encoder_8b10b) |
| 36 | Hard-Decision Viterbi Decoder (rate-1/2, K=3) | Maximum-likelihood convolutional decoder using add-compare-select butterflies and register-exchange survivor memory. | [`day36-viterbi_decoder`](./day36-viterbi_decoder) |
| 37 | Pipelined Radix-2 DIT FFT (N=16, Q1.15) | Fully pipelined 16-point FFT with an elaboration-derived twiddle ROM, one transform per clock. | [`day37-fft_radix2`](./day37-fft_radix2) |
| 38 | 5-Stage Pipelined RISC-V RV32I Integer Core | In-order RV32I core with full data forwarding, load-use hazard interlock, and branch resolution in EX. | [`day38-riscv_pipeline_core`](./day38-riscv_pipeline_core) |
| 39 | 4-Way Set-Associative Write-Back L1 Data Cache | True-LRU cache with write-back/write-allocate stores and burst eviction/refill. | [`day39-l1_data_cache`](./day39-l1_data_cache) |
| 40 | RISC-V Sv32 MMU (TLB + hardware page-table walker) | Fully-associative TLB with a two-level hardware page-table walk and full permission checking. | [`day40-riscv_mmu`](./day40-riscv_mmu) |
| 41 | Out-of-Order Execution Engine (Tomasulo + Reorder Buffer) | Register renaming, reservation stations, and a reorder buffer for precise out-of-order execution. | [`day41-out_of_order_engine`](./day41-out_of_order_engine) |
| 42 | SIMT Register-File Operand Collector | Multi-warp operand-gathering stage with banked register-file arbitration and operand reuse caching. | [`day42-operand_collector`](./day42-operand_collector) |
| 43 | Wormhole Virtual-Channel NoC Router (5-port mesh node) | Deadlock-free XY-routed virtual-channel router with credit-based flow control. | [`day43-noc_router`](./day43-noc_router) |
| 44 | FR-FCFS DRAM Memory Controller (JEDEC-style bank scheduler) | Bank-scheduling DRAM controller enforcing full JEDEC timing with row-hit-locality reordering. | [`day44-dram_controller`](./day44-dram_controller) |
| 45 | MESI Snooping Cache-Coherence Complex (4-core, cache-to-cache) | Four-core MESI protocol with a snooping bus and cache-to-cache intervention. | [`day45-mesi_cache_coherence`](./day45-mesi_cache_coherence) |
| 46 | Descriptor-Driven 2D Strided DMA Engine | Queued-descriptor DMA supporting independent source/destination strides and partial final beats. | [`day46-dma_engine`](./day46-dma_engine) |
| 47 | Out-of-Order Load/Store Queue with Store-to-Load Forwarding | Age-ordered LQ/SQ with store-to-load forwarding and speculative memory disambiguation. | [`day47-load_store_queue`](./day47-load_store_queue) |
| 48 | PCIe-Style Link Training and Status State Machine | Multi-lane TS1/TS2 qualification, width negotiation, bounded retries, and speed/link-loss recovery. | [`day48-pcie_ltssm`](./day48-pcie_ltssm) |

_More days coming._

---

## Repository layout

Each day's folder is self-contained and generally follows this shape:

```
RTL-Projects-Everyday/
├── day01-sync_fifo/
│   ├── *.sv           # RTL design(s)
│   ├── tb_*.sv         # self-checking testbench
│   ├── Makefile        # simulator run targets
│   ├── docs/           # block diagram + captured waveform (where present)
│   └── README.md       # project write-up
├── day02-round_robin_arbiter/
│   └── ...
├── ...
└── day48-pcie_ltssm/
    └── ...
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
