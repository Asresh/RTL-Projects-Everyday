#!/usr/bin/env python3
"""Render the l1_dcache_4way circuit / datapath diagram to
docs/l1_dcache_4way_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, NOT a simulator
capture): the address split, the four parallel tag/valid/dirty ways with their
comparators feeding the hit-OR and the way mux, the word mux and the
byte-enable merge network on the store path, the true-LRU rank file with its
victim selector, the line buffer that drives the writeback / refill bursts, and
the miss FSM that sequences all of it. Two insets give the true-LRU rank update
equations and the FSM state sequence the RTL implements.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

CPU_C  = "#0369a1"   # CPU-side port
TAG_C  = "#7c3aed"   # tag / valid / dirty arrays
CMP_C  = "#16a34a"   # comparators / hit logic
DAT_C  = "#0f766e"   # data array & muxes
LRU_C  = "#b45309"   # replacement policy
FSM_C  = "#be185d"   # miss FSM
WB_C   = "#dc2626"   # writeback path
FIL_C  = "#2563eb"   # refill path
INK    = "#1f2937"
MUT    = "#6b7280"
GRID   = "#e5e7eb"

fig, ax = plt.subplots(figsize=(17.5, 11.0))
ax.set_xlim(0, 178)
ax.set_ylim(0, 112)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=9.3, lw=1.9, z=3):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=z))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=z + 1, linespacing=1.35)


def arrow(x1, y1, x2, y2, c=INK, lw=1.7, ls="-", rad=0.0, ms=12, z=2):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=ms, linewidth=lw, color=c, linestyle=ls,
                 zorder=z, connectionstyle=f"arc3,rad={rad}"))


def lab(x, y, t, c=INK, fs=8.0, style="italic", ha="center", rot=0, fw="normal"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, fontstyle=style,
            zorder=6, rotation=rot, fontweight=fw)


def group(x, y, w, h, title, c):
    ax.add_patch(plt.Rectangle((x, y), w, h, facecolor=c, alpha=0.045,
                 edgecolor=c, lw=1.1, linestyle="--", zorder=1))
    ax.text(x + 1.6, y + h + 1.4, title, ha="left", va="center", fontsize=8.6,
            color=c, fontweight="bold", zorder=6)


fig.suptitle("Day 39  4-Way Set-Associative Write-Back / Write-Allocate L1 Data Cache "
             "— circuit / datapath diagram",
             fontsize=14, fontweight="bold", color=INK, y=0.975)
ax.text(0.5, 1.028, "hand-drawn schematic of the built circuit (not a simulator capture)",
        transform=ax.transAxes, ha="center", fontsize=9.4, color=MUT, fontstyle="italic")

# ===================================================================== #
# address split
# ===================================================================== #
group(2, 92, 74, 14, "cpu_addr[31:0]  address decomposition", CPU_C)
fields = [("tag [31:10]", 4, 30, TAG_C), ("index [9:4]", 34, 20, DAT_C),
          ("word [3:2]", 54, 11, DAT_C), ("byte [1:0]", 65, 9, MUT)]
for name, x, w, c in fields:
    ax.add_patch(plt.Rectangle((x, 95.5), w, 7.0, facecolor="white",
                 edgecolor=c, lw=1.7, zorder=3))
    ax.text(x + w / 2, 99.0, name, ha="center", va="center", fontsize=8.6,
            color=c, zorder=4, family="monospace")
lab(19, 93.6, "22 b -> compared", c=TAG_C, fs=7.4)
lab(44, 93.6, "6 b -> selects 1 of 64 sets", c=DAT_C, fs=7.4)
lab(59.5, 93.6, "1 of 4 words", c=DAT_C, fs=7.4)
lab(69.5, 93.6, "be", c=MUT, fs=7.4)

# CPU port
box(90, 94.5, 40, 11,
    "CPU port  (single outstanding)\n"
    "cpu_req / cpu_we / cpu_be[3:0]\ncpu_wdata[31:0] -> cpu_rdata, cpu_ack",
    CPU_C, fs=8.4)

# ===================================================================== #
# the four ways
# ===================================================================== #
group(2, 44, 96, 44, "4 parallel ways — tag/valid/dirty + 128-bit line, all read in ONE cycle", TAG_C)

WAY_Y = [80.0, 71.0, 62.0, 53.0]
for k, y in enumerate(WAY_Y):
    ax.add_patch(plt.Rectangle((6, y), 15, 7.0, facecolor="white",
                 edgecolor=TAG_C, lw=1.6, zorder=3))
    ax.text(13.5, y + 3.5, f"tag[{k}]  v d", ha="center", va="center",
            fontsize=8.2, color=TAG_C, zorder=4, family="monospace")
    # comparator
    ax.add_patch(plt.Polygon([[25, y + 0.4], [25, y + 6.6], [31.5, y + 3.5]],
                 closed=True, facecolor="white", edgecolor=CMP_C, lw=1.6, zorder=3))
    ax.text(27.2, y + 3.5, "=", ha="center", va="center", fontsize=10,
            color=CMP_C, zorder=4, fontweight="bold")
    arrow(21, y + 3.5, 25, y + 3.5, c=TAG_C, lw=1.4, ms=10)
    arrow(31.5, y + 3.5, 38, y + 3.5, c=CMP_C, lw=1.4, ms=10)
    # data line
    ax.add_patch(plt.Rectangle((52, y), 26, 7.0, facecolor="white",
                 edgecolor=DAT_C, lw=1.6, zorder=3))
    ax.text(65, y + 3.5, f"data line[{k}]  128 b", ha="center", va="center",
            fontsize=8.2, color=DAT_C, zorder=4, family="monospace")
    arrow(78, y + 3.5, 84, y + 3.5, c=DAT_C, lw=1.4, ms=10)

# tag broadcast bus from the address split
ax.plot([19, 19], [95.5, 92.4], color=TAG_C, lw=1.7, zorder=2)
ax.plot([19, 3.2], [92.4, 92.4], color=TAG_C, lw=1.7, zorder=2)
for y in WAY_Y:
    ax.plot([3.2, 3.2], [92.4, y + 5.0], color=TAG_C, lw=1.3, zorder=2)
    arrow(3.2, y + 5.0, 25, y + 5.0, c=TAG_C, lw=1.1, ls=":", ms=9)

# index bus
ax.plot([44, 44], [95.5, 93.4], color=DAT_C, lw=1.7, zorder=2)
ax.plot([44, 49.5], [93.4, 93.4], color=DAT_C, lw=1.7, zorder=2)
arrow(49.5, 93.4, 49.5, 87.6, c=DAT_C, lw=1.7)
lab(64.0, 91.0, "index addresses one set in every way", c=DAT_C, fs=7.2)

# hit OR / way encoder
box(38, 62, 12, 25, "hit\nOR\n+\nway\nenc", CMP_C, fs=8.6)
box(84, 62, 12, 25, "4:1\nway\nmux\n(hit_way)", DAT_C, fs=8.6)
arrow(50, 74.5, 84, 74.5, c=CMP_C, lw=1.5, rad=-0.10)
lab(67, 78.6, "hit_way[1:0] selects the matching way", c=CMP_C, fs=7.4)

# ===================================================================== #
# word mux / merge / CPU return
# ===================================================================== #
group(102, 44, 74, 44, "read return & byte-enable store merge", DAT_C)

box(106, 74, 26, 11, "4:1 word mux\naddr[3:2]", DAT_C, fs=8.8)
arrow(96, 74.5, 106, 79.5, c=DAT_C, lw=1.6)
arrow(132, 79.5, 150, 79.5, c=CMP_C, lw=1.8)
box(150, 74, 24, 11, "cpu_rdata\n+ cpu_ack\n(same cycle on hit)", CMP_C, fs=8.4)

box(106, 58, 26, 12, "byte-enable\nmerge network\n(read-modify-write)", DAT_C, fs=8.4)
arrow(119, 74, 119, 70, c=DAT_C, lw=1.5)
ax.plot([137, 137], [94.5, 64.0], color=CPU_C, lw=1.5, ls="--", zorder=2)
arrow(137, 64.0, 132.4, 64.0, c=CPU_C, lw=1.5, ls="--")
lab(139.0, 88.0, "cpu_wdata\ncpu_be", c=CPU_C, fs=7.4, ha="left")
# merged line written back into the way
ax.plot([106, 101], [64.0, 64.0], color=DAT_C, lw=1.6, zorder=2)
ax.plot([101, 101], [64.0, 48.0], color=DAT_C, lw=1.6, zorder=2)
ax.plot([101, 65], [48.0, 48.0], color=DAT_C, lw=1.6, zorder=2)
arrow(65, 48.0, 65, 52.6, c=DAT_C, lw=1.6)
lab(80, 49.8, "store hit: merged 128-bit line rewritten in place, dirty := 1", c=DAT_C, fs=7.4)

box(140, 58, 34, 12,
    "write policy\nWRITE-BACK + WRITE-ALLOCATE\nno memory traffic until eviction",
    WB_C, fs=8.0)

# ===================================================================== #
# LRU rank file + victim select
# ===================================================================== #
group(2, 22, 96, 19, "true-LRU replacement (rank file, one permutation per set)", LRU_C)

for k in range(4):
    x = 7 + k * 15
    ax.add_patch(plt.Rectangle((x, 30), 13, 7.0, facecolor="white",
                 edgecolor=LRU_C, lw=1.6, zorder=3))
    ax.text(x + 6.5, 33.5, f"age[{k}]  2b", ha="center", va="center",
            fontsize=8.0, color=LRU_C, zorder=4, family="monospace")
lab(34, 27.4, "rank 0 = MRU  ...  rank 3 = LRU   (always a permutation of the 4 ways)",
    c=LRU_C, fs=7.6)

box(70, 26, 26, 13, "victim select\ninvalid way first,\nelse rank == 3", LRU_C, fs=8.4)
arrow(66, 33.5, 70, 33.5, c=LRU_C, lw=1.5)
arrow(44, 61.6, 44, 41.5, c=LRU_C, lw=1.3, ls=":", ms=10)
lab(46.0, 51.5, "any access (hit or alloc)\npromotes its way to rank 0", c=LRU_C, fs=7.4, ha="left")

# ===================================================================== #
# miss FSM + line buffer + memory port
# ===================================================================== #
group(102, 4, 74, 37, "miss sequencer & burst memory port", FSM_C)

box(106, 26, 30, 13, "MISS FSM\nSEL -> WB -> FILL -> ALLOC\n+ flush walk", FSM_C, fs=8.4)
arrow(96, 32.5, 106, 32.5, c=LRU_C, lw=1.6)
lab(101, 35.4, "victim\nway", c=LRU_C, fs=7.2)

box(106, 9, 30, 12, "line buffer\n128 b (4 x 32 b)\nbeat counter", DAT_C, fs=8.4)
arrow(121, 26, 121, 21.4, c=FSM_C, lw=1.5)

box(146, 9, 28, 30,
    "burst memory port\n\n"
    "mem_wr_req + mem_addr\nmem_wdata / wvalid / wready\n\n"
    "mem_rd_req + mem_addr\nmem_rdata / rvalid",
    MUT, fs=8.0)
arrow(136, 16.0, 146, 16.0, c=WB_C, lw=1.8)
lab(141, 18.4, "evict\n4 beats", c=WB_C, fs=7.2)
arrow(146, 30.0, 136, 30.0, c=FIL_C, lw=1.8)
lab(141, 32.6, "refill\n4 beats", c=FIL_C, fs=7.2)

# victim line out of the data array into the line buffer
ax.plot([65, 65], [52.6, 43.5], color=WB_C, lw=1.5, zorder=2)
ax.plot([65, 121], [43.5, 43.5], color=WB_C, lw=1.5, zorder=2)
arrow(121, 43.5, 121, 21.0, c=WB_C, lw=1.5, ls="--")
lab(84, 45.2, "dirty victim line -> line buffer -> memory", c=WB_C, fs=7.4)

# refilled line back into the data array + ALLOC answer to the CPU
ax.plot([106, 99.0], [15.0, 15.0], color=FIL_C, lw=1.5, zorder=2)
ax.plot([99.0, 99.0], [15.0, 56.5], color=FIL_C, lw=1.5, zorder=2)
ax.plot([99.0, 80.0], [56.5, 56.5], color=FIL_C, lw=1.5, ls="--", zorder=2)
arrow(80.0, 56.5, 78.4, 56.5, c=FIL_C, lw=1.5, ls="--")
lab(91.0, 60.0, "refilled line -> allocate\n(+ merge pending store)", c=FIL_C, fs=7.4)

box(2, 4, 96, 15,
    "flush engine  —  walks all 64 sets x 4 ways; every valid+dirty line is streamed to memory\n"
    "and its dirty bit cleared (clean flush: lines stay resident, so a post-flush access still hits).\n"
    "Reuses exactly the same writeback datapath as an eviction (wb_is_flush selects the return path).",
    "#64748b", fs=8.2)

# ===================================================================== #
# insets
# ===================================================================== #
ax.add_patch(FancyBboxPatch((140, 92), 36, 15,
             boxstyle="round,pad=0.5,rounding_size=1.4",
             facecolor="#fffbeb", edgecolor=LRU_C, lw=1.4, zorder=3))
ax.text(158, 104.4, "true-LRU rank update (on any access to way w)",
        ha="center", va="center", fontsize=7.8, color=LRU_C,
        fontweight="bold", zorder=4)
ax.text(142, 98.6,
        "for k in 0..3:\n"
        "    if age[k] < age[w]: age[k] <= age[k] + 1\n"
        "age[w] <= 0\n"
        "victim = way whose age == 3",
        ha="left", va="center", fontsize=7.4, color=INK, zorder=4,
        family="monospace", linespacing=1.5)

ax.text(2, 21.0,
        "geometry: 64 sets x 4 ways x 16 B line = 4 KB  |  hit latency 1 cycle (1 req/clk)  "
        "|  clean miss = 2 + refill beats  |  dirty miss = evict burst + refill burst",
        ha="left", va="center", fontsize=8.2, color=MUT, fontstyle="italic")

plt.tight_layout(rect=(0.01, 0.01, 0.99, 0.93))
fig.savefig("docs/l1_dcache_4way_block.png", dpi=140, facecolor="white")
print("wrote docs/l1_dcache_4way_block.png")
