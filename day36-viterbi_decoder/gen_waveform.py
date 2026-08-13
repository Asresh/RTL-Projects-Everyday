#!/usr/bin/env python3
"""Render a REAL captured waveform from viterbi_decoder.vcd (produced by `make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run of
tb_viterbi_decoder and plots the decoder waking up on the first ("clean-A") stream --
reset release, symbols streaming in, the four Add-Compare-Select path metrics
pm[0..3] settling as the survivor paths converge, state_min tracking the current
minimum-metric trellis state, out_valid rising after the TB_LEN-deep survivor
registers fill, and the decoded bit_out. Every level and bus value is read straight
from the VCD, sampled just after each rising clock edge.

Usage:  python3 gen_waveform.py [viterbi_decoder.vcd] [docs/viterbi_decoder_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "viterbi_decoder.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/viterbi_decoder_waveform.png"


# ---------------------------------------------------------------------------
def parse_vcd(path):
    code2names, widths, changes = {}, {}, {}
    scope, in_defs, t = [], True, 0
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if in_defs:
                if s.startswith("$scope"):
                    scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    if scope:
                        scope.pop()
                elif s.startswith("$var"):
                    p = s.split()
                    width, code, name = int(p[2]), p[3], p[4]
                    name = name.lstrip("\\")           # \pm[0] -> pm[0]
                    path_name = ".".join(scope[1:] + [name]) if len(scope) > 1 else name
                    code2names.setdefault(code, []).append(path_name)
                    widths[path_name] = width
                elif s.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if s[0] == "#":
                t = int(s[1:])
            elif s[0] in "01xzXZ":
                for nm in code2names.get(s[1:], []):
                    changes.setdefault(nm, []).append((t, s[0]))
            elif s[0] in "bB":
                val, code = s[1:].split()
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, val))
    return changes, widths


def val_at(series, t):
    """Value of a signal at time t (last change <= t)."""
    v = "x"
    for (tc, vc) in series:
        if tc <= t:
            v = vc
        else:
            break
    return v


def to_int(v):
    try:
        return int(v, 2)
    except ValueError:
        return None


# ---------------------------------------------------------------------------
changes, widths = parse_vcd(VCD)


def find(*cands):
    for c in cands:
        for k in changes:
            if k == c or k.endswith("." + c):
                return changes[k]
    return []


clk      = find("clk")
rst_n    = find("rst_n")
in_valid = find("in_valid")
sym_in   = find("sym_in")
state_m  = find("state_min")
out_v    = find("out_valid")
bit_o    = find("bit_out")
pm       = [find(f"dut.pm[{i}]", f"pm[{i}]") for i in range(4)]

# posedge times of clk
edges = [t for (t, v) in clk if v == "1"]
edges.sort()

# capture a window that starts a little before reset release and shows warm-up.
# find first time rst_n is high, then take ~24 sampled cycles from just before.
first_hi = next((t for (t, v) in rst_n if v == "1"), edges[0])
sample = [t for t in edges if t >= first_hi - 20][:26]
smp = [t + 1 for t in sample]          # sample just after the edge

N = len(smp)
xs = list(range(N))

# ---------------------------------------------------------------------------
BG      = "white"
INK     = "#1f2937"
GRID    = "#e5e7eb"
CTRL    = "#2563eb"   # control 1-bit
DATA    = "#7c3aed"   # buses
MET     = ["#0f766e", "#b45309", "#c026d3", "#0369a1"]  # 4 path metrics
OUTC    = "#dc2626"   # decoded output

rows = [
    ("clk",       "clk",   None),
    ("rst_n",     "bit",   rst_n),
    ("in_valid",  "bit",   in_valid),
    ("sym_in",    "bus2",  sym_in),
    ("pm[0]",     "met",   pm[0]),
    ("pm[1]",     "met",   pm[1]),
    ("pm[2]",     "met",   pm[2]),
    ("pm[3]",     "met",   pm[3]),
    ("state_min", "bus2",  state_m),
    ("out_valid", "bit",   out_v),
    ("bit_out",   "bit",   bit_o),
]

fig, ax = plt.subplots(figsize=(15.5, 8.6))
ax.set_xlim(-0.6, N - 0.4)
row_h = 1.0
ytop = len(rows) * row_h
ax.set_ylim(-0.6, ytop + 0.4)
ax.axis("off")

fig.suptitle("Day 36  Hard-Decision Viterbi Decoder  (rate-1/2, K=3 (7,5)) "
             "— REAL captured waveform from viterbi_decoder.vcd (Icarus Verilog)",
             fontsize=13, fontweight="bold", color=INK, y=0.975)
ax.text(0.5, 1.012, "clean-A stream warm-up: symbols stream in, the four ACS path "
        "metrics settle, out_valid rises after the survivor registers fill",
        transform=ax.transAxes, ha="center", fontsize=9.6, color="#4b5563")

# vertical cycle guides + numbers
for i in xs:
    ax.plot([i, i], [-0.4, ytop], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop + 0.12, f"{i}", ha="center", va="bottom", fontsize=7.2, color="#9ca3af")

# metric scaling
allmet = []
for i in range(4):
    for t in smp:
        iv = to_int(val_at(pm[i], t))
        if iv is not None:
            allmet.append(iv)
mmax = max(allmet) if allmet else 1
mmax = max(mmax, 1)


def y_of(r):
    return ytop - (r + 0.5) * row_h


for r, (name, kind, series) in enumerate(rows):
    yb = ytop - (r + 1) * row_h
    yc = yb + row_h / 2
    ax.text(-0.8, yc, name, ha="right", va="center", fontsize=9.4,
            color=INK, family="monospace")
    ax.axhline(yb, color=GRID, lw=0.6, zorder=0)

    if kind == "clk":
        # draw a clock: high first half, low second half of each cell
        ys, xsx = [], []
        for i in xs:
            xsx += [i - 0.5, i, i, i + 0.5]
            ys  += [yb + 0.15, yb + 0.15, yb + 0.8, yb + 0.8]
        # simpler explicit square wave
        px, py = [], []
        for i in xs:
            px += [i - 0.5, i - 0.5, i, i, i + 0.5]
            py += [yb + 0.15, yb + 0.8, yb + 0.8, yb + 0.15, yb + 0.15]
        ax.plot(px, py, color="#374151", lw=1.3)

    elif kind == "bit":
        px, py = [], []
        prev = None
        for i, t in zip(xs, smp):
            v = val_at(series, t)
            hi = (v == "1")
            lvl = yb + (0.8 if hi else 0.15)
            if prev is not None and prev != lvl:
                px += [i - 0.5, i - 0.5]
                py += [prev, lvl]
            px += [i - 0.5, i + 0.5]
            py += [lvl, lvl]
            prev = lvl
        col = OUTC if name in ("out_valid", "bit_out") else CTRL
        ax.plot(px, py, color=col, lw=1.9)

    elif kind == "bus2":
        for i, t in zip(xs, smp):
            v = val_at(series, t)
            iv = to_int(v)
            txt = f"{iv}" if iv is not None else "x"
            ax.add_patch(plt.Rectangle((i - 0.46, yb + 0.15), 0.92, 0.65,
                          facecolor="#ede9fe", edgecolor=DATA, lw=1.1, zorder=2))
            ax.text(i, yc, txt, ha="center", va="center", fontsize=8.4,
                    color=DATA, zorder=3, family="monospace")

    elif kind == "met":
        idx = int(name[3])
        col = MET[idx]
        px, py = [], []
        for i, t in zip(xs, smp):
            iv = to_int(val_at(series, t))
            frac = (iv / mmax) if iv is not None else 0
            lvl = yb + 0.12 + 0.72 * frac
            px += [i - 0.5, i + 0.5]
            py += [lvl, lvl]
            # value annotation
            if iv is not None:
                ax.text(i, lvl + 0.02, f"{iv}", ha="center", va="bottom",
                        fontsize=6.6, color=col)
        # step connectors
        fx, fy = [], []
        prev = None
        for i, t in zip(xs, smp):
            iv = to_int(val_at(series, t))
            frac = (iv / mmax) if iv is not None else 0
            lvl = yb + 0.12 + 0.72 * frac
            if prev is not None:
                fx += [i - 0.5, i - 0.5]
                fy += [prev, lvl]
            fx += [i - 0.5, i + 0.5]
            fy += [lvl, lvl]
            prev = lvl
        ax.plot(fx, fy, color=col, lw=1.6)

# annotate out_valid rising edge
ov_rise = None
for i, t in zip(xs, smp):
    if val_at(out_v, t) == "1":
        ov_rise = i
        break
if ov_rise is not None:
    ax.annotate("survivors full → out_valid ↑",
                xy=(ov_rise - 0.5, ytop - 9.5 * row_h + 0.45),
                xytext=(ov_rise + 1.5, ytop - 8.4 * row_h),
                fontsize=8.6, color=OUTC,
                arrowprops=dict(arrowstyle="->", color=OUTC, lw=1.3))

ax.text(0.5, -0.055,
        "Path metrics pm[0..3] are drawn as accumulated-Hamming-distance levels "
        "(value printed above each step); after reset only pm[0]=0 so the trellis "
        "starts anchored in state 0. Sampled one delta after each rising clk edge.",
        transform=ax.transAxes, ha="center", fontsize=8.4, color="#6b7280")

plt.tight_layout(rect=(0.02, 0.03, 0.995, 0.95))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT)
