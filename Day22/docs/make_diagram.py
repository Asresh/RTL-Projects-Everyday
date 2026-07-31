#!/usr/bin/env python3
"""Render docs/crc32_parallel_diagram.png — a block/circuit diagram of the
parallel CRC-32 engine: the DATA_WIDTH-way unrolled GF(2) next-state cone
feeding the CRC state register, with the terminator/result path."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle, Circle

BLUE = "#1f4e8c"; VIOLET = "#6d3bcf"; GREEN = "#1b8a4b"
INK = "#1f2d4d"; GREY = "#6b7280"; LILAC = "#efeafb"; SKY = "#e8f0fb"

fig, ax = plt.subplots(figsize=(13.5, 7.6))
ax.set_xlim(0, 13.5); ax.set_ylim(0, 7.6); ax.axis("off")

def box(x, y, w, h, fc, ec, txt, fs=10, tc=INK, style="round,pad=0.02,rounding_size=0.12"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle=style,
                                fc=fc, ec=ec, lw=1.6, zorder=2))
    ax.text(x+w/2, y+h/2, txt, ha="center", va="center", fontsize=fs,
            color=tc, zorder=3, family="monospace")

def arrow(x0, y0, x1, y1, color=INK, lw=1.6, ls="-"):
    ax.add_patch(FancyArrowPatch((x0, y0), (x1, y1),
                 arrowstyle="-|>", mutation_scale=13, color=color, lw=lw,
                 linestyle=ls, zorder=1, shrinkA=0, shrinkB=0))

ax.text(6.75, 7.25, "Day 22 — Parallel (unrolled) CRC-32 engine  ·  IEEE 802.3 Ethernet FCS",
        ha="center", fontsize=13, color=INK, weight="bold")
ax.text(6.75, 6.9, "one DATA_WIDTH-bit slice per clock  ·  reflected poly 0xEDB88320  ·  "
        "init 0xFFFFFFFF  ·  xor-out 0xFFFFFFFF",
        ha="center", fontsize=9, color=GREY)

# ---- inputs -------------------------------------------------------------
box(0.3, 4.7, 2.0, 0.7, SKY, BLUE, "data[W-1:0]", 10)
box(0.3, 3.75, 2.0, 0.55, "white", GREY, "init / en / last", 8.5, GREY)

# ---- seed mux -----------------------------------------------------------
box(3.0, 4.55, 1.5, 1.0, "white", BLUE, "SEED\nmux", 9)
ax.text(3.75, 4.4, "init? FFFFFFFF : crc_r", ha="center", fontsize=7, color=GREY)
arrow(2.3, 5.05, 3.0, 5.05, BLUE)                    # data into region (upper)
arrow(2.3, 4.0, 2.62, 4.0, GREY)                     # controls
ax.text(2.62, 4.0, "", ha="left")

# ---- unrolled GF(2) cone -------------------------------------------------
cone_x, cone_y, cone_w, cone_h = 5.0, 3.9, 4.2, 2.35
ax.add_patch(FancyBboxPatch((cone_x, cone_y), cone_w, cone_h,
             boxstyle="round,pad=0.02,rounding_size=0.15",
             fc=LILAC, ec=VIOLET, lw=1.8, zorder=2))
ax.text(cone_x+cone_w/2, cone_y+cone_h-0.28,
        "unrolled next-state cone  crc_next()", ha="center",
        fontsize=9.5, color=VIOLET, weight="bold")
ax.text(cone_x+cone_w/2, cone_y+cone_h-0.62,
        "W serial LFSR steps, flattened at elaboration", ha="center",
        fontsize=7.5, color=GREY)

# little chain of XOR/shift stages inside
n_stages = 4
sx = cone_x + 0.55
for i in range(n_stages):
    cx = sx + i*0.95
    ax.add_patch(Circle((cx, cone_y+0.85), 0.17, fc="white", ec=VIOLET, lw=1.4, zorder=3))
    ax.text(cx, cone_y+0.85, "⊕", ha="center", va="center", fontsize=10, color=VIOLET, zorder=4)
    ax.text(cx, cone_y+0.42, f">>1", ha="center", fontsize=6.5, color=GREY)
    if i < n_stages-1:
        arrow(cx+0.17, cone_y+0.85, cx+0.95-0.17, cone_y+0.85, VIOLET, 1.2)
ax.text(sx + n_stages*0.95 - 0.1, cone_y+0.85, "· · ·  (W)", fontsize=8, color=VIOLET, va="center")

arrow(4.5, 5.05, 5.0, 5.05, BLUE)                    # seed mux -> cone

# ---- CRC state register --------------------------------------------------
box(9.7, 4.55, 1.7, 1.0, SKY, BLUE, "crc_r\n[31:0]", 10)
ax.text(10.55, 4.4, "state reg (D-FF)", ha="center", fontsize=7, color=GREY)
arrow(cone_x+cone_w, 5.05, 9.7, 5.05, VIOLET)        # cone -> reg
# feedback
arrow(10.55, 4.55, 10.55, 2.55, GREY, 1.3, ":")
arrow(10.55, 2.55, 3.75, 2.55, GREY, 1.3, ":")
arrow(3.75, 2.55, 3.75, 4.55, GREY, 1.3, ":")
ax.text(6.9, 2.4, "feedback: crc_r  (absorbed each en beat)", ha="center",
        fontsize=7.5, color=GREY, style="italic")

# ---- output xor + result reg --------------------------------------------
ax.add_patch(Circle((12.35, 5.05), 0.22, fc="white", ec=GREEN, lw=1.6, zorder=3))
ax.text(12.35, 5.05, "⊕", ha="center", va="center", fontsize=12, color=GREEN, zorder=4)
ax.text(12.35, 5.5, "FFFFFFFF", ha="center", fontsize=6.5, color=GREEN)
arrow(11.4, 5.05, 12.13, 5.05, BLUE)
box(11.6, 3.4, 1.7, 0.75, "white", GREEN, "crc_o", 9, GREEN)
arrow(12.35, 4.83, 12.35, 4.15, GREEN)

# result register (latched on last)
box(9.7, 1.15, 3.6, 0.8, "white", GREEN,
    "result_o  (latched on `last`)  +  result_valid_o", 8.5, GREEN)
arrow(12.35, 3.4, 12.35, 1.95, GREEN)
ax.text(12.55, 2.7, "close frame", fontsize=7, color=GREEN, rotation=90, va="center")

# clk/rst rail
ax.text(0.3, 0.5, "clk ▸   rst_n ▸ (synchronous, active-low)", fontsize=8.5, color=GREY)

# legend
ax.text(0.3, 6.35, "throughput: 1 slice / clock", fontsize=8.5, color=BLUE)
ax.text(0.3, 6.05, "W=8 → 1 B/clk   W=32 → 4 B/clk   W=64 → 8 B/clk", fontsize=8, color=GREY)

plt.tight_layout()
plt.savefig("crc32_parallel_diagram.png", dpi=140, bbox_inches="tight")
print("wrote crc32_parallel_diagram.png")
