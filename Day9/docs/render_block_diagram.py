#!/usr/bin/env python3
"""Draw the Day9 cordic_sincos micro-architecture as a block diagram (PNG)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10})
fig, ax = plt.subplots(figsize=(15, 8.2))
fig.patch.set_facecolor("white")
ax.set_xlim(0, 100)
ax.set_ylim(0, 56)
ax.axis("off")

BLUE, GREEN, ORANGE, GREY, PUR = "#1f6feb", "#0b8f3a", "#d98a00", "#5a5a5a", "#8250df"

def box(x, y, w, h, text, fc="#eef2ff", ec="#33415c", fs=10, tc="#111", lw=1.4, style="round"):
    p = FancyBboxPatch((x, y), w, h,
                       boxstyle=f"round,pad=0.02,rounding_size={0.6 if style=='round' else 0.01}",
                       fc=fc, ec=ec, lw=lw, zorder=3)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, color=tc, zorder=4)

def arrow(x1, y1, x2, y2, color=GREY, lw=1.6, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                 arrowstyle="-|>", mutation_scale=14, lw=lw, color=color,
                 connectionstyle=f"arc3,rad={rad}", zorder=2, linestyle=ls))

def label(x, y, t, c="#111", fs=9, ha="center", style="normal", w="normal"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, style=style, fontweight=w)

# ---- title ----
ax.text(50, 54.3, "Day 9  cordic_sincos  —  pipelined rotation-mode CORDIC (WIDTH=16, ITER=12)",
        ha="center", va="center", fontsize=13, fontweight="bold")
ax.text(50, 51.6, "no multipliers: only signed adders / subtractors and hard-wired arithmetic shifts",
        ha="center", va="center", fontsize=10, color=GREY, style="italic")

# ================= INPUT SIDE =================
# theta input
label(3.5, 44, "theta\n[Q2.13 rad]", c=BLUE, fs=9)
arrow(7.5, 44, 12, 44, color=BLUE)

# Quadrant fold
box(12, 39.5, 15, 9, "QUADRANT\nFOLD\n\nθ→[-π/2,π/2]\nset negate", fc="#fff4e6", ec=ORANGE, fs=9.5)
label(19.5, 37.6, "cos/sin(θ±π) = -cos/sin(θ)", c=ORANGE, fs=7.8)

# seed constants
box(12, 27, 15, 8.5, "SEED\n\nx0 = 1/K = 0.6073\ny0 = 0\nz0 = folded θ", fc="#eafaf0", ec=GREEN, fs=9)

arrow(27, 45.5, 33, 45.5, color=BLUE)   # z0
arrow(27, 43,   33, 41.5, color=BLUE)   # negate
arrow(27, 31.5, 33, 37,   color=GREEN)  # x0/y0 seed

# ================= PIPELINE STAGES (representative) =================
sx = 33
box(sx, 20, 30, 27, "", fc="#f6f8ff", ec="#33415c", lw=1.6, style="sq")
label(sx + 15, 45.4, "CORDIC ROTATION STAGE  i", c="#33415c", fs=10, w="bold")
label(sx + 15, 43.4, "(fully unrolled: ITER=12 identical pipelined stages)", c=GREY, fs=8)

# stage internals
box(sx + 1.5, 36.5, 12, 5, "sign(z_i)\n→ direction dᵢ", fc="#f3e8ff", ec=PUR, fs=8.5)
box(sx + 16.5, 36.5, 12, 5, "atan(2⁻ⁱ)\nLUT const", fc="#fff4e6", ec=ORANGE, fs=8.5)

box(sx + 1.5, 29.5, 12, 5, "x ∓ (y >>> i)", fc="#eef2ff", ec="#33415c", fs=9)
box(sx + 16.5, 29.5, 12, 5, "y ± (x >>> i)", fc="#eef2ff", ec="#33415c", fs=9)
box(sx + 1.5, 22.5, 27, 5, "z ∓ atan(2⁻ⁱ)     →  drives z toward 0", fc="#eef2ff", ec="#33415c", fs=9)

# little pipeline-register hint on the right edge
for yy in (30, 24):
    ax.add_patch(Rectangle((sx + 29.2, yy), 0.8, 4.5, fc=GREY, ec="none", zorder=3))
label(sx + 29.6, 47.7, "▮ = pipeline reg", c=GREY, fs=7.5)

# direction feeds the add/sub
arrow(sx + 7.5, 36.5, sx + 7.5, 34.5, color=PUR, lw=1.3)
arrow(sx + 13.5, 39, sx + 22.5, 34.5, color=PUR, lw=1.1, rad=-0.2)
arrow(sx + 22.5, 36.5, sx + 22.5, 34.5, color=ORANGE, lw=1.3)

# cross-coupling note
label(sx + 15, 19.0, "x,y cross-couple each stage (the micro-rotation); shift amount i is hard-wired per stage",
      c=GREY, fs=7.6)

# ...ellipsis to output
arrow(sx + 30.5, 33.5, 68.5, 33.5, color="#33415c")
label(66, 35.2, "× ITER", c="#33415c", fs=8.5)

# ================= OUTPUT SIDE =================
box(68.5, 28.5, 15, 10, "OUTPUT\nSIGN FOLD-BACK\n\ncos = ±x_N\nsin = ±y_N\n(negate if set)", fc="#eafaf0", ec=GREEN, fs=8.8)

arrow(83.5, 35.5, 90, 35.5, color=GREEN)
arrow(83.5, 31.5, 90, 31.5, color=GREEN)
label(93, 35.5, "cos_o", c=GREEN, fs=10, w="bold")
label(93, 31.5, "sin_o", c=GREEN, fs=10, w="bold")

# ================= VALID / NEGATE SIDEBAND =================
box(33, 8.5, 50.5, 6, "valid  &  negate  shift pipeline  (ITER+1 deep — keeps sideband aligned to datapath)",
    fc="#eef7ff", ec=BLUE, fs=9)
arrow(12 + 7.5, 39.5, 12 + 7.5, 14.6, color=BLUE, lw=1.2, ls="--")  # negate down into sideband
arrow(58.5, 11.5, 76, 11.5, color=BLUE, lw=1.3)
arrow(76, 11.5, 76, 28.5, color=BLUE, lw=1.3)
label(70, 13.2, "out_valid", c=BLUE, fs=8.5)

# clk / rst_n
label(4, 12, "clk", c=GREY, fs=9, ha="left")
label(4, 9.5, "rst_n", c=GREY, fs=9, ha="left")
arrow(9, 12, 33, 12, color=GREY, lw=1.0, ls=":")
arrow(9, 9.5, 33, 9.5, color=GREY, lw=1.0, ls=":")

# footer
ax.text(50, 3.2,
        "Latency = ITER+1 cycles · throughput = 1 result/clock · magnitude stays in [1/K, 1] so WIDTH bits suffice",
        ha="center", va="center", fontsize=9, color=GREY, style="italic")

plt.tight_layout()
fig.savefig("cordic_sincos_block.png", dpi=130, bbox_inches="tight", facecolor="white")
print("wrote cordic_sincos_block.png")
