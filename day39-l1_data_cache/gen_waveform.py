#!/usr/bin/env python3
"""Render a REAL captured waveform from l1_dcache_4way.vcd (written by
`make icarus`). NOT a hand-drawn mock-up: every level and every bus value in
the figure is read straight out of the VCD produced by the Icarus Verilog run
of tb_l1_dcache_4way.

The window is auto-centred on the first *dirty* miss, i.e. the worst-case cache
transaction: a load/store that misses on a set whose LRU victim is dirty, so the
controller has to evict before it can refill. You can watch the whole sequence

    IDLE(miss) -> SEL -> WB_REQ -> WB_DATA x4 -> FILL_REQ -> FILL_DATA x4
                                                          -> ALLOC(ack) -> IDLE

including the memory model's random `mem_wready` backpressure stretching the
writeback beats and its random `mem_rvalid` gaps stretching the refill.

Usage:  python3 gen_waveform.py [l1_dcache_4way.vcd] [docs/l1_dcache_4way_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "l1_dcache_4way.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/l1_dcache_4way_waveform.png"

STATES = {0: "IDLE", 1: "SEL", 2: "WB_REQ", 3: "WB_DATA", 4: "FILL_REQ",
          5: "FILL_DATA", 6: "ALLOC", 7: "FL_SCAN", 8: "FL_NEXT"}
STATE_FC = {"IDLE": "#f8fafc", "SEL": "#ede9fe", "WB_REQ": "#fee2e2",
            "WB_DATA": "#fee2e2", "FILL_REQ": "#dbeafe", "FILL_DATA": "#dbeafe",
            "ALLOC": "#dcfce7", "FL_SCAN": "#f1f5f9", "FL_NEXT": "#f1f5f9"}
STATE_EC = {"IDLE": "#94a3b8", "SEL": "#7c3aed", "WB_REQ": "#dc2626",
            "WB_DATA": "#dc2626", "FILL_REQ": "#2563eb", "FILL_DATA": "#2563eb",
            "ALLOC": "#16a34a", "FL_SCAN": "#64748b", "FL_NEXT": "#64748b"}


# --------------------------------------------------------------------------- #
def parse_vcd(path):
    code2names, changes = {}, {}
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
                    code, name = p[3], p[4].lstrip("\\")
                    path_name = ".".join(scope[1:] + [name]) if len(scope) > 1 else name
                    code2names.setdefault(code, []).append(path_name)
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
    return changes


def val_at(series, t):
    v = "x"
    for (tc, vc) in series:
        if tc <= t:
            v = vc
        else:
            break
    return v


def as_int(series, t):
    v = val_at(series, t)
    if v in (None, "x") or "x" in v.lower() or "z" in v.lower():
        return None
    return int(v, 2)


def bit(series, t):
    return val_at(series, t) == "1"


changes = parse_vcd(VCD)


def find(*cands):
    for c in cands:
        if c in changes:
            return changes[c]
    for c in cands:
        for k in changes:
            if k.endswith("." + c):
                return changes[k]
    return []


clk     = find("dut.clk", "clk")
state   = find("dut.state_q")
cpu_req = find("dut.cpu_req")
cpu_we  = find("dut.cpu_we")
cpu_ad  = find("dut.cpu_addr")
cpu_ack = find("dut.cpu_ack")
cpu_rd  = find("dut.cpu_rdata")
hit     = find("dut.hit")
wrq     = find("dut.mem_wr_req")
wv      = find("dut.mem_wvalid")
wr      = find("dut.mem_wready")
wd      = find("dut.mem_wdata")
rdq     = find("dut.mem_rd_req")
rv      = find("dut.mem_rvalid")
rd      = find("dut.mem_rdata")
maddr   = find("dut.mem_addr")
beat    = find("dut.beat_q")
isfl    = find("dut.wb_is_flush")

# ------------------------------------------------------------------ window
edges = sorted(t for (t, v) in clk if v == "1")

# first *dirty* miss: a writeback request that is an eviction, not a flush
first_wb = next((i for i, e in enumerate(edges)
                 if bit(wrq, e + 1) and not bit(isfl, e + 1)), 12)
W0 = max(0, first_wb - 5)
NCY = 26
sel = edges[W0:W0 + NCY]
smp = [e + 1 for e in sel]
xs = list(range(len(smp)))
NCY = len(smp)

# ------------------------------------------------------------------ styling
BG, INK, GRID, MUT = "white", "#1f2937", "#e5e7eb", "#6b7280"
CPU_C, HIT_C, WB_C, FILL_C, ST_C = "#0369a1", "#16a34a", "#dc2626", "#2563eb", "#7c3aed"

rows = [
    ("clk",              "clk", None,    INK),
    ("cpu_req",          "bit", cpu_req, CPU_C),
    ("cpu_we",           "bit", cpu_we,  CPU_C),
    ("cpu_addr",         "hex", cpu_ad,  CPU_C),
    ("hit  (tag match)", "bit", hit,     HIT_C),
    ("cpu_ack",          "bit", cpu_ack, HIT_C),
    ("cpu_rdata",        "ackd", cpu_rd, HIT_C),
    ("state_q",          "st",  state,   ST_C),
    ("beat_q",           "dec", beat,    MUT),
    ("mem_addr",         "hex", maddr,   MUT),
    ("mem_wr_req",       "bit", wrq,     WB_C),
    ("mem_wvalid",       "bit", wv,      WB_C),
    ("mem_wready",       "bit", wr,      WB_C),
    ("mem_wdata (evict)", "wbd", wd,     WB_C),
    ("mem_rd_req",       "bit", rdq,     FILL_C),
    ("mem_rvalid",       "bit", rv,      FILL_C),
    ("mem_rdata (refill)", "rvd", rd,    FILL_C),
]

ROW_H = 1.0
LBL_X = -6.2
fig = plt.figure(figsize=(17.5, 11.2))
ax = fig.add_subplot(111)
ax.set_xlim(LBL_X - 0.4, NCY - 0.3)
ytop = len(rows) * ROW_H + 1.0
ax.set_ylim(-0.9, ytop + 0.5)
ax.axis("off")

fig.suptitle("Day 39  4-Way Set-Associative Write-Back L1 D-Cache "
             "— REAL captured waveform from l1_dcache_4way.vcd (Icarus Verilog)",
             fontsize=13.5, fontweight="bold", color=INK, y=0.978)
ax.text(0.5, 1.038,
        "one worst-case DIRTY MISS: evict the LRU victim (4 beats out) then "
        "refill the requested line (4 beats in), then ALLOC answers the CPU",
        transform=ax.transAxes, ha="center", fontsize=9.6, color="#4b5563")

# cycle grid + numbering
for i in xs:
    ax.plot([i, i], [-0.35, ytop - 0.6], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop - 0.5, f"{W0 + i}", ha="center", va="bottom",
            fontsize=7.0, color="#9ca3af")
ax.text(LBL_X, ytop - 0.5, "cycle", ha="left", va="bottom", fontsize=7.8, color="#9ca3af")

for r, (name, kind, ser, col) in enumerate(rows):
    yb = ytop - (r + 1) * ROW_H - 0.6
    yc = yb + ROW_H / 2
    ax.text(LBL_X, yc, name, ha="left", va="center", fontsize=9.4,
            color=col, family="monospace")
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
            hi = bit(ser, t)
            lvl = yb + (0.8 if hi else 0.15)
            if prev is not None and prev != lvl:
                px += [i - 0.5, i - 0.5]; py += [prev, lvl]
            px += [i - 0.5, i + 0.5]; py += [lvl, lvl]
            prev = lvl
            if hi:
                ax.add_patch(plt.Rectangle((i - 0.5, yb + 0.12), 1.0, 0.72,
                             facecolor=col, alpha=0.15, edgecolor="none", zorder=1))
        ax.plot(px, py, color=col, lw=1.9)

    elif kind == "st":
        for i, t in zip(xs, smp):
            v = as_int(ser, t)
            nm = STATES.get(v, "?")
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.14), 0.94, 0.70,
                         facecolor=STATE_FC.get(nm, "white"),
                         edgecolor=STATE_EC.get(nm, GRID), lw=1.3, zorder=2))
            ax.text(i, yc, nm, ha="center", va="center", fontsize=6.4,
                    color=STATE_EC.get(nm, INK), rotation=90, zorder=3,
                    family="monospace", fontweight="bold")

    else:   # bus-valued rows drawn as cells, gated by their qualifier
        for i, t in zip(xs, smp):
            v = as_int(ser, t)
            if kind == "hex":                          # byte addresses: 5 nibbles
                txt = f"{v & 0xFFFFF:05x}" if v is not None else "x"
                show = True
            elif kind == "dec":
                txt = f"{v}" if v is not None else "x"
                show = True
            elif kind == "ackd":                      # only meaningful with ack
                show = bit(cpu_ack, t)
                txt = f"{v:08x}" if (show and v is not None) else "—"
            elif kind == "wbd":                       # only when wvalid&wready
                show = bit(wv, t) and bit(wr, t)
                txt = f"{v:08x}" if (show and v is not None) else "—"
            else:                                     # rvd: only when rvalid
                show = bit(rv, t)
                txt = f"{v:08x}" if (show and v is not None) else "—"
            idle = (txt == "—")
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.16), 0.94, 0.66,
                         facecolor=("#f8fafc" if idle else "white"),
                         edgecolor=(GRID if idle else col), lw=1.1, zorder=2))
            ax.text(i, yc, txt, ha="center", va="center",
                    fontsize=6.3 if not idle else 8.0,
                    color=("#cbd5e1" if idle else col), zorder=3,
                    family="monospace", rotation=90 if not idle else 0)

# ------------------------------------------------------------- phase bands
# Group the captured states into transaction phases and draw them as a labelled
# band above the cycle numbers -- clearer than crossing arrows.
PHASE = {0: ("lookup", "#94a3b8"), 1: ("victim select", ST_C),
         2: ("evict dirty victim -> memory", WB_C),
         3: ("evict dirty victim -> memory", WB_C),
         4: ("refill requested line <- memory", FILL_C),
         5: ("refill requested line <- memory", FILL_C),
         6: ("alloc + ack", "#16a34a"),
         7: ("flush walk", "#64748b"), 8: ("flush walk", "#64748b")}

band_y = ytop - 0.10
runs = []
for i, t in zip(xs, smp):
    ph = PHASE.get(as_int(state, t), ("?", MUT))
    if runs and runs[-1][0] == ph[0]:
        runs[-1][2] = i
    else:
        runs.append([ph[0], i, i, ph[1]])

for nm, i0, i1, col in runs:
    if nm == "lookup":
        continue
    ax.add_patch(plt.Rectangle((i0 - 0.5, band_y), (i1 - i0) + 1.0, 0.46,
                 facecolor=col, alpha=0.16, edgecolor=col, lw=1.0, zorder=2))
    if (i1 - i0) >= 1:
        ax.text((i0 + i1) / 2.0, band_y + 0.23, nm, ha="center", va="center",
                fontsize=7.4, color=col, family="monospace", fontweight="bold",
                zorder=3)
ax.text(LBL_X, band_y + 0.23, "transaction phase", ha="left", va="center",
        fontsize=8.0, color=INK, family="monospace")

ax.text(0.5, -0.03,
        "Buses are shown only where their qualifier is asserted (cpu_rdata with cpu_ack,\n"
        "mem_wdata with wvalid & wready, mem_rdata with rvalid); '—' means don't-care.\n"
        "mem_wready drops mid-burst and rvalid has gaps — the testbench memory model applies\n"
        "random backpressure and latency, and beat_q only advances on an accepted beat.\n"
        "Sampled one delta after each rising clk edge; every value read directly from the VCD.",
        transform=ax.transAxes, ha="center", va="top", fontsize=8.6, color=MUT,
        linespacing=1.5)

plt.tight_layout(rect=(0.02, 0.05, 0.995, 0.93))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT, "| window starts at cycle", W0, "| first dirty-miss edge", first_wb)
