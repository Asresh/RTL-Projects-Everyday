#!/usr/bin/env python3
"""Render the seq_divider circuit / block diagram to docs/seq_divider_block.png.

This is a schematic of the *built* circuit (hand-drawn with matplotlib, not a
simulator capture): the restoring-division datapath (the combined {acc, quo}
shift register, the compare/subtract unit and the quotient-bit feedback) plus
the control path (the IDLE/CALC/DONE FSM and the iteration down-counter).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

DP_C  = "#0f766e"   # datapath
SUB_C = "#b45309"   # compare / subtract
CT_C  = "#2563eb"   # control
Q_C   = "#c026d3"   # quotient
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(14, 8.6))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.8, style="round"):
    if style == "round":
        p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.6,rounding_size=2",
                           linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3)
    else:
        p = Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                      facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.8, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=15, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def lbl(x, y, t, c=INK, fs=9, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, zorder=5,
            fontstyle=style)


# ---- control / datapath bands -----------------------------------------------
ax.add_patch(Rectangle((2, 66), 96, 26, facecolor=CT_C, alpha=0.05, zorder=0))
ax.add_patch(Rectangle((2, 8), 96, 52, facecolor=DP_C, alpha=0.05, zorder=0))
ax.text(50, 94, "seq_divider — restoring shift-subtract divider",
        ha="center", fontsize=13, color=INK, fontweight="bold")
lbl(9, 89, "control", CT_C, fs=10, ha="left", style="italic")
lbl(9, 57, "datapath", DP_C, fs=10, ha="left", style="italic")

# ---- control path -----------------------------------------------------------
box(20, 72, 30, 14,
    "control FSM\nIDLE → CALC → DONE\n(one step per clock)", CT_C,
    fc="#eff6ff", fs=10)
box(58, 72, 26, 14,
    "iteration counter\ncount: WIDTH → 0", CT_C, fc="#eff6ff", fs=9.5)
arrow(50, 79, 58, 79, CT_C); lbl(54, 81.5, "load / --", CT_C, style="normal")
arrow(58, 76, 50, 76, CT_C, rad=0.0); lbl(54, 73.5, "count==0", CT_C, style="normal")

arrow(6, 82, 20, 82, CT_C);  lbl(5.5, 82, "start", CT_C, ha="right", style="normal")
arrow(35, 72, 35, 60, CT_C, ls=(0, (4, 3)))     # FSM controls datapath
lbl(37, 66, "shift / sub enable", CT_C, ha="left")

# ---- datapath: input latches ------------------------------------------------
box(4, 44, 22, 9, "divi  ← divisor", DP_C, fc="#f0fdfa", fs=9.5)
arrow(2, 48.5, 4, 48.5, DP_C); lbl(1.5, 48.5, "divisor", DP_C, ha="right", style="normal")

# ---- combined shift register {acc, quo} -------------------------------------
box(30, 40, 44, 12,
    "combined shift register  { acc , quo }\n"
    "acc = partial remainder   |   quo = dividend → quotient", DP_C,
    fc="#f0fdfa", fs=9.5)
arrow(2, 43, 30, 43, DP_C); lbl(1.5, 43, "dividend", DP_C, ha="right", style="normal")
lbl(52, 54.5, "shift left 1 each cycle  (acc_shift = {acc, quo[MSB]})",
    DP_C, fs=8.5)

# ---- compare / subtract -----------------------------------------------------
box(30, 22, 44, 11,
    "compare & subtract\nif (acc_shift >= divi):  acc -= divi ,  q_bit = 1\n"
    "else:                          q_bit = 0", SUB_C, fc="#fff7ed", fs=9)
arrow(26, 48.5, 30, 30, SUB_C, rad=-0.1)            # divi into subtract
lbl(26, 38, "divi", SUB_C, ha="center", style="normal")
arrow(45, 40, 45, 33, DP_C)                          # acc_shift down to compare
lbl(41, 36.5, "acc_shift", DP_C, ha="center")
arrow(52, 33, 52, 40, SUB_C)                         # acc-b back up
lbl(56, 36.5, "acc'", SUB_C, ha="center")
# quotient bit feedback into quo LSB
arrow(66, 25, 77, 25, Q_C)
arrow(77, 25, 77, 44, Q_C, rad=0.0)
arrow(77, 44, 74, 44, Q_C)
lbl(70, 22, "q_bit → quo[0]", Q_C, ha="center", style="normal")

# ---- outputs ----------------------------------------------------------------
box(80, 40, 16, 9, "quotient\n= quo", Q_C, fc="#fdf4ff", fs=9)
box(80, 27, 16, 9, "remainder\n= acc", DP_C, fc="#f0fdfa", fs=9)
arrow(74, 45, 80, 45, Q_C)
arrow(74, 41, 80, 31.5, DP_C, rad=0.1)
arrow(90, 72, 90, 49, CT_C, ls=(0, (4, 3)))          # done latches outputs
lbl(92, 60, "done", CT_C, ha="left", style="normal")
arrow(96, 78, 99, 78, CT_C); lbl(99.4, 78, "busy / done", CT_C, ha="left", style="normal")

ax.text(50, 4,
        "Divide-by-zero policy: dividend/0 -> quotient = all-ones, remainder = "
        "dividend (div_by_zero asserted). Produced naturally by the algorithm.",
        ha="center", fontsize=9, color="#4b5563", fontstyle="italic")

fig.tight_layout()
fig.savefig("docs/seq_divider_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/seq_divider_block.png")
