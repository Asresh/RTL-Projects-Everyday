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
