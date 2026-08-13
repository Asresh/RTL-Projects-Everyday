#!/usr/bin/env python3
"""Render the riscv_pipeline datapath / circuit diagram to
docs/riscv_pipeline_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, NOT a simulator
capture): the classic 5-stage IF/ID/EX/MEM/WB pipeline with its four pipeline
register banks, the forwarding network feeding the EX operand muxes from the
EX/MEM and MEM/WB stages, the load-use hazard interlock that stalls IF/ID and
bubbles ID/EX, and the EX-stage branch/jump resolution that redirects the PC
and flushes the two younger instructions. Two insets detail the forwarding
priority logic and the hazard/branch control equations the RTL implements.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

IF_C  = "#0369a1"
ID_C  = "#7c3aed"
EX_C  = "#0f766e"
MEM_C = "#b45309"
WB_C  = "#dc2626"
REG_C = "#334155"   # pipeline register banks
FWD_C = "#0891b2"   # forwarding paths
HAZ_C = "#b45309"   # hazard / stall
RED_C = "#dc2626"   # redirect / flush
INK   = "#1f2937"
MUT   = "#6b7280"

fig, ax = plt.subplots(figsize=(17.0, 10.6))
ax.set_xlim(0, 174)
ax.set_ylim(0, 104)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=9.5, lw=1.9):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def preg(x, y, h, label):
    ax.add_patch(plt.Rectangle((x, y), 2.4, h, facecolor=REG_C,
                 edgecolor=REG_C, alpha=0.9, zorder=3))
    ax.text(x + 1.2, y - 2.4, label, ha="center", va="top",
            fontsize=8.2, color=REG_C, fontweight="bold")


def arrow(x1, y1, x2, y2, c=INK, lw=1.8, ls="-", rad=0.0, ms=13):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=ms, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def lab(x, y, t, c=INK, fs=8.0, style="italic", ha="center"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c,
            fontstyle=style, zorder=5)


# --------------------------------------------------------------------------- #
ax.text(87, 101, "Day 38  5-Stage Pipelined RISC-V RV32I Core — datapath / circuit block diagram",
        ha="center", va="center", fontsize=14.5, fontweight="bold", color=INK)
ax.text(87, 96.5, "hand-drawn schematic of the built circuit (matplotlib — NOT a simulator capture)",
        ha="center", va="center", fontsize=9.4, color=MUT, fontstyle="italic")

ROWY, ROWH = 58, 20            # main datapath band

# stage header banners (raised to the top, clear of the datapath labels)
BANNER_Y = 90.0
stages = [("IF", IF_C, 6, 24), ("ID", ID_C, 34, 30), ("EX", EX_C, 72, 34),
          ("MEM", MEM_C, 116, 24), ("WB", WB_C, 148, 22)]
for nm, c, x, w in stages:
    ax.add_patch(plt.Rectangle((x, BANNER_Y), w, 4.2, facecolor=c,
                 alpha=0.14, edgecolor=c, lw=1.2, zorder=1))
    ax.text(x + w / 2, BANNER_Y + 2.1, f"{nm} stage", ha="center", va="center",
            fontsize=10.5, color=c, fontweight="bold")

# ---- IF ------------------------------------------------------------------- #
box(6, ROWY + 11, 10, 8, "PC", IF_C, fc="#eff6ff")
box(6, ROWY, 10, 8, "IMEM\n(1K words)", IF_C, fc="#eff6ff", fs=8.6)
arrow(11, ROWY + 11, 11, ROWY + 8, IF_C)            # PC -> IMEM
arrow(16, ROWY + 4, 24, ROWY + 4, IF_C)             # IMEM -> IF/ID
lab(20, ROWY - 2.4, "instr", IF_C, 7.6, "normal")

preg(24, ROWY - 4, ROWH + 8, "IF/ID")

# ---- ID ------------------------------------------------------------------- #
box(30, ROWY + 11, 16, 9, "Decode +\nControl", ID_C, fc="#f5f3ff", fs=8.8)
box(30, ROWY - 1, 16, 9, "Register File\n32 x 32b (WB-fwd)", ID_C, fc="#f5f3ff", fs=8.2)
box(50, ROWY + 4.5, 10, 8, "Imm\ngen", ID_C, fc="#f5f3ff", fs=8.4)
arrow(26.4, ROWY + 4, 30, ROWY + 3.5, REG_C)
arrow(46, ROWY + 8, 50, ROWY + 8, ID_C)
arrow(60, ROWY + 8, 64, ROWY + 8, ID_C)

preg(64, ROWY - 4, ROWH + 8, "ID/EX")

# ---- EX ------------------------------------------------------------------- #
box(70, ROWY + 12, 9, 8, "fwd\nmuxA", EX_C, fc="#ecfdf5", fs=7.8)
box(70, ROWY - 0.5, 9, 8, "fwd\nmuxB", EX_C, fc="#ecfdf5", fs=7.8)
box(84, ROWY + 6, 12, 12, "ALU", EX_C, fc="#ecfdf5", fs=10.5)
box(84, ROWY - 6.5, 14, 5.5, "branch cmp\n+ target add", EX_C, fc="#ecfdf5", fs=7.8)
arrow(79, ROWY + 16, 84, ROWY + 15, EX_C)
arrow(79, ROWY + 3.5, 84, ROWY + 9, EX_C)
arrow(66.4, ROWY + 15, 70, ROWY + 15, REG_C)
arrow(66.4, ROWY + 2, 70, ROWY + 2, REG_C)

preg(104, ROWY - 4, ROWH + 8, "EX/MEM")
arrow(96, ROWY + 12, 104, ROWY + 12, EX_C)          # ALU result -> EX/MEM
lab(100, ROWY + 14.2, "alu/link", EX_C, 7.2, "normal")

# ---- MEM ------------------------------------------------------------------ #
box(110, ROWY + 2, 16, 14, "Data Memory\n1K words\nLB/LH/LW/LBU/LHU\nSB/SH/SW", MEM_C,
    fc="#fffbeb", fs=7.8)
arrow(106.4, ROWY + 9, 110, ROWY + 9, REG_C)

preg(130, ROWY - 4, ROWH + 8, "MEM/WB")
arrow(126, ROWY + 12, 130, ROWY + 12, MEM_C)        # load data / alu
lab(128, ROWY + 14.2, "wb val", MEM_C, 7.2, "normal")

# ---- WB ------------------------------------------------------------------- #
box(136, ROWY + 5, 14, 9, "WB mux\n(mem / alu)", WB_C, fc="#fef2f2", fs=8.4)
arrow(132.4, ROWY + 9.5, 136, ROWY + 9.5, REG_C)
box(154, ROWY + 5, 16, 9, "commit trace\n(rd, val, store)", WB_C, fc="#fef2f2", fs=8.0)
arrow(150, ROWY + 9.5, 154, ROWY + 9.5, WB_C)

# ---- register-file writeback path (WB -> ID) ------------------------------ #
ax.add_patch(FancyArrowPatch((143, ROWY + 5), (38, ROWY - 6),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.7, color=WB_C,
             linestyle="--", zorder=2, connectionstyle="arc3,rad=0.14"))
lab(90, ROWY - 9.5, "write-back to register file (write-through so a WB in the same "
    "cycle as an ID read is seen)", WB_C, 8.0, "italic")

# ===== forwarding network ================================================== #
# EX/MEM -> EX operand muxes
ax.add_patch(FancyArrowPatch((105, ROWY + ROWH + 3.6), (74.5, ROWY + 20),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.9, color=FWD_C,
             connectionstyle="arc3,rad=-0.25", zorder=6))
# MEM/WB -> EX operand muxes
ax.add_patch(FancyArrowPatch((131, ROWY + ROWH + 3.6), (74.5, ROWY + 22),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.9, color=FWD_C,
             connectionstyle="arc3,rad=-0.3", zorder=6))
lab(101, ROWY + ROWH + 6.2, "forward  EX/MEM  &  MEM/WB  results  →  EX operands",
    FWD_C, 8.6, "normal")

# ===== redirect / flush ==================================================== #
ax.add_patch(FancyArrowPatch((90, ROWY - 6.5), (11, ROWY + 10.5),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.9, color=RED_C,
             connectionstyle="arc3,rad=0.32", zorder=6))
lab(45, ROWY - 14.5, "taken branch / jump resolved in EX → redirect PC + flush IF/ID & ID/EX "
    "(2-cycle penalty)", RED_C, 8.4, "italic")

# ===== hazard unit ========================================================= #
box(30, ROWY + 26, 26, 5.5, "Hazard / load-use interlock", HAZ_C, fc="#fffbeb", fs=9)
arrow(43, ROWY + 26, 43, ROWY + 20.2, HAZ_C, lw=1.4, ls="--")     # -> ID region
ax.add_patch(FancyArrowPatch((30, ROWY + 28.7), (12, ROWY + 19.2),
             arrowstyle="-|>", mutation_scale=12, linewidth=1.4, color=HAZ_C,
             linestyle="--", connectionstyle="arc3,rad=0.2", zorder=6))
lab(21, ROWY + 24.8, "freeze PC", HAZ_C, 7.6, "normal")

# clock / reset rail
ax.plot([6, 170], [ROWY - 20, ROWY - 20], color=MUT, lw=1.1, ls=":")
lab(6, ROWY - 20, "clk / rst_n", MUT, 8.2, "normal", ha="left")

# ===== INSET A : forwarding priority ======================================= #
ax.text(30, 30, "Forwarding unit (per EX source operand)", ha="left",
        fontsize=10.2, fontweight="bold", color=FWD_C)
fa = [
    "priority  (most-recent producer wins):",
    "  if  EX/MEM.regwrite & EX/MEM.rd!=0 & ==rs  → take EX/MEM ALU result",
    "  elif MEM/WB.regwrite & MEM/WB.rd!=0 & ==rs → take MEM/WB write value",
    "  else                                        → take register-file read",
    "loads never forward from EX/MEM (data not ready there) — the load-use",
    "interlock guarantees the consumer is in EX only when the load is in MEM/WB.",
]
for i, t in enumerate(fa):
    ax.text(30, 26 - i * 3.1, t, ha="left", va="center", fontsize=8.0,
            color=INK, family="monospace")

# ===== INSET B : hazard / branch control =================================== #
ax.text(108, 30, "Hazard & control-flow logic", ha="left",
        fontsize=10.2, fontweight="bold", color=HAZ_C)
fb = [
    ("stall  = ID/EX.memread & (ID/EX.rd!=0) &", HAZ_C),
    ("         (ID/EX.rd==rs1 | ID/EX.rd==rs2)      → 1 bubble", HAZ_C),
    ("redirect = ID/EX.valid & (jump | (branch & taken))", RED_C),
    ("target   = jalr ? (rs1+imm)&~1 : pc+imm", RED_C),
    ("on stall  : hold PC & IF/ID, inject bubble into ID/EX", INK),
    ("on redirect: PC←target, squash IF/ID & ID/EX (flush)", INK),
]
for i, (t, c) in enumerate(fb):
    ax.text(108, 26 - i * 3.1, t, ha="left", va="center", fontsize=8.0,
            color=c, family="monospace")

# throughput banner
ax.text(87, 3.0,
        "in-order · single-issue · 1 instruction/clock peak (no hazard)   |   "
        "load-use = 1 stall cycle   |   taken branch/jump = 2 flush cycles   |   "
        "verified vs a golden RV32I ISS on every committed instruction",
        ha="center", va="center", fontsize=9.2, color=INK,
        bbox=dict(boxstyle="round,pad=0.5", fc="#f8fafc", ec="#cbd5e1"))

plt.tight_layout()
fig.savefig("docs/riscv_pipeline_block.png", dpi=140, facecolor="white")
print("wrote docs/riscv_pipeline_block.png")
