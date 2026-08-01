#!/usr/bin/env python3
"""Render the latency_monitor circuit / block diagram to
docs/latency_monitor_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator
capture): the NCO fractional-ns phase accumulator producing `now`, the
direct-mapped tag-matched timestamp-capture table, the wrap-safe latency
subtractor + hit detect, the floor(log2) bin encoder, and the registered
stats + power-of-two histogram back end.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

NCO_C = "#2563eb"   # timestamp / NCO
CAP_C = "#0f766e"   # capture table
LAT_C = "#c026d3"   # latency datapath
HST_C = "#b45309"   # stats / histogram
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(15.0, 9.2))
ax.set_xlim(0, 110)
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


def lbl(x, y, t, c=INK, fs=9, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, zorder=5,
            fontstyle=style)


ax.text(50, 96.5,
        "latency_monitor — hardware nanosecond-timestamp & tick-to-trade latency instrument",
        ha="center", fontsize=13, color=INK, fontweight="bold")

# outline
ax.add_patch(Rectangle((2, 6), 96, 86, facecolor="#f8fafc",
                       edgecolor="#cbd5e1", lw=1.4, zorder=0))

# ---- NCO timestamp clock ---------------------------------------------------
box(6, 74, 30, 13,
    "NCO phase accumulator\nphase += inc_i  (Q8.16 ns/cyc)\nadvances when run_i", NCO_C,
    fc="#eff6ff", fs=9.4)
arrow(3, 84, 6, 84, NCO_C);  lbl(2.6, 84, "run_i", NCO_C, ha="right", style="normal")
arrow(3, 78, 6, 78, NCO_C);  lbl(2.6, 78, "inc_i", NCO_C, ha="right", style="normal")
box(42, 76, 16, 9, "now  =\nphase >> FRAC_W", NCO_C, fc="#eff6ff", fs=9.2)
arrow(36, 80.5, 42, 80.5, NCO_C); lbl(39, 82.6, "phase", NCO_C, style="normal")
arrow(58, 80.5, 63, 80.5, NCO_C); lbl(88, 80.5, "now_o  (wire timestamp, ns)", NCO_C, ha="right", style="normal")
arrow(50, 76, 50, 64, NCO_C, rad=0.0)              # now -> capture + subtract
lbl(53, 70, "now", NCO_C, style="normal")

# ---- capture table ---------------------------------------------------------
box(6, 46, 30, 20,
    "tag-matched capture table\n(direct-mapped, NTAG slots)\n\n"
    "t0:  t0_ts[tag] <= now ; busy[tag]=1\nt1:  read t0_ts[tag], busy[tag]",
    CAP_C, fc="#f0fdfa", fs=9.0)
arrow(3, 60, 6, 60, CAP_C);  lbl(2.6, 60, "t0_valid / t0_tag", CAP_C, ha="right", style="normal")
arrow(3, 52, 6, 52, CAP_C);  lbl(2.6, 52, "t1_valid / t1_tag", CAP_C, ha="right", style="normal")

# ---- latency subtract + hit -----------------------------------------------
box(42, 52, 20, 12,
    "wrap-safe subtract\nlat = now − t0_ts[tag]\nhit = busy[tag] & t1_valid",
    LAT_C, fc="#fdf4ff", fs=9.0)
arrow(36, 58, 42, 58, CAP_C); lbl(39, 60, "t0_ts,\nbusy", CAP_C, style="normal")
arrow(50, 64, 50, 64, NCO_C)                      # (visual anchor)

box(42, 34, 20, 11,
    "floor(log2 lat)\nbin encoder\n→ bin ∈ [0, NBINS)", LAT_C, fc="#fdf4ff", fs=9.0)
arrow(52, 52, 52, 45, LAT_C); lbl(55, 48.5, "lat", LAT_C, style="normal")

# ---- stats + histogram -----------------------------------------------------
box(70, 46, 24, 20,
    "rolling stats (registered)\nmin · max · last · cnt\nsum (mean = sum/cnt)\n"
    "outstanding = popcount(busy)", HST_C, fc="#fff7ed", fs=9.0)
arrow(62, 58, 70, 58, LAT_C); lbl(66, 60, "lat / hit", LAT_C, style="normal")

box(70, 24, 24, 16,
    "power-of-two histogram\nhist[bin]++  (saturating)\n"
    "bin k = [2^k, 2^{k+1}) ns\ntop bin = tail catch-all", HST_C, fc="#fff7ed", fs=8.8)
arrow(62, 39, 70, 34, LAT_C); lbl(66, 38, "bin", LAT_C, style="normal")

# ---- registered outputs ----------------------------------------------------
box(70, 10, 24, 10,
    "OUTPUT REGISTERS\nmeas_valid/tag/lat · orphan\n1-clock deterministic latency",
    HST_C, fc="#fffbeb", fs=8.8)
arrow(82, 24, 82, 20, HST_C)
arrow(94, 15, 98, 15, HST_C); lbl(98.8, 15, "results", HST_C, ha="left", style="normal")
arrow(94, 56, 98, 56, HST_C); lbl(98.8, 56, "stats", HST_C, ha="left", style="normal")
arrow(94, 32, 98, 32, HST_C); lbl(98.8, 32, "hist_flat_o", HST_C, ha="left", style="normal")

# orphan path
arrow(52, 52, 70, 14, LAT_C, rad=-0.25)
lbl(60, 26, "t1 & !busy → orphan", LAT_C, style="normal")

ax.text(50, 8.4,
        "Every path is a fixed combinational cone feeding a register: a t1 at cycle C "
        "yields its measurement + updated stats at C+1,\nindependent of the latency value "
        "or the number of outstanding probes — worst-case latency == typical latency.",
        ha="center", fontsize=8.8, color="#4b5563", fontstyle="italic")

fig.tight_layout()
fig.savefig("docs/latency_monitor_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/latency_monitor_block.png")
