#!/usr/bin/env python3
"""Render the fft_pipeline circuit / block diagram to docs/fft_pipeline_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator capture):
the packed complex input vector entering a bit-reversal permutation, then LOG2N=4
radix-2 DIT butterfly stages -- each a bank of N/2=8 butterflies followed by a
pipeline register bank -- fed by the elaboration-derived twiddle ROM, and the packed
natural-order spectrum leaving the last register bank. Two insets show the actual
radix-2 DIT butterfly cell arithmetic (complex twiddle multiply, add/sub, /2 scaling
with round-half-up) and an 8-point DIT signal-flow graph illustrating the butterfly
connectivity and per-stage twiddle schedule the full 16-point network implements.
"""
import math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

PERM_C = "#7c3aed"   # bit-reversal permutation
BF_C   = "#0f766e"   # butterfly banks
REG_C  = "#b45309"   # pipeline registers
ROM_C  = "#c026d3"   # twiddle ROM
IO_C   = "#0369a1"   # I/O buses
OUT_C  = "#dc2626"   # highlighted output
INK    = "#1f2937"
MUT    = "#6b7280"

fig, ax = plt.subplots(figsize=(16.5, 10.4))
ax.set_xlim(0, 168)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.9):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.5,rounding_size=2",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.35)


def reg(x, y, h, label="reg"):
    ax.add_patch(plt.Rectangle((x, y), 2.6, h, facecolor=REG_C,
                 edgecolor=REG_C, alpha=0.85, zorder=3))
    ax.text(x + 1.3, y - 2.4, label, ha="center", va="top",
            fontsize=7.6, color=REG_C, rotation=0)


def arrow(x1, y1, x2, y2, c=INK, lw=1.9, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=14, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def label(x, y, t, c=INK, fs=8.4, style="italic", ha="center"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c,
            fontstyle=style, zorder=5)


# ---------------------------------------------------------------------------
ax.text(84, 97, "Day 37  Pipelined Radix-2 DIT FFT (N=16, Q1.15) — datapath / circuit block diagram",
        ha="center", va="center", fontsize=14, fontweight="bold", color=INK)
ax.text(84, 92.3, "hand-drawn schematic of the built circuit (matplotlib — NOT a simulator capture)",
        ha="center", va="center", fontsize=9.4, color=MUT, fontstyle="italic")

ROWY, ROWH = 60, 20     # main datapath row
ROM_Y = ROWY + ROWH + 4.0    # twiddle ROM band (below subtitle, above stages)

# ---- input buses ----------------------------------------------------------
box(2, ROWY, 13, ROWH,
    "in_re[255:0]\nin_im[255:0]\n\n16 complex\nsamples\n(natural order)",
    IO_C, fc="#eff6ff", fs=8.6)

# ---- bit-reversal ---------------------------------------------------------
box(20, ROWY, 12, ROWH, "bit-\nreversal\npermute\n(wiring)", PERM_C, fc="#f5f3ff", fs=9)
arrow(15, ROWY + ROWH / 2, 20, ROWY + ROWH / 2, IO_C)

# ---- register bank 0 ------------------------------------------------------
reg(33.5, ROWY, ROWH, "bank0")
arrow(32, ROWY + ROWH / 2, 33.5, ROWY + ROWH / 2, PERM_C)

# ---- four butterfly stages ------------------------------------------------
stage_x = [39, 66, 93, 120]
tw_sets = ["W = 1", "W$^{0}$, W$^{4}$", "W$^{0}$,W$^{2}$,\nW$^{4}$,W$^{6}$",
           "W$^{0}$..W$^{7}$"]
spans   = ["span 1", "span 2", "span 4", "span 8"]
for s in range(4):
    x = stage_x[s]
    box(x, ROWY, 20, ROWH,
        f"Stage {s+1}\n8 radix-2\nbutterflies\n{spans[s]}", BF_C, fc="#ecfdf5", fs=9)
    label(x + 10, ROWY + ROWH + 1.5, "twiddle:  " + tw_sets[s].replace("\n", " "),
          c=ROM_C, fs=8.0, style="normal")
    reg(x + 20 + 0.6, ROWY, ROWH, f"bank{s+1}")
    prev_r = (33.5 + 2.6) if s == 0 else (stage_x[s-1] + 20 + 0.6 + 2.6)
    arrow(prev_r, ROWY + ROWH / 2, x, ROWY + ROWH / 2, REG_C)

# ---- output buses ---------------------------------------------------------
outx = stage_x[3] + 20 + 0.6 + 2.6
box(outx + 4, ROWY, 14, ROWH,
    "out_re[255:0]\nout_im[255:0]\n\n16 spectrum\nbins X[0..15]\n(natural order)",
    OUT_C, fc="#fef2f2", fs=8.4)
arrow(outx, ROWY + ROWH / 2, outx + 4, ROWY + ROWH / 2, REG_C)
label(outx + 11, ROWY - 3.2, "out_valid", c=OUT_C, fs=8.2, style="normal")

# ---- twiddle ROM ----------------------------------------------------------
box(61, ROM_Y, 50, 6,
    "Twiddle ROM  W$_N^k$ = e$^{-j2\\pi k/N}$,  k = 0..N/2-1\n"
    "derived at ELABORATION from cos/sin (no hand-typed table)",
    ROM_C, fc="#fdf4ff", fs=8.4)
for s in range(1, 4):
    arrow(86, ROM_Y, stage_x[s] + 10, ROWY + ROWH + 0.6, ROM_C, lw=1.2, ls="--", rad=0.12)

# clock / reset rail
ax.plot([2, outx + 18], [ROWY - 8, ROWY - 8], color=MUT, lw=1.2, ls=":")
label(6, ROWY - 8, "clk / rst_n", c=MUT, fs=8.2, style="normal", ha="left")
for x in [33.5 + 1.3] + [xx + 20 + 0.6 + 1.3 for xx in stage_x]:
    arrow(x, ROWY - 8, x, ROWY - 0.4, MUT, lw=0.9, ls=":")

# throughput / latency banner
ax.text(84, ROWY - 13.5,
        "throughput = 1 complete 16-point FFT / clock      |      latency = LOG2N+1 = 5 clocks (input bank + 4 butterfly banks)",
        ha="center", va="center", fontsize=9.6, color=INK,
        bbox=dict(boxstyle="round,pad=0.5", fc="#f8fafc", ec="#cbd5e1"))

# ===========================================================================
# INSET A : radix-2 DIT butterfly cell arithmetic
# ===========================================================================
ax.text(30, ROWY - 20.5, "Radix-2 DIT butterfly cell (fixed-point Q1.15)",
        ha="center", fontsize=10.2, fontweight="bold", color=BF_C)
bx0, by0 = 8, 6
# nodes
ax_a = (bx0 + 2, by0 + 20)     # a in (top)
ax_b = (bx0 + 2, by0 + 6)      # b in (bottom)
mul  = (bx0 + 16, by0 + 6)     # twiddle mult
addn = (bx0 + 30, by0 + 20)    # a + Wb
subn = (bx0 + 30, by0 + 6)     # a - Wb
ax.add_patch(Circle(mul, 2.1, facecolor="white", edgecolor=ROM_C, lw=1.8, zorder=4))
ax.text(*mul, "×", ha="center", va="center", fontsize=13, color=ROM_C, zorder=5)
for (nn, lab, col) in [(addn, "+", BF_C), (subn, "−", BF_C)]:
    ax.add_patch(Circle(nn, 2.1, facecolor="white", edgecolor=col, lw=1.8, zorder=4))
    ax.text(nn[0], nn[1], lab, ha="center", va="center", fontsize=13, color=col, zorder=5)
label(ax_a[0] - 2, ax_a[1], "a", c=INK, fs=10, style="normal", ha="right")
label(ax_b[0] - 2, ax_b[1], "b", c=INK, fs=10, style="normal", ha="right")
label(mul[0], mul[1] - 4.2, "W$_N^k$", c=ROM_C, fs=9, style="normal")
# wires
arrow(ax_b[0], ax_b[1], mul[0] - 2.1, ax_b[1], BF_C)
arrow(mul[0] + 2.1, ax_b[1], addn[0] - 2.1, ax_b[1] + 0.0, BF_C, rad=0.0)  # Wb -> toward add/sub
ax.plot([mul[0] + 2.1, subn[0] - 2.1], [ax_b[1], subn[1]], color=BF_C, lw=1.9, zorder=2)
# a fans to add and sub
ax.plot([ax_a[0], addn[0] - 2.1], [ax_a[1], addn[1]], color=BF_C, lw=1.9, zorder=2)
ax.plot([ax_a[0], ax_a[0]], [ax_a[1], subn[1] + 8], color=BF_C, lw=1.9, zorder=2)
arrow(ax_a[0], subn[1] + 8, subn[0] - 2.1, subn[1] + 0.5, BF_C, rad=-0.25)
# Wb into add (t = W*b)
arrow(mul[0], ax_b[1] + 2.1, addn[0] - 2.1, addn[1] - 0.5, BF_C, rad=0.2)
# outputs with /2
for (nn, txt) in [(addn, "(a + W·b) ≫ 1"), (subn, "(a − W·b) ≫ 1")]:
    arrow(nn[0] + 2.1, nn[1], nn[0] + 9, nn[1], OUT_C)
    label(nn[0] + 10, nn[1], txt, c=OUT_C, fs=8.0, style="normal", ha="left")
ax.text(bx0 + 1, by0 - 2.6,
        "t = W·b : (wc·bre − ws·bim, wc·bim + ws·bre) ≫ 15, round-half-up.   "
        "/2 per stage ⇒ output = DFT / N (no overflow for |x| ≤ ½).",
        ha="left", va="top", fontsize=7.8, color=MUT)

# ===========================================================================
# INSET B : 8-point DIT signal-flow graph (illustrates connectivity)
# ===========================================================================
gx0, gy0 = 96, 4
gw, gh = 62, 30
ax.text(gx0 + gw / 2, gy0 + gh + 2.2,
        "8-point DIT signal-flow graph — the butterfly / twiddle pattern the 16-point network generalises",
        ha="center", fontsize=9.6, fontweight="bold", color=INK)
n8 = 8
cols = 4                      # input col + 3 stages
colx = [gx0 + 3 + i * (gw - 6) / (cols - 1) for i in range(cols)]
rowy = [gy0 + gh - 2 - r * (gh - 4) / (n8 - 1) for r in range(n8)]

# node dots
for c in range(cols):
    for r in range(n8):
        ax.add_patch(Circle((colx[c], rowy[r]), 0.5, facecolor=INK, edgecolor=INK, zorder=4))

# bit-reversed input labels (natural index feeding bit-reversed position)
def bitrev3(i):
    return int(f"{i:03b}"[::-1], 2)
for r in range(n8):
    label(colx[0] - 2.4, rowy[r], f"x[{bitrev3(r)}]", c=PERM_C, fs=7.2, style="normal", ha="right")
for r in range(n8):
    label(colx[-1] + 2.4, rowy[r], f"X[{r}]", c=OUT_C, fs=7.2, style="normal", ha="left")

# DIT butterflies per stage
for st in range(3):                         # stages 1..3
    half = 1 << st
    grp = 1 << (st + 1)
    for base in range(0, n8, grp):
        for j in range(half):
            top = base + j
            bot = top + half
            x1, x2 = colx[st], colx[st + 1]
            # straight + cross edges
            ax.plot([x1, x2], [rowy[top], rowy[top]], color=BF_C, lw=1.0, zorder=2)
            ax.plot([x1, x2], [rowy[bot], rowy[bot]], color=BF_C, lw=1.0, zorder=2)
            ax.plot([x1, x2], [rowy[top], rowy[bot]], color="#94a3b8", lw=0.8, zorder=1)
            ax.plot([x1, x2], [rowy[bot], rowy[top]], color="#94a3b8", lw=0.8, zorder=1)
            # twiddle exponent label on the lower incoming edge
            twi = j * (n8 // grp)
            if twi > 0:
                ax.text((x1 + x2) / 2, (rowy[bot]) - 0.9, f"W{twi}",
                        ha="center", va="top", fontsize=6.0, color=ROM_C)

ax.text(gx0 + gw / 2, gy0 - 1.6,
        "solid teal = pass-through, grey = cross butterfly edges;  W k = twiddle exponent applied on that edge",
        ha="center", va="top", fontsize=7.6, color=MUT)

plt.tight_layout()
fig.savefig("docs/fft_pipeline_block.png", dpi=140, facecolor="white")
print("wrote docs/fft_pipeline_block.png")
