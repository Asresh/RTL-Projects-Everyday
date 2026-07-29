#!/usr/bin/env python3
"""Draw the Day11 bitonic_sorter circuit as a compare-exchange NETWORK diagram.

This is the actual built circuit for N=8: 8 lanes (horizontal wires) flowing
left->right through 6 pipeline stages of compare-exchange (CE) elements, with a
pipeline register column after every stage.  The stage list (k, j) and every CE
pair / direction are computed with the SAME formulas the RTL uses, so the picture
matches bitonic_sorter.sv exactly.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

N = 8
L = N.bit_length() - 1                 # log2(N) = 3
STAGES = L * (L + 1) // 2              # 6

def p_of_stage(s):
    p = 0
    while ((p + 1) * (p + 2)) // 2 <= s:
        p += 1
    return p

def kj(s):
    p = p_of_stage(s)
    m = s - (p * (p + 1)) // 2
    return (1 << (p + 1)), (1 << (p - m))     # (k, j)

def stage_pairs(s):
    """list of (i, l, asc) CE elements for stage s, matching the RTL."""
    k, j = kj(s)
    out = []
    for i in range(N):
        l = i ^ j
        if l > i:
            asc = ((i & k) == 0)          # ASCENDING=1 network
            out.append((i, l, asc))
    return out

def main():
    ylane = lambda i: (N - 1 - i)         # lane 0 drawn on TOP
    COLW = 2.0                            # width allotted to each stage column
    x0 = 1.3                              # left margin where wires start
    stage_x = [x0 + 0.7 + st * COLW for st in range(STAGES)]
    x_end = stage_x[-1] + COLW * 0.7 + 0.9

    fig, ax = plt.subplots(figsize=(15.5, 6.6))
    fig.patch.set_facecolor("white")
    GREEN, BLUE, RED, GREY, ORANGE = "#0b8f3a", "#1f6feb", "#b3261e", "#8a8a8a", "#d97706"

    # ---- lane wires ----
    for i in range(N):
        ax.plot([x0, x_end], [ylane(i), ylane(i)], color="#334155", lw=1.4, zorder=1)
        ax.text(x0 - 0.15, ylane(i), f"in[{i}]", ha="right", va="center",
                fontsize=9, color="#111")
        ax.text(x_end + 0.15, ylane(i), f"out[{i}]", ha="left", va="center",
                fontsize=9, color="#111")

    # ---- compare-exchange elements, per stage ----
    for st in range(STAGES):
        k, j = kj(st)
        pairs = stage_pairs(st)
        base_x = stage_x[st]
        # stagger the CE elements across the column so overlapping spans separate
        nsub = len(pairs)
        for idx, (i, l, asc) in enumerate(sorted(pairs)):
            cx = base_x - COLW * 0.30 + (idx + 0.5) * (COLW * 0.60) / nsub
            yi, yl = ylane(i), ylane(l)     # yi is the smaller index (upper)
            col = BLUE if asc else RED
            ax.plot([cx, cx], [yi, yl], color=col, lw=1.8, zorder=3)
            ax.scatter([cx, cx], [yi, yl], color=col, s=22, zorder=4)
            # arrowhead points to the lane that receives the LARGER key:
            #   ascending  -> larger goes to higher index (lower on screen)
            #   descending -> larger goes to lower index  (upper on screen)
            ytail, yhead = (yi, yl) if asc else (yl, yi)
            ax.annotate("", xy=(cx, yhead), xytext=(cx, ytail),
                        arrowprops=dict(arrowstyle="-|>", color=col, lw=1.8),
                        zorder=5)

        # stage label
        ax.text(base_x, N - 0.35, f"stage {st}", ha="center", va="bottom",
                fontsize=9, color="#111", fontweight="bold")
        ax.text(base_x, N - 0.72, f"k={k}, j={j}", ha="center", va="bottom",
                fontsize=8, color="#475569")

        # ---- pipeline register column after this stage ----
        rx = base_x + COLW * 0.42
        for i in range(N):
            ax.add_patch(FancyBboxPatch((rx - 0.06, ylane(i) - 0.12), 0.12, 0.24,
                         boxstyle="round,pad=0.01", linewidth=1.0,
                         edgecolor="#0b8f3a", facecolor="#e9f7ee", zorder=6))
        ax.text(rx, -0.75, "FF", ha="center", va="center", fontsize=7.5,
                color=GREEN)

    # input register column (before stage 0)
    rx0 = x0 + 0.35
    for i in range(N):
        ax.add_patch(FancyBboxPatch((rx0 - 0.06, ylane(i) - 0.12), 0.12, 0.24,
                     boxstyle="round,pad=0.01", linewidth=1.0,
                     edgecolor="#0b8f3a", facecolor="#e9f7ee", zorder=6))
    ax.text(rx0, -0.75, "FF", ha="center", va="center", fontsize=7.5, color=GREEN)
    ax.text((x0 + x_end) / 2.0, -1.25,
            "small green boxes = pipeline registers (7 register columns: 1 input + 6 stage regs).  "
            "Throughput = 1 vector/clock, latency = 7 clocks.",
            ha="center", va="center", fontsize=8.6, color="#444")

    # legend for CE direction
    lx, ly = x0 + 0.1, -2.2
    ax.plot([lx, lx], [ly, ly + 0.5], color=BLUE, lw=1.8)
    ax.annotate("", xy=(lx, ly), xytext=(lx, ly + 0.5),
                arrowprops=dict(arrowstyle="-|>", color=BLUE, lw=1.8))
    ax.text(lx + 0.15, ly + 0.25, "ascending CE (larger key -> lower lane)",
            ha="left", va="center", fontsize=8.4, color="#111")
    lx2 = lx + 6.6
    ax.plot([lx2, lx2], [ly, ly + 0.5], color=RED, lw=1.8)
    ax.annotate("", xy=(lx2, ly + 0.5), xytext=(lx2, ly),
                arrowprops=dict(arrowstyle="-|>", color=RED, lw=1.8))
    ax.text(lx2 + 0.15, ly + 0.25, "descending CE (larger key -> upper lane)",
            ha="left", va="center", fontsize=8.4, color="#111")

    ax.set_xlim(x0 - 1.4, x_end + 1.4)
    ax.set_ylim(-2.7, N + 0.4)
    ax.axis("off")
    ax.set_title("Day 11  bitonic_sorter — compare-exchange network "
                 "(N=8, 6 stages, 24 CE elements, fully pipelined)",
                 fontsize=12, pad=10)
    plt.tight_layout()
    fig.savefig("bitonic_sorter_block.png", dpi=130, bbox_inches="tight",
                facecolor="white")
    print("wrote bitonic_sorter_block.png")

if __name__ == "__main__":
    main()
