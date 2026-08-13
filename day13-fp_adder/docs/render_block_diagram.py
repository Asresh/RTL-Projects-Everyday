#!/usr/bin/env python3
"""Render the Day13 fp_add datapath / block diagram to a PNG.

A hand-drawn schematic (matplotlib) of the 3-stage IEEE-754 add/sub pipeline:
unpack + classify, exponent compare / operand swap, alignment barrel shifter,
significand add/subtract, leading-zero-count normalizer, round-to-nearest-even,
and repack - with the pipeline register boundaries and the special-case
(Inf/NaN/zero) bypass drawn in.  This is a schematic of the RTL, not a captured
signal trace.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

INK   = "#1b2733"
BLUE  = "#1f6feb"
GREEN = "#0b8f3a"
RED   = "#b3261e"
ORANGE= "#d97706"
PURP  = "#6f42c1"
GREY  = "#8a8a8a"


def box(ax, x, y, w, h, text, fc="#ffffff", ec=BLUE, tc=INK, fs=10.5, lw=1.6):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.02,rounding_size=0.06",
                 fc=fc, ec=ec, lw=lw, zorder=3))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, color=tc, zorder=4, family="DejaVu Sans")


def arrow(ax, p0, p1, color=INK, lw=1.6, ls="-"):
    ax.add_patch(FancyArrowPatch(p0, p1, arrowstyle="-|>", mutation_scale=13,
                 color=color, lw=lw, ls=ls, zorder=2,
                 shrinkA=0, shrinkB=0))


def main():
    fig, ax = plt.subplots(figsize=(15.2, 10.6))
    fig.patch.set_facecolor("white")
    ax.set_xlim(0, 15.2)
    ax.set_ylim(0, 10.8)
    ax.axis("off")

    ax.text(7.6, 10.4, "fp_add - pipelined IEEE-754 binary32 adder / subtractor  (datapath)",
            ha="center", va="center", fontsize=15, color=INK, weight="bold")

    # ---- pipeline stage bands ------------------------------------------------
    bands = [(0.5, 3.15, "STAGE 1\nunpack / align", "#eef4ff"),
             (3.75, 3.15, "STAGE 2\nadd + normalize", "#eefaf1"),
             (7.0, 3.15, "STAGE 3\nround + pack", "#fdf0ee")]
    for bx, bw, label, fc in bands:
        ax.add_patch(Rectangle((bx, 1.0), bw, 8.2, fc=fc, ec="none", zorder=0))
        ax.text(bx + bw / 2, 9.35, label, ha="center", va="center",
                fontsize=10.5, color=GREY, weight="bold")
    # pipeline register boundaries
    for rx in (3.45, 6.7):
        ax.plot([rx, rx], [1.0, 9.2], color=GREY, lw=2.2, ls=(0, (5, 3)), zorder=1)
        ax.text(rx, 1.25, "pipe reg", rotation=90, ha="right", va="bottom",
                fontsize=8, color=GREY)

    # ---- inputs --------------------------------------------------------------
    box(ax, 0.15, 7.9, 1.15, 0.7, "a[31:0]", ec=BLUE, fs=10)
    box(ax, 0.15, 6.7, 1.15, 0.7, "b[31:0]", ec=BLUE, fs=10)
    box(ax, 0.15, 5.5, 1.15, 0.7, "sub", ec=ORANGE, fs=10)

    # ---- stage 1 -------------------------------------------------------------
    box(ax, 1.6, 6.9, 1.75, 1.8,
        "unpack\nsign / exp / frac\n+ hidden bit\n+ classify\nzero/Inf/NaN",
        ec=BLUE, fs=9)
    box(ax, 1.6, 4.75, 1.75, 1.35,
        "exponent\ncompare\n& swap\n(big / small)", ec=BLUE, fs=9)
    box(ax, 1.6, 2.55, 1.75, 1.5,
        "align shifter\nsmall >> (dE)\nguard/round\n/sticky", ec=BLUE, fs=9)

    arrow(ax, (1.3, 8.25), (1.6, 8.05), color=BLUE)
    arrow(ax, (1.3, 7.05), (1.6, 7.35), color=BLUE)
    arrow(ax, (1.3, 5.85), (1.6, 5.4), color=ORANGE)          # sub -> unpack/sign
    arrow(ax, (2.475, 6.9), (2.475, 6.1), color=INK)          # unpack -> cmp
    arrow(ax, (2.475, 4.75), (2.475, 4.05), color=INK)        # cmp -> align

    # ---- stage 2 -------------------------------------------------------------
    box(ax, 3.95, 5.7, 1.95, 1.6,
        "significand\nADD / SUB\n(eff. op =\nsign_a ^ sign_b)", ec=GREEN, fs=9.5)
    box(ax, 3.95, 3.05, 1.95, 1.7,
        "leading-zero\ncount +\nnormalize\n<< / >>,\nadjust exp", ec=GREEN, fs=9.5)
    arrow(ax, (3.45, 6.7), (3.95, 6.6), color=INK)            # big/small aligned -> add
    arrow(ax, (3.45, 3.3), (3.95, 3.9), color=INK)
    arrow(ax, (4.925, 5.7), (4.925, 4.75), color=INK)         # add -> normalize

    # ---- stage 3 -------------------------------------------------------------
    box(ax, 7.2, 5.7, 2.0, 1.6,
        "round to\nnearest-even\n(G,R,S + LSB)\ncarry fix-up", ec=RED, fs=9.5)
    box(ax, 7.2, 3.05, 2.0, 1.7,
        "over/underflow\n-> Inf / denorm\n+ repack\nsign|exp|frac", ec=RED, fs=9.5)
    arrow(ax, (6.7, 5.0), (7.2, 6.1), color=INK)              # normalized -> round
    arrow(ax, (8.2, 5.7), (8.2, 4.75), color=INK)             # round -> pack

    # ---- special-case bypass -------------------------------------------------
    box(ax, 3.95, 7.9, 5.25, 0.85,
        "special-case unit:  NaN in -> qNaN   |   Inf +/- Inf -> NaN   |   "
        "Inf -> Inf   |   x + (-x) -> +0", ec=PURP, tc=PURP, fs=9.2, lw=1.5)
    ax.plot([2.475, 2.475, 6.575], [6.9, 8.32, 8.32], color=PURP, lw=1.4,
            ls=(0, (4, 2)), zorder=1)
    arrow(ax, (9.2, 8.1), (11.3, 6.7), color=PURP, ls=(0, (4, 2)))

    # ---- output mux + result -------------------------------------------------
    box(ax, 10.4, 5.55, 1.5, 1.9, "result\nMUX\n(special?\narith)", ec=INK, fs=9.5)
    arrow(ax, (9.2, 5.1), (10.4, 5.9), color=INK)             # packed arith -> mux
    box(ax, 12.6, 6.0, 1.9, 0.95, "result[31:0]\nout_valid", fc="#fff8e6",
        ec=ORANGE, fs=10)
    arrow(ax, (11.9, 6.5), (12.6, 6.47), color=ORANGE)

    # ---- clock / valid rail --------------------------------------------------
    ax.add_patch(Rectangle((0.5, 0.35), 14.0, 0.5, fc="#f4f4f4", ec=GREY, lw=1.0))
    ax.text(0.75, 0.6, "clk", ha="left", va="center", fontsize=9.5, color=GREEN)
    ax.text(1.6, 0.6, "rst_n (sync)", ha="left", va="center", fontsize=9.5, color=GREY)
    ax.text(4.0, 0.6,
            "in_valid pipelined 3 stages -> out_valid    |    throughput = 1 add/clock    "
            "|    latency = 3 clocks    |    parameterized EXP_W / MAN_W",
            ha="left", va="center", fontsize=9.2, color=INK)

    ax.text(7.6, 0.05,
            "Schematic of the RTL datapath (hand-drawn), not a captured signal trace.",
            ha="center", va="center", fontsize=8.5, color=GREY, style="italic")

    plt.tight_layout()
    fig.savefig("fp_add_block.png", dpi=130, bbox_inches="tight", facecolor="white")
    print("wrote fp_add_block.png")


if __name__ == "__main__":
    main()
