#!/usr/bin/env python3
"""Render the encoder_8b10b circuit / block diagram to docs/encoder_8b10b_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator capture):
the byte split into a 5b/6b and 3b/4b sub-block lookup, the K.28 comma remap on the
6b path, the Dx.A7 alternate selector on the 4b path, the uniform-complement select
(emit = RD==NEG ? code_minus : ~code_minus) driven by the running-disparity register,
the neutral-detect that flips RD only on non-neutral sub-blocks, and the registered
{a..i, f..j} line-code output.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

SIX_C = "#7c3aed"   # 5b/6b path
FOUR_C = "#0f766e"  # 3b/4b path
RD_C  = "#c026d3"   # running disparity / control
SEL_C = "#b45309"   # complement/select
OUT_C = "#2563eb"   # registered output
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(16.5, 10.0))
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


def xor(x, y, r=1.9, c=SEL_C):
    ax.add_patch(Circle((x, y), r, edgecolor=c, facecolor="white", lw=1.7, zorder=4))
    ax.text(x, y, "=1", ha="center", va="center", fontsize=8.5, color=c, zorder=5)


def mux(x, y, w=5.5, h=11, c=SEL_C, lab="MUX"):
    ax.add_patch(plt.Polygon([(x, y), (x + w, y + 2.4), (x + w, y + h - 2.4), (x, y + h)],
                 closed=True, edgecolor=c, facecolor="white", lw=1.7, zorder=3))
    ax.text(x + w / 2 + 0.3, y + h / 2, lab, ha="center", va="center",
            fontsize=7.6, color=c, rotation=90, zorder=4)


# ---- title ------------------------------------------------------------------
ax.text(67, 97, "encoder_8b10b - 8b/10b Line Encoder (Widmer / Franaszek)",
        ha="center", va="center", fontsize=14.5, color=INK, weight="bold")
ax.text(67, 92.6,
        "byte {k_i, HGF EDCBA} -> DC-balanced, transition-rich, comma-alignable 10-bit line code; ONE RD- table per sub-block + uniform-complement select",
        ha="center", va="center", fontsize=9.0, color="#6b7280", fontstyle="italic")

# ---- input -----------------------------------------------------------------
box(2, 60, 15, 12, "data_i[7:0]\nk_i\n(HGF EDCBA)", INK, fc="#f9fafb", fs=8.6)
label(9.5, 57.4, "split byte", c=INK, fs=7.6)

# ========================  5b/6b PATH (top)  ================================
box(24, 74, 22, 11, "x = data_i[4:0]\n5b/6b RD- table\n(map6, 32 entries)", SIX_C, fc="#f5f3ff", fs=8.4)
arrow(17, 66, 30, 74, c=SIX_C)                          # x tap up
label(22, 71.8, "x=EDCBA", c=SIX_C, fs=7.6, ha="left")

box(50, 74, 17, 11, "K.28 remap\nx==28 & k_i ?\n001111", RD_C, fc="#fdf4ff", fs=8.2)
arrow(46, 79.5, 49.9, 79.5, c=SIX_C)
label(58.5, 87.0, "cm6 (code-minus, 6 bits)", c=SIX_C, fs=7.8)

box(74, 74, 15, 11, "neutral6?\ncountones==3\n(disp 0)", FOUR_C, fc="#ecfdf5", fs=8.0)
arrow(67, 79.5, 73.9, 79.5, c=SIX_C)

xor(98, 79.5, c=SEL_C)
label(98, 84.2, "~cm6", c=SEL_C, fs=7.8)
arrow(89, 79.5, 96.1, 79.5, c=SIX_C)
mux(107, 74, lab="sel 6b")
arrow(89, 77.5, 106.9, 76.4, c=SIX_C)                   # cm6 straight leg
arrow(99.9, 79.5, 106.9, 81.0, c=SEL_C)                 # ~cm6 leg
label(112.5, 86.6, "e6 = (RD==NEG)?cm6:~cm6", c=SIX_C, fs=7.8, ha="center")
arrow(112.5, 74, 112.5, 46, c=SIX_C)                    # e6 down to output reg
label(115.6, 60, "e6[5:0]\n{a b c d e i}", c=SIX_C, fs=7.6, ha="left")

# ========================  3b/4b PATH (middle)  ============================
box(24, 40, 22, 11, "y = data_i[7:5]\n3b/4b RD- table\n(map4, 8 entries)", FOUR_C, fc="#ecfdf5", fs=8.4)
arrow(17, 64, 30, 51, c=FOUR_C)                         # y tap
label(22, 47.8, "y=HGF", c=FOUR_C, fs=7.6, ha="left")

box(50, 40, 17, 11, "Dx.A7 alt select\ny==7 & (k_i |\nRD/x rule) ? 0111", RD_C, fc="#fdf4ff", fs=7.8)
arrow(46, 45.5, 49.9, 45.5, c=FOUR_C)
label(58.5, 53.0, "cm4 (code-minus, 4 bits)", c=FOUR_C, fs=7.8)

box(74, 40, 15, 11, "neutral4?\ncountones==2\n(disp 0)", FOUR_C, fc="#ecfdf5", fs=8.0)
arrow(67, 45.5, 73.9, 45.5, c=FOUR_C)

xor(98, 45.5, c=SEL_C)
label(98, 50.2, "~cm4", c=SEL_C, fs=7.8)
arrow(89, 45.5, 96.1, 45.5, c=FOUR_C)
mux(107, 40, lab="sel 4b")
arrow(89, 43.5, 106.9, 42.4, c=FOUR_C)
arrow(99.9, 45.5, 106.9, 47.0, c=SEL_C)
label(112.5, 52.6, "e4 = (rd6==NEG)?cm4:~cm4", c=FOUR_C, fs=7.8, ha="center")
arrow(112.5, 40, 112.5, 34, c=FOUR_C)
label(116, 37, "e4[3:0] {f g h j}", c=FOUR_C, fs=7.6, ha="left")

# ========================  RUNNING DISPARITY (bottom-left)  =================
box(24, 12, 30, 14,
    "RUNNING DISPARITY reg  rd_r\n(1 bit:  0=RD-1,  1=RD+1)\nreset -> RD-1\n"
    "rd6 = neutral6 ? rd_r : ~rd_r\nrd_next = neutral4 ? rd6 : ~rd6",
    RD_C, fc="#fdf4ff", fs=8.2)
# rd_r drives both selects
arrow(54, 22, 108.5, 74.2, c=RD_C, ls=(0, (5, 3)), rad=-0.18)
label(84, 33.0, "rd_r selects 6b variant", c=RD_C, fs=7.6)
arrow(54, 19, 108.5, 40.2, c=RD_C, ls=(0, (5, 3)), rad=-0.12)
label(80, 25.0, "rd6 selects 4b variant", c=RD_C, fs=7.6)
# neutral flags into disparity update
arrow(81.5, 74, 45, 24.5, c=FOUR_C, ls=(0, (3, 3)), rad=0.15)
arrow(81.5, 40, 46, 21.5, c=FOUR_C, ls=(0, (3, 3)), rad=0.10)
label(60, 30.5, "neutral6 / neutral4\nflip RD only when\nsub-block is non-neutral",
      c=FOUR_C, fs=7.2)

# ========================  OUTPUT REGISTER (right)  ========================
box(105, 20, 24, 14,
    "OUTPUT REGISTER\n(posedge clk)\ncode_o <= {e6, e4}\nrd_o <= rd_next\nvalid_o, code_err_o",
    OUT_C, fc="#eff6ff", fs=8.4)
arrow(112.5, 46, 117, 34, c=SIX_C, rad=0.12)            # e6 into reg
arrow(112.5, 34, 117, 34.0, c=FOUR_C)                   # e4 into reg (approx)
# rd_next feedback to rd_r
ax.add_patch(FancyArrowPatch((117, 20), (39, 26),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.6,
             color=RD_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=0.28"))
label(76, 15.6, "rd_next committed back into rd_r each accepted character", c=RD_C, fs=7.8)
box(105, 4, 24, 9, "code_o[9:0]\n(a first on wire)\n+ valid_o / rd_o", OUT_C, fc="#eff6ff", fs=8.2)
arrow(117, 20, 117, 13, c=OUT_C)

# ---- footer -----------------------------------------------------------------
ax.text(67, 1.6,
        "Uniform rule: every RD+ codeword is the bitwise complement of its RD- partner (neutral AND non-neutral), so only the RD- column is stored.  "
        "Registered => deterministic 1-clock byte->line latency, no data-dependent timing.",
        ha="center", va="center", fontsize=8.2, color="#374151", fontstyle="italic",
        linespacing=1.5)

fig.tight_layout()
fig.savefig("docs/encoder_8b10b_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/encoder_8b10b_block.png")
