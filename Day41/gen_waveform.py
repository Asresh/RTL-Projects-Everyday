#!/usr/bin/env python3
"""Render a REAL captured waveform from ooo_tomasulo.vcd (written by `make icarus`).

This is NOT a hand-drawn mock-up: every level and every bus value in the figure
is read straight out of the VCD produced by the Icarus Verilog run of
tb_ooo_tomasulo.

The window is auto-centred on the moment the machine's whole point becomes
visible: a 33-cycle divide is sitting at the head of the reorder buffer, the
younger 1-cycle ALU and 3-cycle MUL instructions behind it have long since
executed and are parked in the ROB with their done bits set (dbg_rob_done fills
in from the *back*, out of program order), and nothing can retire.  The divide
finally wins the Common Data Bus, and the ROB drains in one long burst of
strictly in-order commits while dispatch refills it from the other end.

    execute out of order   ->   retire in order

Usage:  python3 gen_waveform.py [ooo_tomasulo.vcd] [docs/ooo_tomasulo_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "ooo_tomasulo.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/ooo_tomasulo_waveform.png"

OPN = ["ADD", "SUB", "AND", "OR", "XOR", "SLL", "SRL", "SLT",
       "MUL", "MULH", "DIV", "REM"]
UNIT = {0: "ALU", 1: "MUL", 2: "DIV", 3: "--"}
UNIT_FC = {"ALU": "#dbeafe", "MUL": "#ede9fe", "DIV": "#fee2e2", "--": "#f8fafc"}
UNIT_EC = {"ALU": "#2563eb", "MUL": "#7c3aed", "DIV": "#dc2626", "--": "#cbd5e1"}


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


def as_bits(series, t, width):
    v = val_at(series, t)
    if v in (None, "x") or "x" in v.lower() or "z" in v.lower():
        return None
    return v.rjust(width, v[0] if v[0] in "01" else "0")


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


clk       = find("clk")
d_val     = find("dut.disp_valid", "disp_valid")
d_rdy     = find("dut.disp_ready", "disp_ready")
d_op      = find("dut.disp_op", "disp_op")
d_rd      = find("dut.disp_rd", "disp_rd")
rob_tail  = find("dut.rob_tail")
rob_head  = find("dut.rob_head")
rob_cnt   = find("dut.rob_count")
rob_done  = find("dut.dbg_rob_done", "dbg_rob_done")
rob_busy  = find("dut.dbg_rob_busy", "dbg_rob_busy")
rs_busy   = find("dut.dbg_rs_busy", "dbg_rs_busy")
f_alu     = find("dut.fire_alu")
f_mul     = find("dut.fire_mul")
f_div     = find("dut.fire_div")
div_run   = find("dut.div_run")
cdb_v     = find("dut.cdb_valid")
cdb_sel   = find("dut.cdb_sel")
cdb_tag   = find("dut.cdb_tag")
cdb_val   = find("dut.cdb_val")
cdb_ooo   = find("dut.cdb_is_ooo")
c_val     = find("dut.commit_valid", "commit_valid")
c_tag     = find("dut.commit_tag", "commit_tag")
c_rd      = find("dut.commit_rd", "commit_rd")
c_v       = find("dut.commit_val", "commit_val")

ROB_D = len(as_bits(rob_done, 0, 8) or "00000000")
RS_D  = len(as_bits(rs_busy, 0, 6) or "000000")

# ------------------------------------------------------------------ window
edges = sorted(t for (t, v) in clk if v == "1")

# Find the divide that retires the deepest backlog: the cycle where the DIV
# unit wins the CDB (cdb_sel == 2) after the longest run of blocked cycles,
# and where the ROB is at its fullest.
best, best_score = None, -1
for i, e in enumerate(edges):
    t = e + 1
    if not (bit(cdb_v, t) and as_int(cdb_sel, t) == 2):
        continue
    cnt = as_int(rob_cnt, t) or 0
    done = as_bits(rob_done, t, ROB_D)
    ndone = done.count("1") if done else 0
    # how many cycles has the head been stalled with completed work behind it?
    stalled = 0
    for k in range(1, 25):
        if i - k < 0:
            break
        if bit(c_val, edges[i - k] + 1):
            break
        stalled += 1
    score = ndone * 4 + cnt * 2 + stalled
    if score > best_score:
        best_score, best = score, i

first = best if best is not None else 40
W0 = max(0, first - 7)
NCY = 27
sel = edges[W0:W0 + NCY]
smp = [e + 1 for e in sel]
xs = list(range(len(smp)))
NCY = len(smp)

# ------------------------------------------------------------------ styling
BG, INK, GRID, MUT = "white", "#1f2937", "#e5e7eb", "#6b7280"
DIS_C, ROB_C, ISS_C, CDB_C, CMT_C = "#0369a1", "#b45309", "#7c3aed", "#dc2626", "#16a34a"

rows = [
    ("clk",                    "clk",  None,     INK),
    ("disp_valid",             "bit",  d_val,    DIS_C),
    ("disp_ready",             "bit",  d_rdy,    DIS_C),
    ("disp_op",                "op",   d_op,     DIS_C),
    ("disp_rd",                "reg",  d_rd,     DIS_C),
    ("rob_tail (alloc tag)",   "dec",  rob_tail, DIS_C),
    ("fire_alu",               "bit",  f_alu,    ISS_C),
    ("fire_mul",               "bit",  f_mul,    ISS_C),
    ("fire_div",               "bit",  f_div,    ISS_C),
    ("div_run (33-cyc)",       "bit",  div_run,  "#dc2626"),
    ("dbg_rs_busy",            "map",  rs_busy,  ISS_C),
    ("cdb_valid",              "bit",  cdb_v,    CDB_C),
    ("cdb unit",               "unit", cdb_sel,  CDB_C),
    ("cdb_tag",                "dec",  cdb_tag,  CDB_C),
    ("cdb_val",                "hex",  cdb_val,  CDB_C),
    ("cdb_is_ooo",             "bit",  cdb_ooo,  "#ea580c"),
    ("dbg_rob_busy",           "map",  rob_busy, ROB_C),
    ("dbg_rob_done",           "map",  rob_done, ROB_C),
    ("rob_head (retire tag)",  "dec",  rob_head, CMT_C),
    ("rob_count",              "dec",  rob_cnt,  ROB_C),
    ("commit_valid",           "bit",  c_val,    CMT_C),
    ("commit_tag",             "dec",  c_tag,    CMT_C),
    ("commit_rd",              "reg",  c_rd,     CMT_C),
    ("commit_val",             "hex",  c_v,      CMT_C),
]

ROW_H = 1.0
LBL_X = -5.4
fig = plt.figure(figsize=(19.0, 13.0))
ax = fig.add_subplot(111)
ax.set_xlim(LBL_X - 0.4, NCY - 0.3)
ytop = len(rows) * ROW_H + 1.0
ax.set_ylim(-1.35, ytop + 0.45)
ax.axis("off")

fig.suptitle("Day 41  Out-of-Order Tomasulo Engine (rename + reservation stations + ROB) "
             "— REAL captured waveform from ooo_tomasulo.vcd (Icarus Verilog)",
             fontsize=13.5, fontweight="bold", color=INK, y=0.982)
ax.text(0.5, 1.030,
        "a 33-cycle DIV blocks the ROB head while younger ALU/MUL work finishes "
        "behind it (dbg_rob_done fills out of program order) — then the DIV wins "
        "the CDB and the ROB drains in strict program order",
        transform=ax.transAxes, ha="center", fontsize=9.6, color="#4b5563")

for i in xs:
    ax.plot([i, i], [-0.35, ytop - 0.6], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop - 0.5, f"{W0 + i}", ha="center", va="bottom",
            fontsize=7.0, color="#9ca3af")
ax.text(LBL_X, ytop - 0.5, "cycle", ha="left", va="bottom",
        fontsize=7.8, color="#9ca3af")

for r, (name, kind, ser, col) in enumerate(rows):
    yb = ytop - (r + 1) * ROW_H - 0.6
    yc = yb + ROW_H / 2
    ax.text(LBL_X, yc, name, ha="left", va="center", fontsize=8.6,
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

    elif kind == "unit":
        for i, t in zip(xs, smp):
            nm = UNIT.get(as_int(ser, t), "--")
            if not bit(cdb_v, t):
                nm = "--"
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.14), 0.94, 0.70,
                         facecolor=UNIT_FC[nm], edgecolor=UNIT_EC[nm],
                         lw=1.3, zorder=2))
            ax.text(i, yc, nm, ha="center", va="center", fontsize=7.0,
                    color=UNIT_EC[nm], zorder=3, family="monospace",
                    fontweight="bold")

    elif kind == "map":
        # one little cell per ROB / RS entry, MSB left = highest index
        n = ROB_D if ser is rob_done or ser is rob_busy else RS_D
        for i, t in zip(xs, smp):
            b = as_bits(ser, t, n)
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.16), 0.94, 0.66,
                         facecolor="white", edgecolor=GRID, lw=0.8, zorder=2))
            if b is None:
                continue
            cw = 0.94 / n
            for k, ch in enumerate(b[::-1]):      # k = entry index, 0 on the left
                ax.add_patch(plt.Rectangle((i - 0.47 + k * cw + 0.006, yb + 0.18),
                             cw - 0.012, 0.62,
                             facecolor=(col if ch == "1" else "#eef2f7"),
                             edgecolor="white", lw=0.5, zorder=3))

    else:   # bus-valued rows, gated by their qualifier
        for i, t in zip(xs, smp):
            v = as_int(ser, t)
            fs, rot = 7.4, 0
            if kind == "op":
                show = bit(d_val, t)
                txt = (OPN[v] if (v is not None and v < len(OPN)) else "x") if show else "—"
                fs = 6.6
            elif kind == "reg":
                if ser is d_rd:
                    show = bit(d_val, t)
                else:
                    show = bit(c_val, t)
                txt = f"r{v}" if (show and v is not None) else "—"
            elif kind == "hex":
                show = bit(cdb_v, t) if ser is cdb_val else bit(c_val, t)
                txt = f"{v:08x}" if (show and v is not None) else "—"
                fs, rot = 6.2, 90
            else:   # dec
                if ser is cdb_tag:
                    show = bit(cdb_v, t)
                elif ser is c_tag:
                    show = bit(c_val, t)
                else:
                    show = True
                txt = f"{v}" if (show and v is not None) else "—"
            idle = (txt == "—")
            if idle:
                rot, fs = 0, 8.0
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.16), 0.94, 0.66,
                         facecolor=("#f8fafc" if idle else "white"),
                         edgecolor=(GRID if idle else col), lw=1.1, zorder=2))
            ax.text(i, yc, txt, ha="center", va="center", fontsize=fs,
                    color=("#cbd5e1" if idle else col), zorder=3,
                    family="monospace", rotation=rot)

# ------------------------------------------------------------- phase bands
band_y = ytop - 0.10
runs = []
for i, t in zip(xs, smp):
    if bit(c_val, t):
        ph, col = "in-order retire burst", CMT_C
    elif bit(div_run, t):
        ph, col = "ROB head blocked on DIV", "#dc2626"
    else:
        ph, col = "refill", DIS_C
    if runs and runs[-1][0] == ph:
        runs[-1][2] = i
    else:
        runs.append([ph, i, i, col])

for nm, i0, i1, col in runs:
    ax.add_patch(plt.Rectangle((i0 - 0.5, band_y), (i1 - i0) + 1.0, 0.46,
                 facecolor=col, alpha=0.16, edgecolor=col, lw=1.0, zorder=2))
    if (i1 - i0) >= 1:
        ax.text((i0 + i1) / 2.0, band_y + 0.23, nm, ha="center", va="center",
                fontsize=7.2, color=col, family="monospace", fontweight="bold",
                zorder=3)
ax.text(LBL_X, band_y + 0.23, "machine phase", ha="left", va="center",
        fontsize=8.0, color=INK, family="monospace")

ax.text(0.5, -0.030,
        "dbg_rob_busy / dbg_rob_done / dbg_rs_busy are drawn as one cell per entry, index 0 on the LEFT; a filled cell means the bit is set.\n"
        "Watch dbg_rob_done: bits light up away from rob_head, i.e. younger instructions finish first — that is out-of-order execution. cdb_is_ooo is the\n"
        "design's own detector for exactly that (a result broadcast while an older entry is still unfinished). Nothing retires until the entry AT rob_head is\n"
        "done, so when the DIV finally wins the bus the whole backlog retires one entry per cycle with commit_tag strictly incrementing — in-order retirement.\n"
        "Buses are shown only where their qualifier is asserted (disp_op/disp_rd with disp_valid, cdb_* with cdb_valid, commit_* with commit_valid); '—' is don't-care.\n"
        "Sampled one delta after each rising clk edge; every value read directly from the VCD.",
        transform=ax.transAxes, ha="center", va="top", fontsize=8.4, color=MUT,
        linespacing=1.5)

plt.tight_layout(rect=(0.02, 0.06, 0.995, 0.935))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT, "| window starts at cycle", W0, "| DIV completion at edge", first)
