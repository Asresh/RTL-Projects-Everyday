#!/usr/bin/env python3
"""Render a REAL captured waveform from rs_encoder.vcd (produced by
`make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run
of tb_rs_encoder and plots one full codeword of the *ramp* directed block --
reset/start, the K=8 message symbols (0x10..0x17) passing through the systematic
datapath unchanged (cw_is_parity=0), then the 2T=8 Reed-Solomon parity symbols
being shifted out (cw_is_parity=1) with cw_last on the final symbol and a done
pulse.  Every level and bus value shown is read straight from the VCD, sampled
just after each rising clock edge (where the registered outputs are valid).

Usage:  python3 gen_waveform.py [rs_encoder.vcd] [docs/rs_encoder_waveform.png] [block]
        block = 1-based index of the codeword to show (default 5 = the ramp).
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD   = sys.argv[1] if len(sys.argv) > 1 else "rs_encoder.vcd"
OUT   = sys.argv[2] if len(sys.argv) > 2 else "docs/rs_encoder_waveform.png"
BLOCK = int(sys.argv[3]) if len(sys.argv) > 3 else 5      # ramp block


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
start_rise = []
prev = "0"
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
NCYC = 19                                           # start + 8 msg + 8 parity + tail
win = edges[e0:e0 + NCYC]
NCYC = len(win)
SAMPLE = [e + 1 for e in win]                       # sample just after each posedge

# ---- signals to show (name, label, kind) -----------------------------------
ROWS = [
    ("rst",            "rst",            "bit"),
    ("start_i",        "start",          "bit"),
    ("msg_valid_i",    "msg_valid",      "bit"),
    ("msg_data_i",     "msg_data",       "bus"),
    ("msg_ready_o",    "msg_ready",      "bit"),
    ("busy_o",         "busy",           "bit"),
    ("cw_valid_o",     "cw_valid",       "bit"),
    ("cw_data_o",      "cw_data",        "bus"),
    ("cw_is_parity_o", "is_parity",      "bit"),
    ("cw_last_o",      "cw_last",        "bit"),
    ("par_valid_o",    "par_valid",      "bit"),
    ("done_o",         "done",           "bit"),
]

BIT_C = "#2563eb"
BUS_C = "#0f766e"
PAR_C = "#b45309"
INK   = "#1f2937"
GRID  = "#e5e7eb"

n = len(ROWS)
fig, ax = plt.subplots(figsize=(16.5, 7.8))
row_h = 1.0
gap = 0.34

ax.set_xlim(-3.4, NCYC)
ax.set_ylim(-0.9, n * (row_h + gap))
ax.axis("off")

for c in range(NCYC + 1):
    ax.plot([c, c], [-0.4, n * (row_h + gap) - gap + 0.1],
            color=GRID, lw=0.8, zorder=0)
for c in range(NCYC):
    ax.text(c + 0.5, n * (row_h + gap) - gap + 0.4, str(c),
            ha="center", va="bottom", fontsize=7.5, color="#9ca3af")
ax.text(-3.3, n * (row_h + gap) - gap + 0.4, "cycle:",
        ha="left", va="bottom", fontsize=8, color="#9ca3af", fontstyle="italic")

# is_parity value per sampled cycle (to color the cw_data cells)
ispar = [val_at(changes.get("cw_is_parity_o", []), ts) for ts in SAMPLE]
cwval = [val_at(changes.get("cw_valid_o", []), ts) for ts in SAMPLE]
mval  = [val_at(changes.get("msg_valid_i", []), ts) for ts in SAMPLE]

for ri, (sig, label, kind) in enumerate(ROWS):
    y = (n - 1 - ri) * (row_h + gap)
    ax.text(-3.3, y + row_h / 2, label, ha="left", va="center",
            fontsize=9.2, color=INK)
    series = changes.get(sig, [])
    if kind == "bit":
        prev = None
        for i, ts in enumerate(SAMPLE):
            v = val_at(series, ts)
            lvl = 1 if v == "1" else 0
            x0, x1 = i, i + 1
            yv = y + (row_h * 0.72 if lvl else row_h * 0.10)
            ax.plot([x0, x1], [yv, yv], color=BIT_C, lw=2.0, zorder=3)
            if prev is not None and prev != lvl:
                ax.plot([x0, x0], [y + row_h * 0.10, y + row_h * 0.72],
                        color=BIT_C, lw=2.0, zorder=3)
            prev = lvl
    else:
        vals = [to_int(val_at(series, ts)) for ts in SAMPLE]
        for i in range(NCYC):
            # only draw a cell where the bus is meaningful this cycle
            if sig == "cw_data_o" and cwval[i] != "1":
                continue
            if sig == "msg_data_i" and mval[i] != "1":
                continue
            x0, x1 = i, i + 1
            vtxt = "--" if vals[i] is None else ("%02X" % vals[i])
            is_par_cell = (sig == "cw_data_o" and ispar[i] == "1")
            face = "#fff7ed" if is_par_cell else "#ecfdf5"
            edge = PAR_C if is_par_cell else BUS_C
            ax.add_patch(plt.Rectangle((x0 + 0.06, y + 0.12),
                         (x1 - x0) - 0.12, row_h * 0.66,
                         facecolor=face, edgecolor=edge, lw=1.2, zorder=2))
            ax.text((x0 + x1) / 2, y + row_h * 0.45, vtxt,
                    ha="center", va="center", fontsize=8.2, color=INK, zorder=4)

# annotation band
def annot(x, txt, col="#6b7280"):
    ax.text(x, -0.62, txt, ha="center", va="top", fontsize=7.6,
            color=col, fontstyle="italic")

# find, within the window, the first message beat and first parity beat
first_msg = next((i for i in range(NCYC) if cwval[i] == "1" and ispar[i] != "1"), None)
first_par = next((i for i in range(NCYC) if cwval[i] == "1" and ispar[i] == "1"), None)
last_beat = next((i for i in range(NCYC - 1, -1, -1)
                  if val_at(changes.get("cw_last_o", []), SAMPLE[i]) == "1"), None)
if first_msg is not None:
    annot(first_msg + 0.5, "message symbols\n(systematic passthrough)", BUS_C)
if first_par is not None:
    annot(first_par + 0.5, "2T parity symbols\n(cw_is_parity=1)", PAR_C)
if last_beat is not None:
    annot(last_beat + 0.5, "cw_last + done", "#dc2626")

ax.set_title(
    "rs_encoder — REAL captured VCD (Icarus Verilog): one RS(16,8)/GF(256) codeword "
    "(ramp block), sampled just after each rising clock edge",
    fontsize=11.5, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
