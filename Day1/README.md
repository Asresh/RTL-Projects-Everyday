# Day 1 — Parameterized Synchronous FIFO

A single-clock FIFO (First-In-First-Out) buffer written in SystemVerilog, with a
fully self-checking testbench that uses a queue-based golden reference model.

FIFOs are one of the most common building blocks in digital design — they buffer
data between two parts of a circuit that produce and consume at different rates.
This one is parameterizable in both **data width** and **depth**.

---

## Features

- Parameterized `DATA_WIDTH` and `DEPTH` (depth need **not** be a power of two).
- Status flags: `full`, `empty`, and a live occupancy `count`.
- Registered read — read data appears one clock **after** `rd_en` (clean timing).
- Overflow / underflow safe: writes when full and reads when empty are ignored.
- Handles **simultaneous read and write** in the same cycle.

---

## Parameters

| Parameter    | Default | Description                     |
|--------------|---------|---------------------------------|
| `DATA_WIDTH` | 8       | Width of each stored data word  |
| `DEPTH`      | 16      | Number of entries the FIFO holds|

## Ports

| Port    | Dir | Width             | Description                              |
|---------|-----|-------------------|------------------------------------------|
| `clk`   | in  | 1                 | System clock                             |
| `rst_n` | in  | 1                 | Active-low asynchronous reset            |
| `wr_en` | in  | 1                 | Write enable                             |
| `rd_en` | in  | 1                 | Read enable                              |
| `din`   | in  | `DATA_WIDTH`      | Write data                               |
| `dout`  | out | `DATA_WIDTH`      | Read data (valid one cycle after `rd_en`)|
| `full`  | out | 1                 | High when FIFO is full                   |
| `empty` | out | 1                 | High when FIFO is empty                  |
| `count` | out | `$clog2(DEPTH)+1` | Number of valid entries currently stored |

---

## Block diagram

```
              wr_en                                 rd_en
                │                                     │
          ┌─────▼─────┐                         ┌─────▼─────┐
   din ──▶│  write    │      ┌───────────┐      │   read    │──▶ dout
          │  pointer  │─────▶│  memory   │─────▶│  pointer  │
          └───────────┘      │  (DEPTH)  │      └───────────┘
                             └───────────┘
                                   │
                            ┌──────▼──────┐
                            │  occupancy  │──▶ count / full / empty
                            │   counter   │
                            └─────────────┘
```

---

## How it works

- **Two pointers** (`wr_ptr`, `rd_ptr`) index a memory array; each advances on a
  successful write / read and wraps back to 0 at the top of the buffer.
- **An occupancy counter** (`count`) increments on a write-only cycle, decrements
  on a read-only cycle, and holds on simultaneous or idle cycles. `full` and
  `empty` are derived directly from it — this avoids the classic ambiguity of
  comparing pointers alone.
- Reads are **registered**, so `dout` is stable and timing-friendly for synthesis.

---

## Files

| File                | Description                              |
|---------------------|------------------------------------------|
| `sync_fifo.sv`      | RTL design under test                    |
| `tb_sync_fifo.sv`   | Self-checking testbench + reference model|
| `Makefile`          | Run targets for common simulators        |

---

## Run the simulation

```bash
# Verilator (open source)
make verilator

# Synopsys VCS
make vcs

# Siemens Questa / ModelSim
make questa
```

Expected output ends with:

```
Checks performed : <N>
Errors           : 0
RESULT: *** PASS ***
```

A `sync_fifo.vcd` waveform is also produced for viewing in GTKWave or your
simulator's waveform viewer.

---

## What the testbench checks

1. FIFO is `empty` right after reset.
2. Filling `DEPTH` words asserts `full`.
3. A write while `full` is dropped (no overflow).
4. Draining all words asserts `empty`.
5. Simultaneous read + write behaves correctly.
6. 200 cycles of randomized read/write traffic, fully scoreboarded against the
   reference queue, with a continuous `count` vs. reference-size check.
