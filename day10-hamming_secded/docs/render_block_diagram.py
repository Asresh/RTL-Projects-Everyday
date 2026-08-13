#!/usr/bin/env python3
"""Render the Day10 hamming_secded micro-architecture / circuit diagram to PNG.

A schematic (hand-drawn in matplotlib) of the SECDED (72,64) datapath:
encoder parity tree -> channel XOR (error injection) -> pipeline register ->
decoder (syndrome generator, 1-of-72 corrector, data extract) -> outputs.
This is an architectural drawing, not a captured simulation.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

plt.rcParams.update({"font.family": "DejaVu Sans", "font.size": 10})
fig, ax = plt.subplots(figsize=(15.5, 8.2))
fig.patch.set_facecolor("white")
ax.set_xlim(0, 100)
ax.set_ylim(0, 56)
ax.axis("off")

INK   = "#12202b"
ENC   = "#e8f0ff"; ENC_E = "#2f6fed"
CH    = "#fff2e6"; CH_E  = "#d97706"
REG   = "#eee9ff"; REG_E = "#6d4bd8"
DEC   = "#e9f9ee"; DEC_E = "#0b8f3a"
FLAG  = "#fdecee"; FLAG_E= "#b3261e"

def box(x, y, w, h, label, fc, ec, fs=10, bold=False, sub=None):
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.15,rounding_size=0.8",
                       linewidth=1.8, edgecolor=ec, facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w/2, y + h/2 + (1.1 if sub else 0), label, ha="center", va="center",
            fontsize=fs, color=INK, fontweight=("bold" if bold else "normal"),
            zorder=4)
    if sub:
        ax.text(x + w/2, y + h/2 - 1.6, sub, ha="center", va="center",
                fontsize=8, color="#4a5a68", zorder=4)
    return (x, y, w, h)

def arrow(x1, y1, x2, y2, color=INK, lw=1.8, style="-|>", ls="-"):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 mutation_scale=15, linewidth=lw, color=color,
                 linestyle=ls, zorder=2))

def lbl(x, y, t, fs=8.5, color="#33475b", ha="center", style="normal"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=color, style=style, zorder=5)

# ---- title ----
ax.text(50, 54.4, "hamming_secded — SECDED (72,64) ECC codec datapath",
        ha="center", va="center", fontsize=14, fontweight="bold", color=INK)
ax.text(50, 51.6, "encode  →  channel (bit-flip inject)  →  pipeline reg  →  decode (correct 1 / detect 2)",
        ha="center", va="center", fontsize=10, color="#4a5a68")

# ---- stage band shading ----
ax.add_patch(Rectangle((2, 6), 30, 41, facecolor="#f6f9ff", edgecolor="none", zorder=0))
ax.add_patch(Rectangle((34, 6), 12, 41, facecolor="#fffaf3", edgecolor="none", zorder=0))
ax.add_patch(Rectangle((48, 6), 8, 41, facecolor="#f7f4ff", edgecolor="none", zorder=0))
ax.add_patch(Rectangle((58, 6), 40, 41, facecolor="#f4fbf6", edgecolor="none", zorder=0))
for (cx, t) in [(17, "ENCODER (comb)"), (40, "CHANNEL"),
                (52, "STAGE-1 REG"), (78, "DECODER (comb) → STAGE-2 REG")]:
    ax.text(cx, 8.4, t, ha="center", va="center", fontsize=8.5,
            color="#8a97a5", fontweight="bold")

# ---- input ----
lbl(6, 44, "data_i[63:0]", fs=10, color=INK)
arrow(9, 42.4, 9, 40.6, color=ENC_E)

# ---- ENCODER internals ----
box(4, 34, 26, 6, "interleave data into", ENC, ENC_E, sub="non-power-of-2 positions 1..71")
box(4, 24, 26, 6, "7 Hamming parity trees", ENC, ENC_E,
    sub="p[j] = XOR of positions with bit j set")
box(4, 15, 26, 6, "overall parity bit", ENC, ENC_E,
    sub="even parity over all 71 -> SECDED")
arrow(17, 34, 17, 30, color=ENC_E)
arrow(17, 24, 17, 21, color=ENC_E)
box(9, 9.5, 16, 3.8, "codeword[71:0]", ENC, ENC_E, fs=9, bold=True)
arrow(17, 15, 17, 13.3, color=ENC_E)

# ---- CHANNEL : XOR error injection ----
arrow(25, 11.4, 39.2, 11.4, color=INK)
xg = box(37, 30, 8, 8, "XOR", CH, CH_E, fs=12, bold=True)
# route codeword up into the XOR
arrow(39.2, 11.4, 39.2, 29.6, color=INK)          # (visual: value travels to XOR)
lbl(41, 44, "err_inject[71:0]", fs=9.5, color=CH_E)
arrow(41, 42.4, 41, 38.2, color=CH_E)
lbl(41, 26.5, "soft-error /\nchannel bit flips", fs=8, color=CH_E)

# ---- STAGE 1 register ----
arrow(45, 34, 49.6, 34, color=INK)
box(49.6, 27, 6, 14, "R\nE\nG", REG, REG_E, fs=11, bold=True)
lbl(52.6, 24.4, "clk / rst_n", fs=7.5, color="#6d4bd8")

# ---- DECODER internals ----
arrow(55.6, 34, 59.6, 34, color=DEC_E)
box(59.5, 34.5, 17, 6, "syndrome generator", DEC, DEC_E,
    sub="7 parity checks over rx word")
box(59.5, 25.5, 17, 6, "overall-parity check", DEC, DEC_E,
    sub="odd? -> correctable")
box(80, 30, 15, 8, "1-of-72 corrector", DEC, DEC_E, fs=10, bold=True,
    sub="flip position = syndrome")
box(80, 18.5, 15, 6.5, "data extract", DEC, DEC_E,
    sub="strip parity positions")

arrow(76.5, 37.5, 80, 35.5, color=DEC_E)          # syndrome -> corrector
arrow(76.5, 28.5, 80, 32.5, color=DEC_E)          # overall  -> corrector
arrow(87.5, 30, 87.5, 25, color=DEC_E)            # corrector -> extract

# decision -> flags
box(59.5, 15, 17, 6.5, "SECDED decode logic", FLAG, FLAG_E,
    sub="S/P0 -> classify")
arrow(68, 25.5, 68, 21.5, color=DEC_E)

# ---- OUTPUTS ----
def outp(y, name, color):
    arrow(95, y, 98.2, y, color=color)
    lbl(98.6, y, name, fs=9, color=INK, ha="left")

arrow(87.5, 18.5, 87.5, 13, color=DEC_E)
arrow(87.5, 13, 96.5, 13, color=DEC_E)
outp(13, "data_o[63:0]", DEC_E)
arrow(76.5, 18.3, 90, 10.2, color=FLAG_E)
outp(10, "single_error_o", FLAG_E)
outp(7.4,  "double_error_o", FLAG_E)
outp(15.6, "out_valid", REG_E)
ax.text(83.5, 6.2, "flags + corrected data registered in stage-2 (latency = 2 clk)",
        ha="center", va="center", fontsize=8, color="#8a97a5")

# footer note
ax.text(50, 2.4,
        "Architectural schematic (hand-drawn). See docs/hamming_secded_waveform.png "
        "for the REAL captured Icarus simulation.",
        ha="center", va="center", fontsize=8.5, color="#8a97a5", style="italic")

plt.tight_layout()
fig.savefig("hamming_secded_block.png", dpi=130, bbox_inches="tight", facecolor="white")
print("wrote hamming_secded_block.png")
