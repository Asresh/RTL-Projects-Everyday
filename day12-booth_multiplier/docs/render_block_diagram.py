#!/usr/bin/env python3
"""Draw the Day12 booth_multiplier circuit as a datapath / block diagram.

The picture shows the actual built circuit for the default WIDTH=16 signed
configuration, left -> right through the 4 pipeline stages:

  stage 0 : operand registers  a_r, b_r
  stage 1 : radix-4 Booth encoder (b_r -> 8 signed digits) + 8 partial-product
            generators (each picks 0 / +/-M / +/-2M from a_r and shifts it)
  stage 2 : Wallace-style 3:2 carry-save reduction tree  (8 -> 6 -> 4 -> 3 -> 2)
  stage 3 : final carry-propagate adder (CPA) -> 32-bit product register

The carry-save reduction tree is drawn from the SAME schedule the RTL's
`csa_reduce` function executes (triples compressed with 3:2 CSAs from index 0,
leftovers passed through), so the tree topology matches booth_multiplier.sv.
This is a schematic of the datapath, not a simulator screenshot.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle

WIDTH = 16
MW    = WIDTH                 # even -> internal width == WIDTH
G     = MW // 2              # 8 partial products

GREEN, BLUE, RED, GREY, ORANGE = "#0b8f3a", "#1f6feb", "#b3261e", "#8a8a8a", "#d97706"
INK, SLATE = "#111", "#334155"


def reduce_schedule(g):
    """Replay csa_reduce: return per-level (ops, out_count).
    ops is a list of ('csa',[a,b,c]) / ('pass',[a]) over the level's node indices.
    """
    levels = []
    cnt = g
    while cnt > 2:
        ops, i = [], 0
        while i + 3 <= cnt:
            ops.append(('csa', [i, i + 1, i + 2]))
            i += 3
        while i < cnt:
            ops.append(('pass', [i]))
            i += 1
        out = sum(2 if o[0] == 'csa' else 1 for o in ops)
        levels.append((ops, out))
        cnt = out
    return levels, cnt


def main():
    fig, ax = plt.subplots(figsize=(16.5, 8.6))
    fig.patch.set_facecolor("white")

    def box(x, y, w, h, fc, ec, text, fs=9, tc=INK, lw=1.3, bold=False):
        ax.add_patch(FancyBboxPatch((x - w/2, y - h/2), w, h,
                     boxstyle="round,pad=0.02", linewidth=lw,
                     edgecolor=ec, facecolor=fc, zorder=3))
        ax.text(x, y, text, ha="center", va="center", fontsize=fs, color=tc,
                zorder=4, fontweight=("bold" if bold else "normal"))

    def ff(x, y, h):
        """small pipeline-register marker (a thin filled bar)."""
        ax.add_patch(Rectangle((x - 0.05, y - h/2), 0.10, h, linewidth=1.0,
                     edgecolor=GREEN, facecolor="#e9f7ee", zorder=6))

    def arrow(x0, y0, x1, y1, color=SLATE, lw=1.4, style="-|>"):
        ax.annotate("", xy=(x1, y1), xytext=(x0, y0),
                    arrowprops=dict(arrowstyle=style, color=color, lw=lw),
                    zorder=2)

    YMID = 4.6

    # ------------------------------------------------------------------ stage 0
    x_op = 1.4
    box(x_op, YMID + 1.1, 1.7, 0.8, "#eef2ff", SLATE, "a_r\n[15:0]", fs=9)
    box(x_op, YMID - 1.1, 1.7, 0.8, "#eef2ff", SLATE, "b_r\n[15:0]", fs=9)
    ax.text(x_op, YMID + 3.4, "operands\n(a=multiplicand,\n b=multiplier)",
            ha="center", va="center", fontsize=8.4, color="#475569")

    # ------------------------------------------------------------------ stage 1
    x_be = 4.0
    box(x_be, YMID - 1.1, 2.0, 1.5, "#fff3e0", ORANGE,
        "radix-4 BOOTH\nENCODER\nb_r -> 8 digits\n{-2,-1,0,+1,+2}", fs=7.8)
    # 8 partial-product generators
    x_pp = 6.7
    pp_h = 0.62
    pp_gap = 0.20
    pp_top = YMID + 3.0
    pp_y = [pp_top - i * (pp_h + pp_gap) for i in range(G)]
    for i in range(G):
        box(x_pp, pp_y[i], 1.7, pp_h,
            "#eef2ff", "#33415c", f"PP{i}  (<<{2*i})", fs=7.2)
    ax.text(x_pp, pp_top + 0.85, f"{G} partial products",
            ha="center", va="center", fontsize=8.6, color=INK, fontweight="bold")
    ax.text(x_pp, pp_top + 0.55, "each = 0 / +/-M / +/-2M  of a_r",
            ha="center", va="center", fontsize=7.6, color="#475569")

    # a_r feeds every PP generator (multiplicand); booth digits steer the select
    arrow(x_op + 0.85, YMID + 1.1, x_pp - 0.9, pp_y[0] + 0.4, color=BLUE)
    ax.text((x_op + x_pp)/2 - 0.2, YMID + 2.55, "a_r (M, 2M)", fontsize=7.4,
            color=BLUE, ha="center")
    arrow(x_op + 0.85, YMID - 1.1, x_be - 1.0, YMID - 1.1, color=SLATE)
    for i in range(G):
        arrow(x_be + 1.0, YMID - 1.1 + 0.02*i, x_pp - 0.86, pp_y[i],
               color=ORANGE, lw=0.8, style="->")

    # ------------------------------------------------------------------ stage 2
    levels, final_cnt = reduce_schedule(G)
    # x columns for each node-level (level 0 = the 8 PP outputs)
    tree_x0 = 9.1
    col_w   = 1.35
    ncols   = len(levels) + 1
    col_x   = [tree_x0 + c * col_w for c in range(ncols)]
    # y layout: spread `cnt` nodes across a fixed band
    band_hi, band_lo = pp_top, pp_top - (G - 1) * (pp_h + pp_gap)
    def ys(cnt):
        if cnt == 1:
            return [(band_hi + band_lo) / 2]
        return [band_hi - k * (band_hi - band_lo) / (cnt - 1) for k in range(cnt)]

    counts = [G] + [out for (_, out) in levels]
    node_y = [ys(c) for c in counts]

    # draw nodes (small dots) at every level
    for ci, cnt in enumerate(counts):
        for k in range(cnt):
            ax.scatter([col_x[ci]], [node_y[ci][k]], s=16, color=SLATE, zorder=5)

    # connect PP0..7 outputs into level-0 nodes
    for i in range(G):
        arrow(x_pp + 0.86, pp_y[i], col_x[0] - 0.02, node_y[0][i],
               color="#94a3b8", lw=0.8, style="-")

    # draw each reduction level's CSA blocks / pass wires
    for li, (ops, out) in enumerate(levels):
        xs, xd = col_x[li], col_x[li + 1]
        dst = 0
        for kind, idxs in ops:
            if kind == 'csa':
                ymid = sum(node_y[li][j] for j in idxs) / 3.0
                bx = (xs + xd) / 2.0
                box(bx, ymid, 0.62, 0.5, "#e9f7ee", GREEN, "3:2", fs=7.0,
                    tc=GREEN, lw=1.1)
                for j in idxs:
                    arrow(xs + 0.03, node_y[li][j], bx - 0.32, ymid,
                           color="#94a3b8", lw=0.7, style="-")
                # two outputs: sum, carry
                for _ in range(2):
                    arrow(bx + 0.32, ymid, xd - 0.03, node_y[li + 1][dst],
                           color="#94a3b8", lw=0.7, style="-")
                    dst += 1
            else:  # pass-through
                j = idxs[0]
                arrow(xs + 0.03, node_y[li][j], xd - 0.03, node_y[li + 1][dst],
                       color="#cbd5e1", lw=0.7, style="-")
                dst += 1
        # level count label
        ax.text((xs + xd)/2.0, band_hi + 0.55, f"{counts[li]}->{out}",
                ha="center", va="center", fontsize=7.8, color=GREEN)

    ax.text((col_x[0] + col_x[-1]) / 2.0, band_hi + 1.15,
            "Wallace 3:2 carry-save reduction tree", ha="center", va="center",
            fontsize=8.8, color=INK, fontweight="bold")
    ax.text((col_x[0] + col_x[-1]) / 2.0, band_lo - 0.55,
            "3:2 CSA:  sum = a^b^c,  carry = maj(a,b,c)<<1  (no carry propagation)",
            ha="center", va="center", fontsize=7.6, color="#475569")

    # the final two redundant vectors
    ax.text(col_x[-1] + 0.05, node_y[-1][0] + 0.32, "sum", fontsize=7.4,
            color=SLATE, ha="left")
    ax.text(col_x[-1] + 0.05, node_y[-1][1] - 0.32, "carry", fontsize=7.4,
            color=SLATE, ha="left")

    # ------------------------------------------------------------------ stage 3
    x_cpa  = col_x[-1] + 1.6
    x_prod = x_cpa + 2.1
    box(x_cpa, YMID, 1.5, 1.5, "#fdecea", RED,
        "CPA\ncarry-\npropagate\nadder", fs=8.0, tc=RED)
    for k in range(2):
        arrow(col_x[-1] + 0.03, node_y[-1][k], x_cpa - 0.78, YMID + (0.35 if k == 0 else -0.35),
               color="#94a3b8", lw=0.9, style="-|>")
    box(x_prod, YMID, 1.9, 1.0, "#e9f7ee", GREEN, "product\n[31:0]", fs=9,
        tc=INK, bold=True)
    arrow(x_cpa + 0.78, YMID, x_prod - 0.98, YMID, color=SLATE)
    arrow(x_prod + 0.98, YMID, x_prod + 1.7, YMID, color=SLATE)
    ax.text(x_prod + 1.75, YMID, "a*b", fontsize=9, color=INK, ha="left",
            va="center")

    # ------------------------------------------------------------ stage borders
    stage_bounds = [ (2.5,  "stage 0\noperand reg"),
                     (7.9,  "stage 1\nBooth + PP gen"),
                     (col_x[-1] + 0.7, "stage 2\nCSA tree"),
                     (x_prod + 2.6, "stage 3\nCPA + product reg") ]
    prev = 0.2
    for i, (xb, lbl) in enumerate(stage_bounds):
        last = (i == len(stage_bounds) - 1)
        if not last:
            ax.plot([xb, xb], [0.2, 8.7], color="#cbd5e1", lw=1.0, ls="--", zorder=1)
            ff(xb, YMID, 8.2)        # pipeline-register bar at each boundary
        ax.text((prev + xb) / 2.0, 0.55, lbl, ha="center", va="center",
                fontsize=8.2, color=GREEN, fontweight="bold")
        prev = xb

    ax.text((0.2 + stage_bounds[-1][0]) / 2.0, -0.15,
            "green bars = pipeline registers (4 register stages).  "
            "Throughput = 1 multiply / clock,  latency = 4 clocks.",
            ha="center", va="center", fontsize=8.6, color="#444")

    ax.set_xlim(-0.4, x_prod + 3.4)
    ax.set_ylim(-0.6, 9.4)
    ax.axis("off")
    ax.set_title("Day 12  booth_multiplier — pipelined radix-4 Booth multiplier "
                 "datapath (WIDTH=16, SIGNED: 8 partial products, 3:2 CSA tree, CPA)",
                 fontsize=12, pad=10)
    plt.tight_layout()
    fig.savefig("booth_multiplier_block.png", dpi=130, bbox_inches="tight",
                facecolor="white")
    print("wrote booth_multiplier_block.png")


if __name__ == "__main__":
    main()
