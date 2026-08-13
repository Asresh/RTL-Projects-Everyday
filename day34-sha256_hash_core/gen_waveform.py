#!/usr/bin/env python3
"""Render a REAL captured waveform from sha256_core.vcd (produced by `make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run
of tb_sha256_core and plots the "abc" known-answer block being hashed -- the
start/first pulse, the block load, and the first compression rounds where the
round counter climbs, the message-schedule word W[t] (`wt`) streams one word per
clock out of the 16-word rolling window, and the working registers a / e update
every clock. Every level and bus value shown is read straight from the VCD,
sampled just after each rising clock edge (where the registered datapath is
valid). After 64 such rounds the feed-forward add yields the FIPS-180-4 digest
ba7816bf...f20015ad (see caption).

Usage:  python3 gen_waveform.py [sha256_core.vcd] [docs/sha256_core_waveform.png] [block]
        block = 1-based index of the start pulse to show (default 2 = "abc").
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD   = sys.argv[1] if len(sys.argv) > 1 else "sha256_core.vcd"
OUT   = sys.argv[2] if len(sys.argv) > 2 else "docs/sha256_core_waveform.png"
BLOCK = int(sys.argv[3]) if len(sys.argv) > 3 else 2      # 2nd start = "abc"


def parse_vcd(path):
    """Parse a VCD, keying every signal by its full hierarchical path so both
    top-level TB ports (clk, start_i, ...) and DUT internals (dut.rnd, dut.wt,
    dut.a, ...) are available."""
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


changes, widths = parse_vcd(VCD)

clk   = changes.get("clk", [])
edges = [t for (t, v) in clk if v == "1"]                  # rising clock edges

start_series = changes.get("start_i", [])
start_rise, prev = [], "0"
for (t, v) in start_series:
    if v == "1" and prev != "1":
        start_rise.append(t)
    prev = v

if len(start_rise) >= BLOCK:
    t0 = start_rise[BLOCK - 1]
    e0 = next(i for i, e in enumerate(edges) if e >= t0)
else:
    e0 = 1
e0 = max(0, e0 - 2)                                         # lead-in
NCYC = 16
win = edges[e0:e0 + NCYC]
NCYC = len(win)
SAMPLE = [e + 1 for e in win]                              # sample just after posedge

# ---- signals to show : (vcd path, label, kind) -----------------------------
ROWS = [
    ("rst_n",   "rst_n",    "bit"),
    ("start_i", "start",    "bit"),
    ("first_i", "first",    "bit"),
    ("busy_o",  "busy",     "bit"),
    ("dut.rnd", "round t",  "dec"),
    ("dut.wt",  "W[t]",     "hex"),
    ("dut.a",   "a",        "hex"),
    ("dut.e",   "e",        "hex"),
    ("done_o",  "done",     "bit"),
]

BIT_C = "#2563eb"
RND_C = "#c026d3"
W_C   = "#7c3aed"
A_C   = "#0f766e"
E_C   = "#b45309"
INK   = "#1f2937"
GRID  = "#e5e7eb"

n = len(ROWS)
row_h = 1.0
gap   = 0.42
LEFT  = 3.4

fig, ax = plt.subplots(figsize=(17.5, 8.0))
ax.set_xlim(-LEFT, NCYC)
ax.set_ylim(-1.9, n * (row_h + gap))
ax.axis("off")

for c in range(NCYC + 1):
    ax.plot([c, c], [-0.4, n * (row_h + gap) - gap + 0.1],
            color=GRID, lw=0.8, zorder=0)
for c in range(NCYC):
    ax.text(c + 0.5, n * (row_h + gap) - gap + 0.4, str(c),
            ha="center", va="bottom", fontsize=7.5, color="#9ca3af")
ax.text(-LEFT + 0.1, n * (row_h + gap) - gap + 0.4, "cycle:",
        ha="left", va="bottom", fontsize=8, color="#9ca3af", fontstyle="italic")

busy = [val_at(changes.get("busy_o", []), ts) for ts in SAMPLE]

for ri, (sig, label, kind) in enumerate(ROWS):
    y = (n - 1 - ri) * (row_h + gap)
    ax.text(-LEFT + 0.1, y + row_h / 2, label, ha="left", va="center",
            fontsize=9.6, color=INK)
    series = changes.get(sig, [])
    if kind == "bit":
        prev = None
        for i, ts in enumerate(SAMPLE):
            v = val_at(series, ts)
            lvl = 1 if v == "1" else 0
            x0, x1 = i, i + 1
            yv = y + (row_h * 0.72 if lvl else row_h * 0.10)
            ax.plot([x0, x1], [yv, yv], color=BIT_C, lw=2.2, zorder=3)
            if prev is not None and prev != lvl:
                ax.plot([x0, x0], [y + row_h * 0.10, y + row_h * 0.72],
                        color=BIT_C, lw=2.2, zorder=3)
            prev = lvl
    elif kind == "dec":
        for i, ts in enumerate(SAMPLE):
            iv = to_int(val_at(series, ts))
            txt = "-" if iv is None else str(iv)
            shown = (busy[i] == "1")
            ax.text(i + 0.5, y + row_h * 0.42, txt if shown else "-",
                    ha="center", va="center", fontsize=9.6,
                    color=RND_C if shown else "#c0c4cc", zorder=4,
                    fontweight="bold")
    else:
        col  = {"W[t]": W_C, "a": A_C, "e": E_C}[label]
        face = {"W[t]": "#f5f3ff", "a": "#ecfdf5", "e": "#fff7ed"}[label]
        for i, ts in enumerate(SAMPLE):
            iv = to_int(val_at(series, ts))
            x0 = i
            txt = "--------" if iv is None else ("%08X" % iv)
            ax.add_patch(plt.Rectangle((x0 + 0.06, y + 0.18),
                         0.88, row_h * 0.60,
                         facecolor=face, edgecolor=col, lw=1.0, zorder=2))
            ax.text(x0 + 0.5, y + row_h * 0.47, txt, ha="center",
                    va="center", fontsize=7.0, color=INK, zorder=4,
                    family="monospace")


def annot(x, txt, col="#6b7280"):
    ax.text(x, -0.72, txt, ha="center", va="top", fontsize=7.8,
            color=col, fontstyle="italic")


first_busy = next((i for i in range(NCYC) if busy[i] == "1"), None)
if first_busy is not None:
    annot(first_busy - 0.5, "start+first:\nload block,\n(a..h)=IV", BIT_C)
    if first_busy + 4 < NCYC:
        annot(first_busy + 4.0,
              "64 compression rounds -- round t++ each clock;  W[t] streams one word/clock\n"
              "out of the 16-word rolling schedule window;  a,e (working state) update every clock",
              A_C)

ax.text(NCYC / 2 - LEFT / 2, -1.62,
        "after 64 rounds the Davies-Meyer feed-forward add commits the digest:  "
        "SHA-256(\"abc\") = ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad",
        ha="center", va="top", fontsize=8.6, color=E_C, fontweight="bold")

ax.set_title(
    "sha256_core - REAL captured VCD (Icarus Verilog): hashing the NIST \"abc\" block, "
    "sampled just after each rising clock edge",
    fontsize=11.5, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
