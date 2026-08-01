#!/usr/bin/env python3
"""Render a REAL captured waveform from strat_trigger.vcd (produced by
`make icarus`).

Not a hand-drawn mock-up: this parses the VCD written by the Icarus Verilog run
of tb_strat_trigger and plots the directed corner-case sequence -- reset, a BUY
rule firing when the ask crosses its limit, the one-shot arm-clear suppressing a
refire, a SELL rule firing when the bid rises to its limit, and a fire that loads
the cooldown counter which then BLOCKS several marketable ticks before the engine
is free to fire again -- sampling each signal just after every rising clock edge
(where the registered outputs are valid). Every level and value shown is read
straight from the VCD.

Usage:  python3 gen_waveform.py [strat_trigger.vcd] [docs/strat_trigger_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "strat_trigger.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/strat_trigger_waveform.png"


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

# rising clock edges
clk = changes.get("clk", [])
edges = [t for (t, v) in clk if v == "1"]
# directed sequence: reset + Directed-1 (BUY fire/one-shot) + Directed-2 (SELL)
# + Directed-3 (cooldown block/fire) = first ~15 cycles before the soak.
NCYC = 15
edges = edges[:NCYC]
SAMPLE = [e + 1 for e in edges]  # sample just after each posedge

# ---- signals to show (name, label, kind) -----------------------------------
ROWS = [
    ("rst",              "rst",             "bit"),
    ("bbo_valid_i",      "bbo_valid",       "bit"),
    ("best_bid_i",       "best_bid",        "bus"),
    ("best_ask_i",       "best_ask",        "bus"),
    ("cfg_we_i",         "cfg_we",          "bit"),
    ("armed_cnt_o",      "armed_cnt",       "bus"),
    ("fire_o",           "fire",            "bit"),
    ("fire_idx_o",       "fire_idx",        "bus"),
    ("order_side_o",     "order_side(0=B)", "bit"),
    ("order_px_o",       "order_px",        "bus"),
    ("order_qty_o",      "order_qty",       "bus"),
    ("blocked_o",        "blocked",         "bit"),
    ("cooldown_active_o","cooldown",        "bit"),
    ("inflight_o",       "inflight",        "bus"),
]

BIT_C = "#2563eb"
BUS_C = "#0f766e"
INK   = "#1f2937"
GRID  = "#e5e7eb"

n = len(ROWS)
fig, ax = plt.subplots(figsize=(15.5, 8.8))
row_h = 1.0
gap = 0.32

ax.set_xlim(-3.6, NCYC)
ax.set_ylim(-0.7, n * (row_h + gap))
ax.axis("off")

for c in range(NCYC + 1):
    ax.plot([c, c], [-0.4, n * (row_h + gap) - gap + 0.1],
            color=GRID, lw=0.8, zorder=0)
for c in range(NCYC):
    ax.text(c + 0.5, n * (row_h + gap) - gap + 0.4, str(c),
            ha="center", va="bottom", fontsize=7.5, color="#9ca3af")
ax.text(-3.5, n * (row_h + gap) - gap + 0.4, "cycle:",
        ha="left", va="bottom", fontsize=8, color="#9ca3af", fontstyle="italic")

for ri, (sig, label, kind) in enumerate(ROWS):
    y = (n - 1 - ri) * (row_h + gap)
    ax.text(-3.5, y + row_h / 2, label, ha="left", va="center",
            fontsize=8.8, color=INK)
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
        vals = [to_int(val_at(series, ts)) for ts in SAMPLE]
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
                    ha="center", va="center", fontsize=8.0, color=INK, zorder=4)
            i = j + 1

# annotation band (aligned to the directed step sequence)
ann = [
    (0.5,  "reset"),
    (1.5,  "arm rule0 BUY lim1000"),
    (2.5,  "ask 1005>lim: no fire"),
    (3.5,  "ask==lim: BUY FIRE"),
    (4.5,  "one-shot: no refire"),
    (7.5,  "bid==lim: SELL FIRE"),
    (9.5,  "FIRE -> load cooldown=3"),
    (11.7, "marketable but BLOCKED"),
    (14.5, "cooldown done: FIRE"),
]
for x, txt in ann:
    ax.text(x, -0.55, txt, ha="center", va="top", fontsize=7.2,
            color="#6b7280", fontstyle="italic", rotation=0)

ax.set_title(
    "strat_trigger — REAL captured VCD (Icarus Verilog), sampled just after each rising clock edge",
    fontsize=12, color=INK, pad=14)

fig.tight_layout()
fig.savefig(OUT, dpi=140, bbox_inches="tight")
print("wrote", OUT)
