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
