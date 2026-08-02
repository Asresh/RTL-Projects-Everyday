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
| 26 | Pre-Trade Risk Check Gate (Market-Access "Risk Firewall") | **mandatory last hop of the HFT tick-to-trade path** — the hardware gate every child order must clear before egress, the FPGA embodiment of the regulatory pre-trade risk controls (**SEC Rule 15c3-5** "Market Access Rule", **MiFID II RTS 6**); five limits checked **fully in parallel in one combinational cone** — KILL (kill-switch/halt), QTY (`qty==0 \|\| qty>max_qty`, fat-finger size), BAND (`price ∉ [min,max][side]`, per-side price collar), NOTIONAL (`price×qty>max_notional`, capital-at-risk), POSITION (`\|pos ± qty\|>max_pos`, net exposure with long+short overflow caught in a widened signed domain) → `reason[4:0]={POS,NOTL,BAND,QTY,KILL}` bitmap (reports **every** failing limit, not just the first) → `accept=req_valid&(reason==0)`, **registered decision = deterministic 1-clock latency independent of outcome** (accept, one-limit-reject, all-five-reject all resolve in the *same* cycle count — worst-case == typical, the metric that wins in HFT), **signed net-position accumulator** (`+`long/`−`short) committed **only on the accepting edge** so back-to-back 1-order/clock bursts each see their predecessor's position with no SW round-trip and no race, rejected orders provably **hold** the position, per-side collar + request echo for the egress stage + 1-cycle `viol_o` reject pulse, latch-free `default_nettype none`/parameterized `PW/QW/POSW/NOTW`, independent golden-model 1-deep-pipeline scoreboard TB (4025 checks: reset, every reason isolated incl. long+short position overflow, accept-holds-on-reject proof, back-to-back bursts, live kill toggle, 4000 random) — waveform is a **real captured VCD** | [`Day26`](./Day26) |
| 27 | Direct-Mapped L2 Limit Order Book + BBO Engine | **compute heart of the HFT tick-to-trade path** (sits between Day 25's feed parser and Day 26's risk gate) — the live L2 book + the one pair of numbers a quoter reads every tick: **best-bid / best-offer** (top of book), a **direct-mapped price-indexed** book (`bid_q[LEVELS]`/`ask_q[LEVELS]`) instead of a software tree/heap so top-of-book is **not** an `O(log N)` cache-jittery pointer walk, one market-data event/clock `{side, op(ADD/REMOVE), level, qty}` with **saturating** qty math (ADD clamp `QMAX`, REMOVE clamp 0), **parallel BBO extraction every cycle** (`occupied[i]=(qty[i]!=0)` → best bid = HIGHEST occupied level, best ask = LOWEST → balanced priority-encoder tree whose depth is fixed by `LEVELS`, **not** by occupancy ⇒ 1-level book and full book resolve in the **same single clock**), BBO computed from the **next-state** book so back-to-back 1-event/clock bursts stay coherent (never a stale top), `both_valid`/`spread`/**`crossed`** (locked/crossed market, `bid_level≥ask_level`) in the same cone, **registered outputs ⇒ deterministic occupancy-independent 1-clock event→BBO latency (worst == typical)**, latch-free `default_nettype none`/parameterized `LEVELS`/`QW`, independent **linear-scan golden-model** 1-deep-pipeline scoreboard TB (5027 checks: reset, empty, best-bid/ask tracking, remove-to-empty fallback, saturating over/underflow, crossed market, full tear-down, back-to-back burst, 5000 random) — waveform is a **real captured VCD** | [`Day27`](./Day27) |
| 28 | Redundant A/B Market-Data Feed Arbiter (line arbitration) | **the very front door of the HFT tick-to-trade path** — the ingest stage in front of Day 25's parser that collapses the exchange's **two redundant multicast feeds** (line A + line B, the same stream published twice) into one clean, dedup'd, strictly in-order stream, all in fixed registered clocks; **duplicate suppression** = a single direct-mapped slot `valid`-bit test (a seq already held on either line is dropped + counted, the redundancy payoff — line A classified before B so a simultaneous pair resolves A-stored/B-dup), **reorder** via a `WIN=2**WIN_LOG2` **direct-mapped window** (slot = `seq mod WIN`; within-window residues are unique ⇒ no CAM/no search/no sort — each line is already in order, so you only need a window wide enough to absorb A/B skew), **in-order drain** of `slot[expected]` (≤1 forward/clock, `expected++` only when present), **modular-arithmetic classify** `off = seq−expected` (`<WIN`⇒in-window, top-half⇒behind/stale-dup, else⇒beyond-window **`far_o`** drop, no slot corruption), **bounded-timeout gap handling** (a hole at `expected` while later seqs are buffered = positive evidence of a both-lines loss ⇒ a fixed `GAP_TIMEOUT` counter waits for a late copy, then pulses **`gap_o`/`gap_seq_o`** and skips — exactly one `expected` advance/clock by forward *or* skip ⇒ provable forward-progress + **worst-case latency == typical** even under packet loss), saturating `stat_fwd/dup/gap` perf counters, latch-free `default_nettype none`/parameterized `SEQ_W`/`DATA_W`/`WIN_LOG2`/`GAP_TIMEOUT`, independent plain-array golden-model 1-deep-pipeline scoreboard TB (4020 checks: reset, in-order fwd, A/B dup-suppress, out-of-order reorder, single-line-drop redundancy cover, both-lines gap timeout+skip, beyond-window far-drop, stale-dup, 4000 random biased around live `expected`) — waveform is a **real captured VCD** | [`Day28`](./Day28) |
| 29 | Cut-Through Order-Entry Egress Serializer (wire encoder) | **the last hop of the HFT tick-to-trade path** — the egress stage *behind* Day 26's risk gate that turns an accepted parallel order descriptor `{token, side, price, shares, symbol}` into the exchange's binary order-entry wire message (simplified **OUCH-style "Enter Order"**) streamed one byte/clock onto the SerDes/MAC lane — the exact **inverse of Day 25's feed parser**, the point where "tick-to-**trade**" becomes the trade; **cut-through assembly** = the full big-endian frame **and** its 8-bit XOR checksum are built **combinationally** from the live inputs and captured into one frame register on the accepting edge (no store-and-forward, no buffer copy — first byte can leave the very next clock), **fixed 17-byte frame** (`'O'` type / 32b token / `'B'`\|`'S'` side / 32b price / 32b shares / 16b symbol / XOR-checksum trailer) ⇒ every order serializes in the **same occupancy-independent number of clocks** (**worst-case latency == typical**), byte-serializer FSM (`msg_r[(TOTAL-1-idx)*8+:8]`, `idx` counter, `m_last` on the checksum byte) feeding a textbook **2-slot skid buffer** (`EMPTY→BUSY→FULL` micro-FSM) so the AXI-Stream-like `{m_valid, m_ready, m_data, m_last}` egress is **fully registered** (short comb path ⇒ high fmax) **and** absorbs a downstream `m_ready` stall **with no drop / no duplicate** while sustaining 1 byte/clock, running XOR line-integrity checksum, latch-free `default_nettype none`/parameterized `TOKEN_W`/`PRICE_W`/`QTY_W`/`SYM_W`/`MSG_TYPE`, independent golden-reassembly per-beat scoreboard TB under **random backpressure** (5236 byte checks: all-zero/all-ones/typical/max/alternating/unit/sign corners + 300 random orders, checks data + `m_last` position + exact byte count, drives the skid into `FULL`) — waveform is a **real captured VCD** | [`Day29`](./Day29) |
| 30 | Hardware Nanosecond-Timestamp & Tick-to-Trade Latency Monitor | **HFT tick-to-trade instrumentation stage** — measure end-to-end latency *in the fabric* (no CPU / no syscall / no observer effect), the metric that decides HFT races; **NCO / DDS fractional-nanosecond timestamp** (`phase += inc_i`, Q8.16 ns/cycle → `now = phase>>FRAC_W` ⇒ sub-ns resolution from an integer counter; `inc_i` doubles as the **PTP / IEEE-1588 frequency-correction word**), `run_i` freeze gate; **tag-matched direct-mapped timestamp capture** (`t0` stamps+arms `t0_ts[tag]`, `t1` retires — **no CAM / no search / O(1)**, overlapping probes retire in any order), **wrap-safe modular latency** `now − t0_ts[tag]` (survives counter roll-over), **orphan** `t1`-without-`t0` isolation (never pollutes stats); **power-of-two latency histogram** (`floor(log2 lat)` saturating bins, top bin = **tail catch-all** — the p99/p99.9 the mean hides) + rolling min/max/last/cnt/sum(mean) + `outstanding` popcount; **registered outputs ⇒ deterministic occupancy-independent 1-clock `t1`→measurement latency (worst == typical)**, latch-free `default_nettype none` / parameterized `TS_W`/`FRAC_W`/`INC_W`/`TAG_W`/`NBINS`; independent golden-model 1-deep-pipeline scoreboard TB (75,166 checks: reset, NCO advance/hold, single/overlapping/out-of-order measurements, orphan, same-cycle `t0`+`t1`, every histogram bin, 4000 random) — waveform is a **real captured VCD** | [`Day30`](./Day30) |
| 31 | Tick-to-Trade Marketable-Order Trigger Engine | **the trade-decision node of the HFT tick-to-trade path** — sits between Day 27's book/BBO engine and Day 26's pre-trade risk gate, the block where a *quote* becomes a *trade*: a table of `N` resting **strategy rules** `{arm, side, lim_px, qty, token}` continuously evaluated against the live BBO, firing exactly one child order the cycle a rule turns **marketable** (BUY: `ask_ok & ask≤lim`, SELL: `bid_ok & bid≥lim`); the whole decision — `N` **parallel marketable comparators** → **priority encoder** (lowest index = strategy priority) → **throttle gate** → registered order-field mux — is **one combinational cone** on the current registered state ⇒ **deterministic occupancy-independent 1-clock BBO→fire latency (worst == typical)** whose encoder depth is fixed by `N`, not by how many rules match; three ULL throttles keep a fabric that reacts in one clock from machine-gunning the market — **one-shot arm-clear** (fire clears `arm[win_idx]` ⇒ a rule fires *exactly once* per arm, killing the classic duplicate-order-flood bug), runtime **cooldown** counter (post-fire quiet window, HW rate-limit), **max-inflight** cap (≤`MAX_INFLIGHT` orders outstanding awaiting `ack_i`, bounds capital/message-credit at risk) — with a marketable-but-throttled tick raising `blocked_o` instead of `fire_o`; single-cycle rule config port (a same-cycle `cfg_we` **wins over** the one-shot arm-clear so a slot can re-arm on its firing edge), underflow-safe inflight counter, `armed_cnt`/`inflight`/`cooldown_active` status, latch-free `default_nettype none`/parameterized `N`/`PX_W`/`QW`/`TOKW`/`COOLDOWN_W`/`MAX_INFLIGHT`, independent golden-model 1-deep-pipeline scoreboard TB (4033 checks: reset, BUY/SELL boundary triggers, one-shot no-refire, cooldown block+fire, inflight-cap block + ack-release, lowest-index priority, ok-flag gating, disarm, 4000 random) — waveform is a **real captured VCD** | [`Day31`](./Day31) |
| 32 | Reed–Solomon RS(n,k) Systematic Encoder over GF(2^M) | the workhorse **symbol-level ECC** of the real world (CD/DVD/Blu-ray, QR, DVB/ATSC, DSL, RAID-6, deep-space CCSDS, flash controllers) — a streaming systematic encoder that appends `2T` parity symbols so the `N=K+2T` codeword is a multiple of `g(x)=∏(x−α^(FCR+i))`, giving **`T`-symbol error correction** (a burst that trashes a whole byte still costs only one of `T` credits — unlike [Day 10](./Day10)'s single-*bit* Hamming SECDED over GF(2)); the standout is that the **entire finite field GF(2^M) *and* the generator's `2T` tap constants are derived at ELABORATION time** by constant SystemVerilog functions from just `{M,T,PRIM,FCR}` — **zero hand-coded lookup tables**: `gf_mul` is a parameter-general combinational shift-and-reduce ("Russian-peasant") cone folding in the primitive polynomial `PRIM`, and `g(x)` is built by iteratively multiplying the monomials `(x−α^(FCR+i))` in GF(2^M); the core is a `2T`-symbol **Galois-field LFSR** (the polynomial-division / remainder circuit) computing `parity = message(x)·x^(2T) mod g(x)` at **1 symbol/clock** — message symbols pass straight through (**systematic**, `cw_is_parity=0`), then the remainder registers `b[2T−1..0]` shift out as parity (`cw_is_parity=1`, `cw_last`+`done` on the final symbol), with a parallel `par_flat_o` view; deterministic `S_IDLE→S_MSG(count K)→S_PAR(emit 2T)` framing, reset-safe, latch-free `default_nettype none`, parameterized `M`/`T`/`K`/`PRIM`/`FCR`/`ALG` (default shortened **RS(16,8)/GF(256)**, `T=4`; retargets to **DVB RS(255,239)** or **RS(15,11)/GF(16)** by parameter only); independent **fully-decoupled golden model** TB — textbook GF(2^M) polynomial long-division parity **and** the defining **syndrome-zero property** `c(α^(FCR+s))=0` for all `2T` roots (Horner, sharing no code path with the DUT) **and** systematic-passthrough **and** error-injection sanity (a flipped symbol must break a syndrome), directed corners (all-zero/all-ones/unit-head/unit-tail/ramp/known-msg, parity cross-checked against a Python GF(256) model) + 400 random blocks = **20,308 checks, 0 errors** — waveform is a **real captured VCD** | [`Day32`](./Day32) |
| 33 | AES-128 Block-Cipher Encryption Core (iterative, FIPS-197) | the symmetric block cipher under **MACsec (802.1AE) / IPsec / TLS record / self-encrypting drives** — a synthesizable AES-128 encryptor that turns one 128-bit block into ciphertext in a **fixed, data-independent 11 clocks** (initial key-add + 10 rounds), a **substitution–permutation network over GF(2⁸)** (reduction poly `0x11B`): **SubBytes** (16× S-box = field inverse + affine, the only nonlinear/confusion step), **ShiftRows** (row `r` cyclically `<<< r`, cross-column diffusion), **MixColumns** (per-column fixed MDS `{02 03 01 01}` circulant via `xtime` shift-and-reduce, skipped on the last round), **AddRoundKey** (128-bit XOR); the standout is an **on-the-fly key schedule** — one round key produced **per clock** by `RotWord`/`SubWord`(shared S-box)/`Rcon` word-chain XORs, so the core holds exactly **one** 128-bit key register **instead of the 176-byte expanded schedule RAM**; a single round datapath **reused 10×** (small area) with a last-round MixColumns-bypass mux and a round-counter FSM (`IDLE→round 1..10→IDLE`, `busy`/`done`/`valid`, held `ct_o`); latency is **outcome-independent (worst-case == typical)** ⇒ no datapath timing side channel, `default_nettype none`/latch-free/no vendor primitives; independent golden-model scoreboard TB whose **S-box is DERIVED, not copied** (GF(2⁸) multiplicative inverse by exhaustive search + affine `inv⊕(inv⋘1..4)⊕0x63` — catches any single wrong ROM byte) and is **anchored to the two published FIPS-197 KATs** (App. B `2b7e…→3925841d…`, App. C.1 `0001…/0011…→69c4e0d8…`) via `$fatal` before it ever judges the DUT, plus directed corners (all-zero/all-ones/`key==pt`/unit-bit/split) + 500 random `(key,pt)` blocks + per-block watchdog & global timeouts = **510 checks, 0 errors** — waveform is a **real captured VCD** | [`Day33`](./Day33) |
| 34 | SHA-256 Cryptographic Hash Core (iterative, FIPS 180-4) | the hash workhorse under **TLS records / Git objects / secure-boot & software-update signing / HMAC / PBKDF2 / IPFS / Bitcoin proof-of-work** — a synthesizable SHA-256 engine that absorbs one already-padded **512-bit block per launch** and folds it into the **256-bit digest** in a **fixed, data-independent 66 clocks** (1 load + 64 rounds + feed-forward), chaining any number of blocks (**Merkle–Damgård**) to hash a message of any length; the same primitive *family* as [Day 33](./Day33)'s AES but a **one-way compression function** (not an invertible cipher) built from **bit-level mod-2³² mixing** (`Ch`,`Maj`, and the Σ/σ `ror`/shift-xor functions) rather than a GF(2⁸) SPN; the **hardware standout is the message schedule** — the 64 expanded words `W[0..63]` are **never stored as 64 registers** but kept in a **16-word CIRCULAR WINDOW** `w[0..15]` that shift-registers one word/clock, round `t` consuming `w[0]`(`=W[t]`) while the recurrence `W[t+16]=σ1(w[14])+w[9]+σ0(w[1])+w[0]` is evaluated combinationally and shifted into `w[15]` ⇒ the whole schedule costs **16 regs + one adder cone, not a 2 Kbit W-RAM**; **dual-use hash registers** `H0..H7` hold the running chaining digest **and** serve as the **Davies–Meyer feed-forward** source (working state `a..h` loaded from them each block, final add commits back — no shadow copy), `first_i` seeds the **IV** on the first block then blocks chain automatically, 64 round constants `K[t]` baked as an elaboration `case` (no `$readmem`), **outcome-independent 66-clock/block latency ⇒ no data-dependent timing side channel** (worst == typical), `default_nettype none`/latch-free/no vendor primitives; independent golden-model scoreboard TB whose reference uses the **FULL 64-word schedule** (structurally unlike the DUT's rolling window) and is **anchored to 3 published NIST KATs** (`""`→`e3b0c442…`, `"abc"`→`ba7816bf…`, 56-byte 2-block→`248d6a61…`) via `$fatal` before it judges the DUT, plus directed corners (empty/1-byte/**55 B** max-single-block/**56·64·112 B** multi-block boundaries/200 B zeros/130 B ones) + 300 random-length random-content messages + per-block & global timeouts = **309 checks, 0 errors** — waveform is a **real captured VCD** | [`Day34`](./Day34) |

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
├── Day26/
│   ├── risk_gate.sv               # RTL design (pre-trade risk check gate / market-access firewall)
│   ├── tb_risk_gate.sv            # self-checking testbench (independent golden model)
│   ├── Makefile                   # simulator run targets
│   ├── docs/                      # datapath diagram + captured waveform
│   └── README.md                  # project write-up
├── Day27/
│   ├── order_book_bbo.sv          # RTL design (direct-mapped L2 order book + BBO engine)
│   ├── tb_order_book_bbo.sv       # self-checking testbench (independent linear-scan golden book)
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
