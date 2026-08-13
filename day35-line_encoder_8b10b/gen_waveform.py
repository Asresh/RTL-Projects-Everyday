#!/usr/bin/env python3
"""Render a REAL captured waveform from encoder_8b10b.vcd (produced by `make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run of
tb_encoder_8b10b and plots the very first characters the DUT emits -- the D.00
known-answer pair and the K.28.5 comma among them -- showing valid_i / k_i, the
8-bit input byte, the resulting 10-bit line code, valid_o, and the 1-bit running
disparity rd_o flipping as non-neutral sub-blocks are emitted. Every level and bus
value is read straight from the VCD, sampled just after each rising clock edge
(where the registered output datapath is valid).

Usage:  python3 gen_waveform.py [encoder_8b10b.vcd] [docs/encoder_8b10b_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "encoder_8b10b.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/encoder_8b10b_waveform.png"


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
    v = None
    for (tt, vv) in series:
        if tt <= t:
            v = vv
        else:
            break
    return v


def to_int(bits):
    if bits is None or bits in ("x", "z", "X", "Z"):
        return None
    b = bits.lstrip("bB")
    if any(c in "xzXZ" for c in b):
        return None
    try:
        return int(b, 2)
    except ValueError:
        return None


changes, _ = parse_vcd(VCD)
clk = changes.get("clk", [])
edges = [t for (t, v) in clk if v == "1"]

# find the first rising edge where valid_o becomes 1 (first emitted character)
vo = changes.get("valid_o", [])
first_hi = next((t for (t, v) in vo if v == "1"), edges[3] if edges else 0)
e0 = next((i for i, e in enumerate(edges) if e >= first_hi), 1)
e0 = max(0, e0 - 2)
NCYC = 14
win = edges[e0:e0 + NCYC]
NCYC = len(win)
SAMPLE = [e + 1 for e in win]

ROWS = [
    ("rst_n",      "rst_n",    "bit"),
    ("valid_i",    "valid_i",  "bit"),
    ("k_i",        "k_i",      "bit"),
    ("data_i",     "data_i",   "hex8"),
    ("valid_o",    "valid_o",  "bit"),
    ("code_o",     "code_o[9:0] (a..j)", "bin10"),
    ("rd_o",       "rd_o (0=RD-,1=RD+)", "bit"),
    ("code_err_o", "code_err", "bit"),
]

BIT_C = "#2563eb"; IN_C = "#7c3aed"; OUT_C = "#0f766e"; RD_C = "#c026d3"; INK = "#1f2937"; GRID = "#e5e7eb"

n = len(ROWS); row_h = 1.0; gap = 0.42; LEFT = 3.9
fig, ax = plt.subplots(figsize=(17.5, 8.0))
ax.set_xlim(-LEFT, NCYC)
ax.set_ylim(-2.1, n * (row_h + gap))
ax.axis("off")

for c in range(NCYC + 1):
    ax.plot([c, c], [-0.4, n * (row_h + gap) - gap + 0.1], color=GRID, lw=0.8, zorder=0)
for c in range(NCYC):
    ax.text(c + 0.5, n * (row_h + gap) - gap + 0.4, str(c),
            ha="center", va="bottom", fontsize=7.5, color="#9ca3af")
ax.text(-LEFT + 0.1, n * (row_h + gap) - gap + 0.4, "cycle:",
        ha="left", va="bottom", fontsize=8, color="#9ca3af", fontstyle="italic")

K28_5 = 0xBC


def draw_bit(y, series, color=BIT_C):
    prev = None
    for i, ts in enumerate(SAMPLE):
        v = val_at(series, ts)
        lvl = 1 if v == "1" else 0
        yv = y + (row_h * 0.72 if lvl else row_h * 0.10)
        ax.plot([i, i + 1], [yv, yv], color=color, lw=2.2, zorder=3)
        if prev is not None and prev != lvl:
            ax.plot([i, i], [y + row_h * 0.10, y + row_h * 0.72], color=color, lw=2.2, zorder=3)
        prev = lvl


for ri, (sig, label, kind) in enumerate(ROWS):
    y = (n - 1 - ri) * (row_h + gap)
    ax.text(-LEFT + 0.1, y + row_h / 2, label, ha="left", va="center", fontsize=9.4, color=INK)
    series = changes.get(sig, [])
    vi = changes.get("valid_o", [])
    if kind == "bit":
        col = RD_C if sig == "rd_o" else BIT_C
        draw_bit(y, series, col)
    elif kind == "hex8":
        for i, ts in enumerate(SAMPLE):
            iv = to_int(val_at(series, ts))
            valid_in = (val_at(changes.get("valid_i", []), ts) == "1")
            txt = "--" if iv is None or not valid_in else ("%02X" % iv)
            isk = valid_in and iv == K28_5
            ax.add_patch(plt.Rectangle((i + 0.08, y + 0.20), 0.84, row_h * 0.58,
                         facecolor="#fef2ff" if isk else "#f5f3ff",
                         edgecolor=RD_C if isk else IN_C, lw=1.1, zorder=2))
            ax.text(i + 0.5, y + row_h * 0.47, txt, ha="center", va="center",
                    fontsize=9.0, color=INK, zorder=4, family="monospace")
            if isk:
                ax.text(i + 0.5, y + row_h * 0.86, "K.28.5", ha="center", va="bottom",
                        fontsize=6.6, color=RD_C, fontstyle="italic")
    elif kind == "bin10":
        for i, ts in enumerate(SAMPLE):
            iv = to_int(val_at(series, ts))
            vo_hi = (val_at(vi, ts) == "1")
            txt = "----------" if (iv is None or not vo_hi) else format(iv, "010b")
            ax.add_patch(plt.Rectangle((i + 0.03, y + 0.20), 0.94, row_h * 0.58,
                         facecolor="#ecfdf5" if vo_hi else "#f3f4f6",
                         edgecolor=OUT_C if vo_hi else "#d1d5db", lw=1.1, zorder=2))
            ax.text(i + 0.5, y + row_h * 0.47, txt, ha="center", va="center",
                    fontsize=7.4, color=INK, zorder=4, family="monospace")

ax.text(-LEFT + 0.1, -0.95,
        "Each cycle: the byte on data_i (with k_i) is registered out one clock later as the 10-bit line code, and rd_o holds the running disparity AFTER that code.",
        ha="left", va="top", fontsize=8.4, color="#6b7280", fontstyle="italic")
ax.text(-LEFT + 0.1, -1.5,
        "The K.28.5 comma (data_i=BC, k_i=1) emits 0011111010 at RD- / 1100000101 at RD+ -- the unique 0011111/1100000 pattern the receiver locks byte alignment onto.",
        ha="left", va="top", fontsize=8.4, color=RD_C, fontstyle="italic")

ax.set_title(
    "encoder_8b10b - REAL captured VCD (Icarus Verilog): first emitted characters, "
    "sampled just after each rising clock edge",
    fontsize=11.5, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
