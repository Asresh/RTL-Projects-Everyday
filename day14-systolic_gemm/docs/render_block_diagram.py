#!/usr/bin/env python3
"""Render the Day14 systolic_matmul circuit/block diagram to a PNG.

Draws the output-stationary systolic dataflow: the N x N mesh of MAC PEs, the
A rows entering from the west (skewed) and marching east, the B columns entering
from the north (skewed) and marching south, the skew scheduler that latches A/B
and issues the diagonal launch schedule, and an inset of a single PE's datapath
(input registers + multiplier + stationary accumulator + neighbour forwarding).

Pure schematic drawing (matplotlib) -- not a simulator screenshot.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

N = 4

BG   = "#0b141f"
PANEL= "#13233a"
PE   = "#1d3557"
PE_E = "#457b9d"
ACC  = "#2a9d8f"
AC   = "#e63946"   # A path (east)
BC   = "#f4a261"   # B path (south)
TXT  = "#e0e1dd"
MUT  = "#9fb3c8"

fig, ax = plt.subplots(figsize=(13.5, 8.6))
fig.patch.set_facecolor(BG)
ax.set_facecolor(BG)
ax.set_xlim(0, 15)
ax.set_ylim(0, 10)
ax.axis("off")


def box(x, y, w, h, fc, ec, lw=1.5, r=0.08):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle=f"round,pad=0.02,rounding_size={r}",
                 facecolor=fc, edgecolor=ec, lw=lw, zorder=3))


def arrow(x0, y0, x1, y1, c, lw=2.0, style="-|>"):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1), arrowstyle=style,
                 mutation_scale=13, color=c, lw=lw, zorder=4))


# ---- title -----------------------------------------------------------------
ax.text(7.5, 9.65, "Day14 — Output-Stationary Systolic-Array GEMM Accelerator  (C = A × B)",
        ha="center", color=TXT, fontsize=15, weight="bold")
ax.text(7.5, 9.25, "N×N MAC mesh · A streams east · B streams south · diagonal skew aligns A[i][k]·B[k][j] at PE(i,j)",
        ha="center", color=MUT, fontsize=10)

# ---- skew scheduler --------------------------------------------------------
box(0.4, 3.2, 2.1, 3.0, PANEL, "#5a7bb0")
ax.text(1.45, 5.9, "SKEW", ha="center", color=TXT, fontsize=11, weight="bold")
ax.text(1.45, 5.55, "SCHEDULER", ha="center", color=TXT, fontsize=9, weight="bold")
ax.text(1.45, 5.05, "latch A (N×K)\nlatch B (K×N)\non `start`", ha="center",
        color=MUT, fontsize=8)
ax.text(1.45, 4.15, "issue row i\n@ t≥i, col j\n@ t≥j", ha="center",
        color=MUT, fontsize=8)
ax.text(1.45, 3.45, "start→busy→done", ha="center", color=ACC, fontsize=7.5)

# ---- mesh geometry ---------------------------------------------------------
x0, y0 = 4.6, 3.0     # bottom-left of PE(N-1,0)
dx, dy = 1.7, 1.35
pe_w, pe_h = 1.15, 1.0


def pe_xy(i, j):
    # i = row (0 at top), j = col (0 at left)
    px = x0 + j * dx
    py = y0 + (N - 1 - i) * dy
    return px, py


# B column feeds (north, skewed) — arrows coming down into row 0
for j in range(N):
    px, py = pe_xy(0, j)
    cx = px + pe_w / 2
    arrow(cx, 8.7, cx, py + pe_h, BC, lw=1.8)
    ax.text(cx, 8.85, f"B[:,{j}]", ha="center", color=BC, fontsize=8)
    # little skew tick label
    ax.text(cx + 0.02, py + pe_h + 0.18, f"↓+{j}", ha="center", color=BC, fontsize=6.5)

# A row feeds (west, skewed) — arrows coming in from the left into col 0
for i in range(N):
    px, py = pe_xy(i, 0)
    cy = py + pe_h / 2
    arrow(3.0, cy, px, cy, AC, lw=1.8)
    ax.text(2.95, cy, f"A[{i},:]", ha="right", va="center", color=AC, fontsize=8)
    ax.text(px - 0.35, cy + 0.28, f"→+{i}", ha="center", color=AC, fontsize=6.5)

# PEs + internal forwarding arrows
for i in range(N):
    for j in range(N):
        px, py = pe_xy(i, j)
        box(px, py, pe_w, pe_h, PE, PE_E, lw=1.3, r=0.06)
        ax.text(px + pe_w/2, py + pe_h*0.62, f"PE", ha="center", color=TXT,
                fontsize=8.5, weight="bold")
        ax.text(px + pe_w/2, py + pe_h*0.30, f"{i},{j}", ha="center", color="#a8dadc",
                fontsize=8)
        # east forward (A) to next column
        if j < N - 1:
            arrow(px + pe_w, py + pe_h*0.62, px + dx, py + pe_h*0.62, AC, lw=1.3)
        else:
            arrow(px + pe_w, py + pe_h*0.62, px + pe_w + 0.5, py + pe_h*0.62,
                  AC, lw=1.0, style="-|>")
        # south forward (B) to next row
        if i < N - 1:
            arrow(px + pe_w*0.35, py, px + pe_w*0.35, py - (dy - pe_h) - 0.0 - (dy-pe_h)*0 - (dy - pe_h),
                  BC, lw=1.3)

# fix south arrows cleanly (draw explicitly between adjacent PEs)
for i in range(N - 1):
    for j in range(N):
        px, py = pe_xy(i, j)
        px2, py2 = pe_xy(i + 1, j)
        arrow(px + pe_w*0.35, py, px + pe_w*0.35, py2 + pe_h, BC, lw=1.3)

# C outputs held in-place (stationary) — small down ticks from bottom row
for j in range(N):
    px, py = pe_xy(N - 1, j)
    ax.text(px + pe_w/2, py - 0.35, f"C[:,{j}]", ha="center", color=ACC, fontsize=7.5)

ax.text(7.9, 2.35, "each PE holds C[i][j] stationary in its accumulator (output-stationary)",
        ha="center", color=ACC, fontsize=8.5, style="italic")

# ---- single-PE datapath inset ---------------------------------------------
ix, iy, iw, ih = 11.0, 3.1, 3.6, 3.6
box(ix, iy, iw, ih, "#0f1d30", "#5a7bb0", lw=1.4, r=0.05)
ax.text(ix + iw/2, iy + ih - 0.3, "PE datapath", ha="center", color=TXT,
        fontsize=10, weight="bold")

# input regs
box(ix+0.3, iy+2.3, 0.9, 0.55, PE, AC, 1.2, r=0.05)
ax.text(ix+0.75, iy+2.57, "a_reg", ha="center", color=TXT, fontsize=7.5)
box(ix+0.3, iy+1.5, 0.9, 0.55, PE, BC, 1.2, r=0.05)
ax.text(ix+0.75, iy+1.77, "b_reg", ha="center", color=TXT, fontsize=7.5)

# multiplier
box(ix+1.55, iy+1.9, 0.75, 0.9, "#3a506b", "#a8dadc", 1.2, r=0.05)
ax.text(ix+1.92, iy+2.35, "×", ha="center", color=TXT, fontsize=15, weight="bold")

# adder + acc
box(ix+2.55, iy+1.9, 0.75, 0.9, "#3a506b", "#a8dadc", 1.2, r=0.05)
ax.text(ix+2.92, iy+2.35, "+", ha="center", color=TXT, fontsize=15, weight="bold")
box(ix+2.5, iy+0.75, 0.85, 0.55, ACC, "#e9fff9", 1.2, r=0.05)
ax.text(ix+2.92, iy+1.02, "acc", ha="center", color="#08312a", fontsize=8, weight="bold")

arrow(ix+1.2, iy+2.57, ix+1.55, iy+2.5, AC, 1.4)
arrow(ix+1.2, iy+1.77, ix+1.55, iy+2.2, BC, 1.4)
arrow(ix+2.3, iy+2.35, ix+2.55, iy+2.35, "#a8dadc", 1.4)
arrow(ix+2.92, iy+1.9, ix+2.92, iy+1.3, ACC, 1.4)          # add -> acc
arrow(ix+2.92, iy+1.3, ix+2.6, iy+2.0, ACC, 1.2, style="-|>")  # acc feedback
ax.text(ix+3.35, iy+1.55, "acc += a·b\n(when valid)", ha="left", color=ACC, fontsize=6.8)

# forwarding taps
arrow(ix+0.75, iy+2.85, ix+0.75, iy+3.15, AC, 1.2)
ax.text(ix+0.3, iy+3.2, "a→east", color=AC, fontsize=6.5)
arrow(ix+0.75, iy+1.5, ix+0.75, iy+1.2, BC, 1.2)
ax.text(ix+0.3, iy+1.0, "b→south", color=BC, fontsize=6.5)

# legend
ax.add_patch(Rectangle((0.4, 0.5), 0.4, 0.2, color=AC)); ax.text(0.95, 0.6, "A activations (flow east)", color=MUT, fontsize=8, va="center")
ax.add_patch(Rectangle((5.4, 0.5), 0.4, 0.2, color=BC)); ax.text(5.95, 0.6, "B weights (flow south)", color=MUT, fontsize=8, va="center")
ax.add_patch(Rectangle((10.0, 0.5), 0.4, 0.2, color=ACC)); ax.text(10.55, 0.6, "stationary C accumulator", color=MUT, fontsize=8, va="center")

fig.savefig("systolic_matmul_block.png", dpi=130, bbox_inches="tight",
            facecolor=fig.get_facecolor())
print("wrote systolic_matmul_block.png")
