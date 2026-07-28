#!/usr/bin/env python3
"""Render the axi4lite_regs circuit / block diagram to docs/axi4lite_regs_block.png.

This is a schematic of the *built* circuit (hand-drawn with matplotlib, not a
simulator capture): the five AXI4-Lite channels, the write path (AW+W capture ->
WSTRB byte-mask -> register file -> B response), the read path (AR -> address
decode -> read mux -> R), the address decoder driving OKAY/SLVERR, and the
register file with its RW / RO / W1C map.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

WR_C  = "#2563eb"   # write channels
RD_C  = "#c026d3"   # read channels
DEC_C = "#b45309"   # decode / response
REG_C = "#0f766e"   # register file
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(14.5, 8.8))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.8, style="round"):
    if style == "round":
        p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5,rounding_size=2",
                           linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3)
    else:
        p = Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                      facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.8, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=14, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def lbl(x, y, t, c=INK, fs=9, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, zorder=5,
            fontstyle=style)


ax.text(50, 96, "axi4lite_regs — AXI4-Lite slave register block",
        ha="center", fontsize=13, color=INK, fontweight="bold")

# slave outline
ax.add_patch(Rectangle((21, 8), 78, 82, facecolor="#f8fafc",
                       edgecolor="#cbd5e1", lw=1.4, zorder=0))
lbl(60, 87, "AXI4-Lite slave", "#64748b", fs=10, style="italic")

# ---- master side channel labels ---------------------------------------------
lbl(3, 92, "AXI4-Lite master (BFM)", "#334155", fs=10, ha="left", style="italic")

# ---- write path -------------------------------------------------------------
box(26, 70, 26, 12,
    "write capture\nAW addr + W data/WSTRB\n(1 outstanding)", WR_C,
    fc="#eff6ff", fs=9)
arrow(6, 79, 26, 79, WR_C);  lbl(5.5, 79, "AW: awaddr/awvalid/awready", WR_C, ha="right", style="normal")
arrow(6, 73, 26, 73, WR_C);  lbl(5.5, 73, "W: wdata/wstrb/wvalid/wready", WR_C, ha="right", style="normal")

box(60, 70, 24, 12,
    "WSTRB byte-mask\n& commit\n(RW / RO / W1C)", DEC_C, fc="#fff7ed", fs=9)
arrow(52, 76, 60, 76, WR_C); lbl(56, 78, "addr/data", WR_C, style="normal")

box(26, 52, 26, 10, "B response\nbvalid / bready", WR_C, fc="#eff6ff", fs=9)
arrow(6, 57, 26, 57, WR_C, rad=0.0); lbl(5.5, 57, "B: bresp/bvalid/bready", WR_C, ha="right", style="normal")
arrow(72, 70, 39, 62, DEC_C, rad=0.15)
lbl(58, 65, "OKAY / SLVERR", DEC_C, style="normal")

# ---- register file ----------------------------------------------------------
box(84, 30, 14, 52,
    "register file\n\n0x00 REG0 RW\n0x04 REG1 RW\n0x08 REG2 RW\n"
    "0x0C REG3 RO\n0x10 REG4 RW\n0x14 REG5 W1C\n0x18 REG6 RW\n0x1C REG7 RW",
    REG_C, fc="#f0fdfa", fs=8.2)
arrow(72, 70, 84, 66, REG_C, rad=-0.15)         # commit -> regfile
lbl(80, 71, "write", REG_C, style="normal")

# ---- read path --------------------------------------------------------------
box(26, 30, 26, 12,
    "read address decode\nAR -> reg select\nmapped?", RD_C, fc="#fdf4ff", fs=9)
arrow(6, 36, 26, 36, RD_C);  lbl(5.5, 36, "AR: araddr/arvalid/arready", RD_C, ha="right", style="normal")

box(60, 30, 22, 12, "read mux\nRO const / regfile / 0", RD_C, fc="#fdf4ff", fs=9)
arrow(52, 36, 60, 36, RD_C); lbl(56, 38, "sel", RD_C, style="normal")
arrow(84, 55, 82, 40, REG_C, rad=0.15)          # regfile -> read mux
lbl(80, 47, "read", REG_C, style="normal")

box(26, 14, 26, 10, "R response\nrdata / rresp\nrvalid / rready", RD_C,
    fc="#fdf4ff", fs=9)
arrow(6, 19, 26, 19, RD_C, rad=0.0); lbl(5.5, 19, "R: rdata/rresp/rvalid/rready", RD_C, ha="right", style="normal")
arrow(60, 33, 39, 24, RD_C, rad=0.12)
lbl(50, 30.5, "data + OKAY/SLVERR", RD_C, style="normal")

ax.text(50, 4,
        "Five VALID/READY channels; WSTRB masks writes at byte granularity; "
        "unmapped addresses return SLVERR; RO writes are ignored (OKAY); "
        "W1C clears written-1 bits.",
        ha="center", fontsize=8.8, color="#4b5563", fontstyle="italic")

fig.tight_layout()
fig.savefig("docs/axi4lite_regs_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/axi4lite_regs_block.png")
