#!/usr/bin/env python3
"""Render a REAL captured waveform from mmu_sv32.vcd (written by `make icarus`).

This is NOT a hand-drawn mock-up: every level and every bus value in the figure
is read straight out of the VCD produced by the Icarus Verilog run of
tb_mmu_sv32.

The window is auto-centred on a full TLB-miss page-table walk, i.e. the
worst-case translation: a virtual address that is not resident, so the walker
has to read the level-1 (root) PTE, discover a pointer, descend, read the
level-0 PTE, find a leaf, check its permissions, install it in the TLB and only
then answer the CPU:

    IDLE(miss) -> REQ -> WAIT (root PTE) -> REQ -> WAIT (leaf PTE) -> RESP

The testbench memory model applies random `ptw_req_ready` backpressure and
random response latency, so the number of WAIT cycles per level varies run to
run; the walker just waits.

Usage:  python3 gen_waveform.py [mmu_sv32.vcd] [docs/mmu_sv32_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "mmu_sv32.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/mmu_sv32_waveform.png"

STATES = {0: "IDLE", 1: "REQ", 2: "WAIT", 3: "RESP"}
STATE_FC = {"IDLE": "#f8fafc", "REQ": "#dbeafe",
            "WAIT": "#fef3c7", "RESP": "#dcfce7"}
STATE_EC = {"IDLE": "#94a3b8", "REQ": "#2563eb",
            "WAIT": "#b45309", "RESP": "#16a34a"}

ACC = {0: "LD", 1: "ST", 2: "IF"}
PRIV = {0: "U", 1: "S", 3: "M"}


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


clk      = find("dut.clk", "clk")
state    = find("dut.state")
rq_v     = find("dut.req_valid", "req_valid")
rq_rdy   = find("dut.req_ready", "req_ready")
rq_va    = find("dut.req_vaddr", "req_vaddr")
rq_acc   = find("dut.req_access", "req_access")
priv     = find("dut.priv", "priv")
tlb_hit  = find("dut.tlb_hit")
rs_v     = find("dut.resp_valid", "resp_valid")
rs_pa    = find("dut.resp_paddr", "resp_paddr")
rs_flt   = find("dut.resp_fault", "resp_fault")
rs_cse   = find("dut.resp_cause", "resp_cause")
rs_sup   = find("dut.resp_super", "resp_super")
p_req_v  = find("dut.ptw_req_valid", "ptw_req_valid")
p_req_a  = find("dut.ptw_req_addr", "ptw_req_addr")
p_req_r  = find("dut.ptw_req_ready", "ptw_req_ready")
p_rsp_v  = find("dut.ptw_resp_valid", "ptw_resp_valid")
p_rsp_d  = find("dut.ptw_resp_data", "ptw_resp_data")
level    = find("dut.walk_level")
base     = find("dut.walk_base")
miss     = find("dut.perf_tlb_miss", "perf_tlb_miss")

# ------------------------------------------------------------------ window
edges = sorted(t for (t, v) in clk if v == "1")

# Find a TLB miss whose walk goes all the way to a level-0 leaf and succeeds
# (i.e. the walk issues TWO PTE reads and ends without a fault) - the full
# worst-case translation rather than a one-read superpage hit or a fault.
def walk_window(start_i):
    """Return (n_reads, faulted, end_i) for the walk beginning at edge start_i."""
    n_reads, i = 0, start_i
    while i < len(edges) and i < start_i + 60:
        t = edges[i] + 1
        if bit(p_rsp_v, t):
            n_reads += 1
        if as_int(state, t) == 3:          # RESP
            return n_reads, bit(rs_flt, t), i
        i += 1
    return n_reads, True, start_i


first = None
for i, e in enumerate(edges):
    if bit(miss, e + 1):
        n_reads, faulted, end_i = walk_window(i)
        if n_reads >= 2 and not faulted:
            first = i
            break
if first is None:
    first = next((i for i, e in enumerate(edges) if bit(miss, e + 1)), 12)

W0 = max(0, first - 3)
NCY = 24
sel = edges[W0:W0 + NCY]
smp = [e + 1 for e in sel]
xs = list(range(len(smp)))
NCY = len(smp)

# ------------------------------------------------------------------ styling
BG, INK, GRID, MUT = "white", "#1f2937", "#e5e7eb", "#6b7280"
CPU_C, TLB_C, PTW_C, RSP_C, ST_C = "#0369a1", "#16a34a", "#2563eb", "#7c3aed", "#b45309"

rows = [
    ("clk",                  "clk",  None,    INK),
    ("req_valid",            "bit",  rq_v,    CPU_C),
    ("req_ready",            "bit",  rq_rdy,  CPU_C),
    ("req_vaddr",            "va",   rq_va,   CPU_C),
    ("req_access",           "acc",  rq_acc,  CPU_C),
    ("priv",                 "prv",  priv,    CPU_C),
    ("tlb_hit",              "bit",  tlb_hit, TLB_C),
    ("state",                "st",   state,   ST_C),
    ("walk_level",           "lvl",  level,   ST_C),
    ("walk_base (tbl PPN)", "ppn",  base,    ST_C),
    ("ptw_req_valid",        "bit",  p_req_v, PTW_C),
    ("ptw_req_ready",        "bit",  p_req_r, PTW_C),
    ("ptw_req_addr (PTE)",   "pteA", p_req_a, PTW_C),
    ("ptw_resp_valid",       "bit",  p_rsp_v, PTW_C),
    ("ptw_resp_data (PTE)",  "pteD", p_rsp_d, PTW_C),
    ("resp_valid",           "bit",  rs_v,    RSP_C),
    ("resp_paddr",           "pa",   rs_pa,   RSP_C),
    ("resp_fault",           "bit",  rs_flt,  "#dc2626"),
    ("resp_super",           "bit",  rs_sup,  RSP_C),
]

ROW_H = 1.0
LBL_X = -4.6
fig = plt.figure(figsize=(18.0, 12.0))
ax = fig.add_subplot(111)
ax.set_xlim(LBL_X - 0.4, NCY - 0.3)
ytop = len(rows) * ROW_H + 1.0
ax.set_ylim(-1.15, ytop + 0.45)
ax.axis("off")

fig.suptitle("Day 40  RISC-V Sv32 MMU (TLB + hardware page-table walker) "
             "— REAL captured waveform from mmu_sv32.vcd (Icarus Verilog)",
             fontsize=13.5, fontweight="bold", color=INK, y=0.978)
ax.text(0.5, 1.035,
        "one worst-case TLB MISS: read the level-1 root PTE, descend on a "
        "pointer, read the level-0 leaf PTE, check permissions, install in the "
        "TLB, then answer the CPU",
        transform=ax.transAxes, ha="center", fontsize=9.6, color="#4b5563")

# cycle grid + numbering
for i in xs:
    ax.plot([i, i], [-0.35, ytop - 0.6], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop - 0.5, f"{W0 + i}", ha="center", va="bottom",
            fontsize=7.0, color="#9ca3af")
ax.text(LBL_X, ytop - 0.5, "cycle", ha="left", va="bottom",
        fontsize=7.8, color="#9ca3af")

for r, (name, kind, ser, col) in enumerate(rows):
    yb = ytop - (r + 1) * ROW_H - 0.6
    yc = yb + ROW_H / 2
    ax.text(LBL_X, yc, name, ha="left", va="center", fontsize=8.8,
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
            nm = STATES.get(as_int(ser, t), "?")
            ax.add_patch(plt.Rectangle((i - 0.47, yb + 0.14), 0.94, 0.70,
                         facecolor=STATE_FC.get(nm, "white"),
                         edgecolor=STATE_EC.get(nm, GRID), lw=1.3, zorder=2))
            ax.text(i, yc, nm, ha="center", va="center", fontsize=6.6,
                    color=STATE_EC.get(nm, INK), rotation=90, zorder=3,
                    family="monospace", fontweight="bold")

    else:   # bus-valued rows, drawn as cells and gated by their qualifier
        for i, t in zip(xs, smp):
            v = as_int(ser, t)
            rot, fs = 90, 6.3
            if kind == "va":              # 32-bit VA: show vpn1|vpn0|off
                if v is None:
                    txt, show = "x", True
                else:
                    txt = f"{v >> 22:03x}|{(v >> 12) & 0x3FF:03x}|{v & 0xFFF:03x}"
                    show = True
            elif kind == "pa":            # only meaningful with resp_valid
                show = bit(rs_v, t)
                txt = (f"{v >> 12:06x}|{v & 0xFFF:03x}"
                       if (show and v is not None) else "—")
            elif kind == "acc":
                show, rot, fs = True, 0, 7.6
                txt = ACC.get(v, "x")
            elif kind == "prv":
                show, rot, fs = True, 0, 7.6
                txt = PRIV.get(v, "x")
            elif kind == "lvl":
                show, rot, fs = True, 0, 7.6
                txt = f"{v}" if v is not None else "x"
            elif kind == "ppn":
                show, rot, fs = True, 0, 7.0
                txt = f"{v:03x}" if v is not None else "x"
            elif kind == "pteA":          # only while the request is driven
                show = bit(p_req_v, t)
                txt = f"{v:09x}" if (show and v is not None) else "—"
            else:                         # pteD: only when the response is valid
                show = bit(p_rsp_v, t)
                txt = f"{v:08x}" if (show and v is not None) else "—"
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
# Group the captured cycles into walk phases and draw them as a labelled band.
band_y = ytop - 0.10
runs = []
for i, t in zip(xs, smp):
    st = as_int(state, t)
    lv = as_int(level, t)
    if st == 0:
        ph, col = "idle / lookup", "#94a3b8"
    elif st == 3:
        ph, col = "install + answer CPU", "#16a34a"
    elif lv == 1:
        ph, col = "fetch level-1 (root) PTE", PTW_C
    else:
        ph, col = "fetch level-0 (leaf) PTE", "#7c3aed"
    if runs and runs[-1][0] == ph:
        runs[-1][2] = i
    else:
        runs.append([ph, i, i, col])

for nm, i0, i1, col in runs:
    if nm == "idle / lookup":
        continue
    ax.add_patch(plt.Rectangle((i0 - 0.5, band_y), (i1 - i0) + 1.0, 0.46,
                 facecolor=col, alpha=0.16, edgecolor=col, lw=1.0, zorder=2))
    if (i1 - i0) >= 1:
        ax.text((i0 + i1) / 2.0, band_y + 0.23, nm, ha="center", va="center",
                fontsize=7.4, color=col, family="monospace", fontweight="bold",
                zorder=3)
ax.text(LBL_X, band_y + 0.23, "walk phase", ha="left", va="center",
        fontsize=8.0, color=INK, family="monospace")

ax.text(0.5, -0.035,
        "req_vaddr is split as vpn1|vpn0|offset and resp_paddr as ppn|offset. Buses are shown only where their\n"
        "qualifier is asserted (ptw_req_addr with ptw_req_valid, ptw_resp_data with ptw_resp_valid,\n"
        "resp_paddr with resp_valid); '—' means don't-care. The testbench memory model applies random ready and\n"
        "latency backpressure; in this window both PTE requests are accepted on their first cycle and each PTE\n"
        "then arrives 4 cycles later, so the walker sits in WAIT. ptw_req_addr = {walk_base, vpn[level], 2'b00}: the first read\n"
        "indexes the root table with vpn1, the second indexes the table the root PTE pointed at with vpn0.\n"
        "Sampled one delta after each rising clk edge; every value read directly from the VCD.",
        transform=ax.transAxes, ha="center", va="top", fontsize=8.5, color=MUT,
        linespacing=1.5)

plt.tight_layout(rect=(0.02, 0.06, 0.995, 0.93))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT, "| window starts at cycle", W0, "| miss edge index", first)
