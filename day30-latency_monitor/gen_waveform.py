#!/usr/bin/env python3
"""Render a REAL captured waveform from latency_monitor.vcd (produced by
`make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run
of tb_latency_monitor and plots the directed corner-case sequence -- reset, NCO
warm-up, tag-matched measurements landing in different histogram bins, an orphan
t1, overlapping out-of-order probes, a simultaneous t0+t1, and an NCO freeze --
sampling each signal just after every rising clock edge (where the registered
outputs are valid). Every level and value shown is read straight from the VCD.

Usage:  python3 gen_waveform.py [latency_monitor.vcd] [docs/latency_monitor_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "latency_monitor.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/latency_monitor_waveform.png"


def parse_vcd(path):
    """Parse a VCD, registering only the top testbench scope (depth 1)."""
    code2names, widths, changes = {}, {}, {}
    t, in_defs, depth = 0, True, 0
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if in_defs:
                if s.startswith("$scope"):
                    depth += 1
                elif s.startswith("$upscope"):
                    depth -= 1
                elif s.startswith("$var") and depth == 1:
                    p = s.split()
                    width, code, name = int(p[2]), p[3], p[4]
                    code2names.setdefault(code, []).append(name)
                    widths[name] = width
                elif s.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if s[0] == "#":
                t = int(s[1:])
            elif s[0] in "01xzXZ":
                code = s[1:]
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, s[0]))
            elif s[0] in "bB":
                val, code = s[1:].split()
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, val))
            elif s[0] in "rR":
                pass
    return changes, widths


def val_at(series, t):
    """Value of a signal at time t (last change at or before t)."""
    v = None
    for (tt, vv) in series:
        if tt <= t:
            v = vv
        else:
            break
    return v


def to_int(bits):
    if bits is None:
        return None
    if bits in ("x", "z", "X", "Z"):
        return None
    b = bits.lstrip("bB")
    if any(c in "xzXZ" for c in b):
        return None
    try:
        return int(b, 2)
    except ValueError:
        return None


changes, widths = parse_vcd(VCD)

# rising clock edges from the clk series
clk = changes.get("clk", [])
edges = [t for (t, v) in clk if v == "1"]
# directed sequence is the first ~21 cycles (ends on the NCO-hold, before the
# randomized soak begins)
NCYC = 21
edges = edges[:NCYC]
# sample a hair after each posedge so registered outputs have settled
SAMPLE = [e + 1 for e in edges]

# ---- signals to show (name, label, kind) -----------------------------------
# kind: 'bit' single-bit level, 'bus' multi-bit value label
ROWS = [
    ("rst",          "rst",            "bit"),
    ("run_i",        "run_i",          "bit"),
    ("now_o",        "now_o (ns)",     "bus"),
    ("t0_valid_i",   "t0_valid",       "bit"),
    ("t0_tag_i",     "t0_tag",         "bus"),
    ("t1_valid_i",   "t1_valid",       "bit"),
    ("t1_tag_i",     "t1_tag",         "bus"),
    ("meas_valid_o", "meas_valid",     "bit"),
    ("meas_tag_o",   "meas_tag",       "bus"),
    ("meas_lat_o",   "meas_lat (ns)",  "bus"),
    ("orphan_o",     "orphan",         "bit"),
    ("outstanding_o","outstanding",    "bus"),
    ("cnt_o",        "cnt",            "bus"),
    ("min_o",        "min (ns)",       "bus"),
    ("max_o",        "max (ns)",       "bus"),
    ("last_o",       "last (ns)",      "bus"),
]

BIT_C = "#2563eb"
BUS_C = "#0f766e"
INK   = "#1f2937"
GRID  = "#e5e7eb"

n = len(ROWS)
fig, ax = plt.subplots(figsize=(15.5, 9.4))
row_h = 1.0
gap = 0.32

ax.set_xlim(-3.2, NCYC)
ax.set_ylim(-0.6, n * (row_h + gap))
ax.axis("off")

# cycle grid + numbers
for c in range(NCYC + 1):
    ax.plot([c, c], [-0.4, n * (row_h + gap) - gap + 0.1],
            color=GRID, lw=0.8, zorder=0)
for c in range(NCYC):
    ax.text(c + 0.5, n * (row_h + gap) - gap + 0.4, str(c),
            ha="center", va="bottom", fontsize=7.5, color="#9ca3af")
ax.text(-3.1, n * (row_h + gap) - gap + 0.4, "cycle:",
        ha="left", va="bottom", fontsize=8, color="#9ca3af", fontstyle="italic")

for ri, (sig, label, kind) in enumerate(ROWS):
    y = (n - 1 - ri) * (row_h + gap)
    ax.text(-3.1, y + row_h / 2, label, ha="left", va="center",
            fontsize=9.2, color=INK)
    series = changes.get(sig, [])
    if kind == "bit":
        prev = None
        for i, ts in enumerate(SAMPLE):
            v = val_at(series, ts)
            lvl = 1 if v == "1" else 0
            x0, x1 = i, i + 1
            yv = y + (row_h * 0.72 if lvl else row_h * 0.10)
            ax.plot([x0, x1], [yv, yv], color=BIT_C, lw=1.9, zorder=3)
            if prev is not None and prev != lvl:
                ax.plot([x0, x0],
                        [y + row_h * 0.10, y + row_h * 0.72],
                        color=BIT_C, lw=1.9, zorder=3)
            prev = lvl
    else:
        last_v = None
        seg_start = 0
        vals = []
        for i, ts in enumerate(SAMPLE):
            vals.append(to_int(val_at(series, ts)))
        # draw each cycle as a value cell; merge equal neighbours
        i = 0
        while i < NCYC:
            j = i
            while j + 1 < NCYC and vals[j + 1] == vals[i]:
                j += 1
            x0, x1 = i, j + 1
            vtxt = "x" if vals[i] is None else str(vals[i])
            ax.add_patch(plt.Rectangle((x0 + 0.04, y + 0.12),
                         (x1 - x0) - 0.08, row_h * 0.66,
                         facecolor="#ecfdf5", edgecolor=BUS_C, lw=1.2, zorder=2))
            ax.text((x0 + x1) / 2, y + row_h * 0.45, vtxt,
                    ha="center", va="center", fontsize=8.2, color=INK, zorder=4)
            i = j + 1

# annotation band
ann = [
    (1.5,  "reset"),
    (5.0,  "measA: lat=4 (bin2)"),
    (8.5,  "measB: lat=8 (bin3)"),
    (13.5, "overlap: retire 5 then 4"),
    (16.0, "orphan"),
    (18.5, "t0+t1 same cyc"),
    (20.5, "NCO hold"),
]
for x, txt in ann:
    ax.text(x, -0.5, txt, ha="center", va="top", fontsize=7.6,
            color="#6b7280", fontstyle="italic")

ax.set_title(
    "latency_monitor — REAL captured VCD (Icarus Verilog), sampled just after each rising clock edge",
    fontsize=12, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
