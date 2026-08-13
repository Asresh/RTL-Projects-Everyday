#!/usr/bin/env python3
"""Render the async_fifo circuit / block diagram to docs/async_fifo_block.png.

This is a schematic of the *built* circuit (hand-drawn with matplotlib, not a
simulator capture): the two clock domains, the dual-port memory, the two
binary+Gray pointer blocks, and the two 2-flop pointer synchronizers that carry
the Gray-coded pointers across the clock-domain boundary.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

W_C  = "#2563eb"   # write domain
R_C  = "#c026d3"   # read domain
MEM_C = "#0f766e"  # memory
SYN_C = "#b45309"  # synchronizers
INK  = "#1f2937"

fig, ax = plt.subplots(figsize=(14, 8.2))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.8, style="round"):
    if style == "round":
        p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.6,rounding_size=2",
                           linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3)
    else:
        p = Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                      facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.8, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                 arrowstyle="-|>", mutation_scale=15, linewidth=lw,
                 color=c, linestyle=ls, zorder=2,
                 connectionstyle=f"arc3,rad={rad}"))


def lbl(x, y, t, c=INK, fs=9, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c,
            zorder=5, fontstyle=style)


# ---- domain background bands ------------------------------------------------
ax.add_patch(Rectangle((1, 6), 40, 88, facecolor=W_C, alpha=0.06, zorder=0))
ax.add_patch(Rectangle((59, 6), 40, 88, facecolor=R_C, alpha=0.06, zorder=0))
ax.text(21, 91, "WRITE clock domain  (wclk / wrst_n)", ha="center",
        fontsize=11, color=W_C, fontweight="bold")
ax.text(79, 91, "READ clock domain  (rclk / rrst_n)", ha="center",
        fontsize=11, color=R_C, fontweight="bold")
# CDC boundary
ax.plot([50, 50], [7, 88], color="#9ca3af", ls=(0, (6, 4)), lw=1.6, zorder=1)
ax.text(50, 88.8, "clock-domain crossing", ha="center", fontsize=9,
        color="#6b7280", fontstyle="italic")

# ---- write side -------------------------------------------------------------
box(6, 60, 30, 15,
    "wptr_full\n\nbinary ctr  →  Gray  (wptr)\nfull = (wgray_next ==\n{~rq_gray[MSB:MSB-1], …})",
    W_C, fs=9)
# inputs
arrow(2, 71, 6, 71, W_C); lbl(1.5, 71, "wr_en", W_C, ha="right", style="normal")
arrow(2, 65, 6, 65, W_C); lbl(1.5, 65, "wdata", W_C, ha="right", style="normal")
# outputs from wptr block
arrow(21, 60, 21, 46, W_C)          # waddr / wen down to memory
lbl(23.5, 53, "waddr, wen", W_C, ha="left")
arrow(36, 67, 44, 67, W_C)          # wfull out to flag box
lbl(40, 69.6, "wfull", W_C, ha="center", style="normal")
box(44, 63, 12, 8, "wfull", W_C, fc="#eff6ff", fs=10)

# ---- read side --------------------------------------------------------------
box(64, 60, 30, 15,
    "rptr_empty\n\nbinary ctr  →  Gray  (rptr)\nempty = (rgray_next ==\nwq_gray_synced)",
    R_C, fs=9)
arrow(94, 71, 98, 71, R_C); lbl(98.5, 71, "rd_en", R_C, ha="left", style="normal")
arrow(79, 60, 79, 46, R_C)
lbl(81.5, 53, "raddr", R_C, ha="left")
box(44, 51, 12, 8, "rempty", R_C, fc="#fdf4ff", fs=10)
arrow(64, 63, 56.5, 55, R_C, rad=-0.2)
lbl(60, 60.5, "rempty", R_C, ha="center", style="normal")
arrow(94, 63, 98, 63, R_C); lbl(98.5, 63, "rdata", R_C, ha="left", style="normal")

# ---- memory -----------------------------------------------------------------
box(33, 33, 34, 13,
    "Dual-port FIFO memory\n(2**ADDR_WIDTH × DATA_WIDTH)\nsync write · show-ahead read",
    MEM_C, fc="#f0fdfa", fs=9.5)
arrow(67, 42, 79, 42, MEM_C)        # rdata path memory -> read domain out region
lbl(73, 44.5, "rdata", MEM_C)
arrow(79, 42, 94, 63, MEM_C, rad=0.15)

# ---- synchronizers ----------------------------------------------------------
def sync(x, y, title, c, direction):
    # two flops FF1 -> FF2
    box(x, y, 9, 7, "FF1", c, fc="white", fs=9, style="square")
    box(x + 13, y, 9, 7, "FF2", c, fc="white", fs=9, style="square")
    arrow(x + 9, y + 3.5, x + 13, y + 3.5, c)
    ax.text(x + 11, y + 9.2, title, ha="center", fontsize=8.5,
            color=c, fontstyle="italic")

# write Gray ptr -> read domain (sync_w2r)
sync(38.5, 20, "sync_w2r : wptr → rclk", SYN_C, "r")
arrow(16, 60, 16, 23.5, W_C, ls=(0, (4, 3)))         # wptr down
arrow(16, 23.5, 38.5, 23.5, W_C, ls=(0, (4, 3)))
lbl(24, 25.4, "wptr (Gray)", W_C, ha="center")
arrow(60.5, 23.5, 79, 23.5, R_C, ls=(0, (4, 3)))     # into rptr_empty
arrow(79, 23.5, 79, 60, R_C, ls=(0, (4, 3)))
lbl(70, 25.4, "wq2_rptr", R_C, ha="center")

# read Gray ptr -> write domain (sync_r2w)
sync(38.5, 10, "sync_r2w : rptr → wclk", SYN_C, "w")
arrow(84, 62, 84, 13.5, R_C, ls=(0, (4, 3)))         # rptr down
arrow(84, 13.5, 60.5, 13.5, R_C, ls=(0, (4, 3)))
lbl(74, 15.4, "rptr (Gray)", R_C, ha="center")
arrow(38.5, 13.5, 12, 13.5, W_C, ls=(0, (4, 3)))     # into wptr_full
arrow(12, 13.5, 12, 60, W_C, ls=(0, (4, 3)))
lbl(24, 15.4, "rq2_wptr", W_C, ha="center")

ax.text(50, 3.2,
        "Gray-coded pointers cross the boundary through 2-flop synchronizers; "
        "full/empty are computed locally in each domain.",
        ha="center", fontsize=9, color="#4b5563", fontstyle="italic")
ax.set_title("async_fifo — circuit / block diagram (dual-clock FIFO with Gray-pointer CDC)",
             fontsize=13, pad=12)

fig.tight_layout()
fig.savefig("docs/async_fifo_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/async_fifo_block.png")
