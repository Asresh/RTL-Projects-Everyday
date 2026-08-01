#!/usr/bin/env python3
"""Render a REAL captured waveform from aes128_enc.vcd (produced by `make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run
of tb_aes128_enc and plots the FIPS-197 Appendix C.1 block being enciphered --
start pulse, the initial AddRoundKey load, the 10 round-transform cycles (with
the round counter, the running cipher state, and the on-the-fly round key), and
the done pulse that latches the ciphertext. Every level and bus value shown is
read straight from the VCD, sampled just after each rising clock edge (where the
registered datapath is valid).

Usage:  python3 gen_waveform.py [aes128_enc.vcd] [docs/aes128_enc_waveform.png] [block]
        block = 1-based index of the start pulse to show (default 2 = FIPS C.1).
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD   = sys.argv[1] if len(sys.argv) > 1 else "aes128_enc.vcd"
OUT   = sys.argv[2] if len(sys.argv) > 2 else "docs/aes128_enc_waveform.png"
BLOCK = int(sys.argv[3]) if len(sys.argv) > 3 else 2      # FIPS-197 App. C.1


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
edges = [t for (t, v) in clk if v == "1"]          # rising clock edges

# locate the chosen block by the BLOCK-th rising edge of start_i
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
    e0 = 0
e0 = max(0, e0 - 1)                                 # one cycle of lead-in
NCYC = 13                                           # start + load + 10 rounds + done
win = edges[e0:e0 + NCYC]
NCYC = len(win)
SAMPLE = [e + 1 for e in win]                       # sample just after each posedge

# ---- signals to show (name, label, kind) -----------------------------------
ROWS = [
    ("rst_n",   "rst_n",     "bit"),
    ("start_i", "start",     "bit"),
    ("busy_o",  "busy",      "bit"),
    ("w_round", "round",     "dec"),
    ("w_state", "state",     "hex"),
    ("w_key",   "round_key", "hex"),
    ("done_o",  "done",      "bit"),
    ("valid_o", "valid",     "bit"),
    ("ct_o",    "ciphertext","hex"),
]

BIT_C = "#2563eb"
STA_C = "#0f766e"
KEY_C = "#7c3aed"
CT_C  = "#b45309"
INK   = "#1f2937"
GRID  = "#e5e7eb"

n = len(ROWS)
row_h = 1.0
gap   = 0.42
LEFT  = 5.6

fig, ax = plt.subplots(figsize=(18.5, 8.4))
ax.set_xlim(-LEFT, NCYC)
ax.set_ylim(-1.1, n * (row_h + gap))
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
    else:
        col = {"state": STA_C, "round_key": KEY_C, "ciphertext": CT_C}.get(label, STA_C)
        face = {"state": "#ecfdf5", "round_key": "#f5f3ff",
                "ciphertext": "#fff7ed"}.get(label, "#ecfdf5")
        for i, ts in enumerate(SAMPLE):
            iv = to_int(val_at(series, ts))
            x0, x1 = i, i + 1
            # ciphertext only meaningful once valid; round key/state always shown
            if kind == "dec":
                txt = "-" if iv is None else str(iv)
                ax.text((x0 + x1) / 2, y + row_h * 0.42, txt, ha="center",
                        va="center", fontsize=9.0, color=INK, zorder=4)
                continue
            txt = "--" if iv is None else ("%032X" % iv)
            ax.add_patch(plt.Rectangle((x0 + 0.04, y + 0.16),
                         (x1 - x0) - 0.08, row_h * 0.62,
                         facecolor=face, edgecolor=col, lw=1.0, zorder=2))
            ax.text((x0 + x1) / 2, y + row_h * 0.47, txt, ha="center",
                    va="center", fontsize=4.5, color=INK, zorder=4,
                    family="monospace")

# annotation band
def annot(x, txt, col="#6b7280"):
    ax.text(x, -0.72, txt, ha="center", va="top", fontsize=7.8,
            color=col, fontstyle="italic")

# first busy cycle = load (initial AddRoundKey); done cycle = latch ct
first_busy = next((i for i in range(NCYC) if busy[i] == "1"), None)
done_i = next((i for i in range(NCYC)
               if val_at(changes.get("done_o", []), SAMPLE[i]) == "1"), None)
if first_busy is not None:
    annot(first_busy + 0.5, "load:\nstate = pt XOR key\n(initial AddRoundKey)", STA_C)
    if first_busy + 5 < NCYC:
        annot(first_busy + 5.5, "10 round transforms\nSubBytes/ShiftRows/MixColumns/AddRoundKey\nround keys generated on the fly", KEY_C)
if done_i is not None:
    annot(done_i + 0.5, "done -> ciphertext\n69c4e0d8...70b4c55a", CT_C)

ax.set_title(
    "aes128_enc - REAL captured VCD (Icarus Verilog): FIPS-197 App. C.1 block "
    "(pt=00112233...eeff, key=000102...0f), sampled just after each rising clock edge",
    fontsize=11.5, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
