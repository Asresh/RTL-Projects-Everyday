#!/usr/bin/env python3
"""Render the viterbi_decoder circuit / block diagram to docs/viterbi_decoder_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator capture):
the received 2-bit symbol feeding a Branch-Metric Unit (Hamming distance to every
trellis edge codeword), four Add-Compare-Select units (one per K=3 state) each with
its path-metric register and a survivor register-exchange word, the per-cycle metric
normaliser, the minimum-metric argmin selector, and the TB_LEN-delayed decoded-bit
read-out. A small (7,5) trellis butterfly is drawn to show the edge connectivity the
ACS units implement.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

BMU_C = "#7c3aed"   # branch metric unit
ACS_C = "#0f766e"   # add-compare-select
PM_C  = "#b45309"   # path metric registers
SURV_C= "#0369a1"   # survivor memory
MIN_C = "#c026d3"   # min-metric select
OUT_C = "#dc2626"   # decoded output
INK   = "#1f2937"
MUT   = "#6b7280"

fig, ax = plt.subplots(figsize=(16.5, 10.2))
ax.set_xlim(0, 134)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.9):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.5,rounding_size=2",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.9, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=14, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def label(x, y, t, c=INK, fs=8.4, style="italic", ha="center"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c,
            fontstyle=style, zorder=5)


def reg(x, y, w, h, lab, ec):
    ax.add_patch(plt.Rectangle((x, y), w, h, edgecolor=ec, facecolor="#f8fafc",
                 lw=1.7, zorder=3))
    # little flip-flop notch
    ax.add_patch(plt.Polygon([(x, y), (x + 2.0, y + h / 2), (x, y + h)],
                 closed=True, edgecolor=ec, facecolor=ec, lw=0, zorder=4))
    ax.text(x + w / 2 + 1, y + h / 2, lab, ha="center", va="center",
            fontsize=8.2, color=INK, zorder=5)


# ---- title -----------------------------------------------------------------
ax.text(67, 96.5, "Day 36 — Hard-Decision Viterbi Decoder  (rate-1/2, K=3, (7,5) code)",
        ha="center", fontsize=15, fontweight="bold", color=INK)
ax.text(67, 92.6, "one trellis stage per clock : Branch-Metric → 4× Add-Compare-Select "
        "→ Survivor register-exchange → argmin read-out",
        ha="center", fontsize=10, color=MUT)

# ---- primary inputs --------------------------------------------------------
arrow(2, 74, 12, 74, c=INK)
label(6.5, 77.4, "sym_in[1:0]", c=INK, style="normal", fs=9)
label(6.5, 70.6, "in_valid", c=MUT, fs=8)
arrow(2, 8.5, 12, 8.5, c=MUT)
label(6.5, 11.5, "clk / rst_n", c=MUT, style="normal", fs=8.5)

# ---- Branch Metric Unit ----------------------------------------------------
box(12, 60, 20, 28, "Branch-Metric\nUnit (BMU)\n\nHamming dist. of\nsym_in to every\nedge codeword\nenc_out(s,u)", BMU_C, fc="#f5f3ff", fs=9)
label(22, 57.5, "8 branch metrics bm (0..2)", c=BMU_C, fs=8)

# ---- four ACS units --------------------------------------------------------
acs_x = 42
acs_w = 30
ys = [70, 52, 34, 16]
names = ["ACS state 0", "ACS state 1", "ACS state 2", "ACS state 3"]
for i, (yy, nm) in enumerate(zip(ys, names)):
    box(acs_x, yy, acs_w, 13,
        f"{nm}\nadd 2 edge metrics → compare → select min",
        ACS_C, fc="#ecfeff", fs=8.4)
    # feed from BMU
    arrow(32, 74 - i*0.0 if False else (yy + 9.5 if i == 0 else yy + 9.5),
          acs_x, yy + 9.5, c=BMU_C, lw=1.4, rad=(0.10 if i else 0.0))
    # path metric register to the right
    reg(acs_x + acs_w + 6, yy + 1.5, 15, 10, f"pm[{i}]", PM_C)
    arrow(acs_x + acs_w, yy + 6.5, acs_x + acs_w + 6, yy + 6.5, c=ACS_C, lw=1.6)
    # feedback pm -> ACS (dashed, up/over)
    arrow(acs_x + acs_w + 13.5, yy + 1.5, acs_x + acs_w + 13.5, yy - 2.2,
          c=PM_C, lw=1.2, ls=(0, (3, 2)))
    arrow(acs_x + acs_w + 13.5, yy - 2.2, acs_x - 2, yy - 2.2,
          c=PM_C, lw=1.2, ls=(0, (3, 2)))
    arrow(acs_x - 2, yy - 2.2, acs_x - 2, yy + 4, c=PM_C, lw=1.2, ls=(0, (3, 2)))
    arrow(acs_x - 2, yy + 4, acs_x, yy + 4, c=PM_C, lw=1.2, ls=(0, (3, 2)))

label(acs_x + acs_w + 13.5, 8.0, "path-metric feedback (survivor recursion)",
      c=PM_C, fs=7.6)

# BMU fan-out note
label(37, 45, "each ACS adds the\ntwo incoming-edge\nbranch metrics to its\ntwo predecessors' pm",
      c=MUT, fs=7.4)

# ---- normaliser ------------------------------------------------------------
box(acs_x + acs_w + 24, 40, 15, 20,
    "Metric\nNormaliser\n\nsubtract\nrunning min\n(anti-overflow)", "#334155",
    fc="#f1f5f9", fs=8.2)
for yy in ys:
    arrow(acs_x + acs_w + 21, yy + 6.5, acs_x + acs_w + 24, 50, c=PM_C, lw=1.0,
          ls=(0, (2, 2)), rad=0.05)

# ---- survivor memory -------------------------------------------------------
box(100, 58, 26, 26,
    "Survivor Memory\n(register-exchange)\n\n4 × TB_LEN-bit words\nsurv[s] << decision\nappend edge input bit",
    SURV_C, fc="#eff6ff", fs=8.6)
for yy in ys:
    arrow(acs_x + acs_w, yy + 11, 100, 66, c=ACS_C, lw=1.0, ls=(0, (2, 2)), rad=0.12)
label(113, 55.5, "MSB = bit from TB_LEN symbols ago", c=SURV_C, fs=7.8)

# ---- argmin + output -------------------------------------------------------
box(100, 30, 26, 16,
    "argmin selector\n\nstate_min = index of\nminimum pm[s]", MIN_C, fc="#fdf4ff", fs=8.6)
for yy in ys:
    arrow(acs_x + acs_w + 21, yy + 6.5, 100, 40, c=PM_C, lw=0.9, ls=(0, (2, 2)), rad=-0.10)

arrow(113, 58, 113, 46, c=SURV_C, lw=1.6)
label(120, 52, "surv[state_min]\n[TB_LEN-1]", c=SURV_C, fs=7.6, style="normal")

box(100, 12, 26, 12, "output register\nbit_out / out_valid", OUT_C, fc="#fef2f2", fs=9)
arrow(113, 30, 113, 24, c=MIN_C, lw=1.8)
arrow(126, 18, 133, 18, c=OUT_C, lw=2.0)
label(130, 21.5, "bit_out", c=OUT_C, style="normal", fs=9)
label(130, 14.5, "out_valid", c=OUT_C, style="normal", fs=8)

# ---- little (7,5) trellis butterfly inset ----------------------------------
tx, ty = 8, 20
ax.text(tx + 14, ty + 20, "(7,5) trellis stage", ha="center", fontsize=8.6,
        color=INK, fontweight="bold")
srcs = {0: ty + 16, 1: ty + 11, 2: ty + 6, 3: ty + 1}
dsts = {0: ty + 16, 1: ty + 11, 2: ty + 6, 3: ty + 1}
# edges: state s --input u--> {s[0],u}; enumerate
edges = []
for s in range(4):
    sr0 = s & 1
    for u in (0, 1):
        ns = ((sr0 << 1) | u) & 3
        edges.append((s, ns, u))
for (s, ns, u) in edges:
    col = "#0f766e" if u == 0 else "#b45309"
    ax.plot([tx + 3, tx + 25], [srcs[s], dsts[ns]], color=col,
            lw=1.2, alpha=0.8, zorder=2)
for s, yy in srcs.items():
    ax.add_patch(Circle((tx + 3, yy), 0.9, color="#334155", zorder=3))
    ax.text(tx + 0.6, yy, f"{s:02b}", ha="right", va="center", fontsize=7, color=INK)
for s, yy in dsts.items():
    ax.add_patch(Circle((tx + 25, yy), 0.9, color="#334155", zorder=3))
    ax.text(tx + 26.6, yy, f"{s:02b}", ha="left", va="center", fontsize=7, color=INK)
ax.text(tx + 14, ty - 2.4, "solid=input 0   amber=input 1", ha="center",
        fontsize=6.8, color=MUT)

plt.tight_layout()
fig.savefig("docs/viterbi_decoder_block.png", dpi=140, facecolor="white")
print("wrote docs/viterbi_decoder_block.png")
