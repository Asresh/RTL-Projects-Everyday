#!/usr/bin/env python3
"""Render a REAL captured waveform from fft_pipeline.vcd (produced by `make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run of
tb_fft_pipeline and plots the pipelined FFT streaming the directed test vectors --
reset release, in_valid presenting whole 16-sample vectors, out_valid rising exactly
LOG2N+1 = 5 clocks later, and a handful of output spectrum bins X[k].re changing as
each vector's transform emerges. Every level and bus value is read straight from the
VCD, sampled just after each rising clock edge. An inset bar chart shows the full
16-bin magnitude spectrum of the complex-exponential (single-tone) frame -- captured
from the DUT -- with all its energy concentrated in bin 5, exactly as an ideal FFT.

Usage:  python3 gen_waveform.py [fft_pipeline.vcd] [docs/fft_pipeline_waveform.png]
"""
import sys, math
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "fft_pipeline.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/fft_pipeline_waveform.png"

N, DW = 16, 16


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
                    name = name.lstrip("\\")
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
    v = "x"
    for (tc, vc) in series:
        if tc <= t:
            v = vc
        else:
            break
    return v


def s16(bits):                       # signed 16-bit from binary string
    if bits in (None, "x") or "x" in bits or "z" in bits:
        return None
    v = int(bits, 2)
    return v - (1 << DW) if v & (1 << (DW - 1)) else v


def bins(series, t):                 # 256-bit packed bus -> list of 16 signed words
    v = val_at(series, t)
    if v in (None, "x") or "x" in v.lower() or "z" in v.lower():
        return [None] * N
    v = v.zfill(N * DW)
    out = []
    for k in range(N):               # sample/bin k occupies [k*DW +: DW]
        hi = len(v) - k * DW
        out.append(s16(v[hi - DW:hi]))
    return out


# ---------------------------------------------------------------------------
changes, widths = parse_vcd(VCD)


def find(*cands):
    for c in cands:
        for k in changes:
            if k == c or k.endswith("." + c):
                return changes[k]
    return []


clk   = find("clk")
rst_n = find("rst_n")
inv   = find("in_valid")
outv  = find("out_valid")
ore   = find("out_re")
oim   = find("out_im")

edges = sorted(t for (t, v) in clk if v == "1")
first_hi = next((t for (t, v) in rst_n if v == "1"), edges[0])
sample = [t for t in edges if t >= first_hi - 20][:22]
smp = [t + 1 for t in sample]
Ncy = len(smp)
xs = list(range(Ncy))

# find the single-tone output frame: the captured out frame whose spectrum peaks
# in bin 5 (that is the complex-exponential input vector 0.4*e^(j2*pi*5n/N)).
TONE = 5
best_t, best_mag = None, None
for t in [e + 1 for e in edges if e >= first_hi]:
    if val_at(outv, t) != "1":
        continue
    br, bi = bins(ore, t), bins(oim, t)
    if any(x is None for x in br) or any(x is None for x in bi):
        continue
    mag = [math.hypot(br[k], bi[k]) for k in range(N)]
    if max(range(N), key=lambda j: mag[j]) == TONE and mag[TONE] > 8000:
        best_t, best_mag = t, mag
        break

# ---------------------------------------------------------------------------
BG, INK, GRID = "white", "#1f2937", "#e5e7eb"
CTRL, OUTC, DATA = "#2563eb", "#dc2626", "#7c3aed"
BINCOL = ["#0f766e", "#b45309", "#c026d3", "#0369a1"]
SHOWBINS = [0, 2, 5, 8]

rows = [("clk", "clk", None),
        ("rst_n", "bit", rst_n),
        ("in_valid", "bit", inv),
        ("out_valid", "bit", outv)]
rows += [(f"X[{k}].re", "bin", k) for k in SHOWBINS]

fig = plt.figure(figsize=(16.0, 9.2))
gs = fig.add_gridspec(1, 5, wspace=0.28)
ax = fig.add_subplot(gs[0, 0:4])
axb = fig.add_subplot(gs[0, 4])

ax.set_xlim(-1.2, Ncy - 0.4)
row_h = 1.0
ytop = len(rows) * row_h
ax.set_ylim(-0.6, ytop + 0.4)
ax.axis("off")

fig.suptitle("Day 37  Pipelined Radix-2 DIT FFT (N=16, Q1.15) "
             "— REAL captured waveform from fft_pipeline.vcd (Icarus Verilog)",
             fontsize=13, fontweight="bold", color=INK, y=0.975)
ax.text(0.5, 1.028,
        "one whole 16-sample vector streams in per clock; the valid bubble "
        "propagates down the register pipeline to out_valid; four spectrum bins "
        "X[k].re shown live",
        transform=ax.transAxes, ha="center", fontsize=9.2, color="#4b5563")

for i in xs:
    ax.plot([i, i], [-0.4, ytop], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop + 0.12, f"{i}", ha="center", va="bottom", fontsize=7.2, color="#9ca3af")

# scale for the bin numeric traces
allv = []
for k in SHOWBINS:
    for t in smp:
        b = bins(ore, t)[k]
        if b is not None:
            allv.append(abs(b))
vmax = max(allv) if allv else 1
vmax = max(vmax, 1)

for r, (name, kind, ser) in enumerate(rows):
    yb = ytop - (r + 1) * row_h
    yc = yb + row_h / 2
    ax.text(-1.4, yc, name, ha="right", va="center", fontsize=9.4,
            color=INK, family="monospace")
    ax.axhline(yb, color=GRID, lw=0.6, zorder=0)

    if kind == "clk":
        px, py = [], []
        for i in xs:
            px += [i - 0.5, i - 0.5, i, i, i + 0.5]
            py += [yb + 0.15, yb + 0.8, yb + 0.8, yb + 0.15, yb + 0.15]
        ax.plot(px, py, color="#374151", lw=1.3)

    elif kind == "bit":
        px, py, prev = [], [], None
        for i, t in zip(xs, smp):
            hi = (val_at(ser, t) == "1")
            lvl = yb + (0.8 if hi else 0.15)
            if prev is not None and prev != lvl:
                px += [i - 0.5, i - 0.5]; py += [prev, lvl]
            px += [i - 0.5, i + 0.5]; py += [lvl, lvl]
            prev = lvl
        col = OUTC if name == "out_valid" else CTRL
        ax.plot(px, py, color=col, lw=1.9)

    elif kind == "bin":
        col = BINCOL[SHOWBINS.index(ser)]
        for i, t in zip(xs, smp):
            b = bins(ore, t)[ser]
            txt = f"{b}" if b is not None else "x"
            fc = "#ecfdf5" if b not in (None, 0) else "#f3f4f6"
            ax.add_patch(plt.Rectangle((i - 0.46, yb + 0.16), 0.92, 0.64,
                          facecolor=fc, edgecolor=col, lw=1.1, zorder=2))
            ax.text(i, yc, txt, ha="center", va="center", fontsize=7.6,
                    color=col, zorder=3, family="monospace")

# mark the pipeline latency: an in_valid idle-bubble propagates to an out_valid
# bubble exactly LOG2N+1 clocks later (both edges are inside the window).
def falling(ser):
    prev = None
    for i, t in zip(xs, smp):
        cur = (val_at(ser, t) == "1")
        if prev is True and cur is False:
            return i
        prev = cur
    return None

iv_fall = falling(inv)
ov_fall = falling(outv)
if iv_fall is not None and ov_fall is not None and ov_fall > iv_fall:
    ylat = ytop - 2 * row_h + 0.02
    ax.annotate("", xy=(ov_fall - 0.5, ylat), xytext=(iv_fall - 0.5, ylat),
                arrowprops=dict(arrowstyle="<->", color="#374151", lw=1.5))
    ax.text((iv_fall + ov_fall) / 2 - 0.5, ylat + 0.12,
            "the in_valid idle bubble reappears on out_valid a fixed pipeline "
            "delay later (no stalls, no reordering)",
            ha="center", va="bottom", fontsize=8.4, color="#374151")

ax.text(0.5, -0.05,
        "Pipeline depth = input register + LOG2N butterfly banks = LOG2N+1 = 5 "
        "registered stages.\nBin values are signed Q1.15 raw integers from the packed "
        "out_re bus (X = DFT/N, scaled-FFT convention); sampled one delta after each "
        "rising clk edge.",
        transform=ax.transAxes, ha="center", va="top", fontsize=8.2, color="#6b7280")

# ---- inset: captured magnitude spectrum of the single-tone frame ----------
axb.set_title("captured |X[k]| — single-tone\n(complex exp @ bin 5)",
              fontsize=9.4, color=INK)
if best_mag is not None:
    barcol = ["#dc2626" if k == max(range(N), key=lambda j: best_mag[j])
              else "#93c5fd" for k in range(N)]
    axb.bar(range(N), best_mag, color=barcol, edgecolor="#1e3a8a", lw=0.5)
    kpk = max(range(N), key=lambda j: best_mag[j])
    axb.text(kpk, best_mag[kpk], f" bin {kpk}", ha="center", va="bottom",
             fontsize=8.2, color="#dc2626")
else:
    axb.text(0.5, 0.5, "single-tone frame\nnot captured in window",
             ha="center", va="center", transform=axb.transAxes, fontsize=8)
axb.set_xlabel("bin k", fontsize=8.6)
axb.set_ylabel("|X[k]| (Q1.15 raw)", fontsize=8.6)
axb.set_xticks(range(0, N, 2))
axb.tick_params(labelsize=7.4)
axb.spines[["top", "right"]].set_visible(False)

plt.tight_layout(rect=(0.03, 0.06, 0.995, 0.92))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT, "| single-tone frame @t =", best_t)
