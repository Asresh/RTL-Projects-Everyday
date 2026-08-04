#!/usr/bin/env python3
"""Render a REAL captured waveform from riscv_pipeline.vcd (produced by
`make icarus`). NOT a hand-drawn mock-up: every value is read straight out of
the VCD written by the Icarus Verilog run of tb_riscv_pipeline.

The figure tracks a single window of the program as instructions stream down
the 5-stage pipeline. Each row is a pipeline latch's *PC*, so the same PC
marching one row lower every clock is the instruction advancing
IF -> ID -> EX -> MEM -> WB. The window is auto-centred on the first load-use
interlock so you can watch the hazard unit assert `stall`, freeze the front of
the pipe, and inject a one-cycle bubble (a gap in the diagonal). `redirect`
marks any branch/jump the EX stage resolves taken. The bottom row disassembles
the instruction retiring at WB that cycle.

Usage:  python3 gen_waveform.py [riscv_pipeline.vcd] [docs/riscv_pipeline_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = sys.argv[1] if len(sys.argv) > 1 else "riscv_pipeline.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/riscv_pipeline_waveform.png"


# --------------------------------------------------------------------------- #
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


def as_int(series, t):
    v = val_at(series, t)
    if v in (None, "x") or "x" in v.lower() or "z" in v.lower():
        return None
    return int(v, 2)


def bit(series, t):
    v = val_at(series, t)
    return v == "1"


changes, widths = parse_vcd(VCD)


def find(*cands):
    for c in cands:
        if c in changes:
            return changes[c]
    for c in cands:
        for k in changes:
            if k.endswith("." + c):
                return changes[k]
    return []


clk   = find("dut.clk", "clk")
rst_n = find("dut.rst_n", "rst_n")
stall = find("dut.stall")
redir = find("dut.redirect")
pc_if = find("dut.pc")
pc_id = find("dut.ifid_pc")
pc_ex = find("dut.idex_pc")
pc_mem = find("dut.exmem_pc")
cpc   = find("dut.commit_pc", "commit_pc")
cval  = find("dut.commit_valid", "commit_valid")
cinst = find("dut.commit_instr", "commit_instr")
exv   = find("dut.idex_valid")


# --------------------------------------------------------------------------- #
# minimal RV32I disassembler for the commit-row annotation
REGN = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1",
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "s2", "s3",
        "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]


def sx(v, n):
    return v - (1 << n) if v & (1 << (n - 1)) else v


def disasm(iw):
    if iw is None:
        return "-"
    op = iw & 0x7f
    rd = (iw >> 7) & 0x1f
    f3 = (iw >> 12) & 7
    rs1 = (iw >> 15) & 0x1f
    rs2 = (iw >> 20) & 0x1f
    f7 = (iw >> 25) & 0x7f
    R = lambda i: REGN[i]
    ii = sx((iw >> 20) & 0xfff, 12)
    if iw == 0x13:
        return "nop"
    if op == 0x37:
        return f"lui {R(rd)},0x{(iw>>12)&0xfffff:x}"
    if op == 0x17:
        return f"auipc {R(rd)},0x{(iw>>12)&0xfffff:x}"
    if op == 0x6f:
        return f"jal {R(rd)}"
    if op == 0x67:
        return f"jalr {R(rd)},{R(rs1)}"
    if op == 0x63:
        nm = {0: "beq", 1: "bne", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}.get(f3, "b?")
        return f"{nm} {R(rs1)},{R(rs2)}"
    if op == 0x03:
        nm = {0: "lb", 1: "lh", 2: "lw", 4: "lbu", 5: "lhu"}.get(f3, "l?")
        return f"{nm} {R(rd)},{ii}({R(rs1)})"
    if op == 0x23:
        nm = {0: "sb", 1: "sh", 2: "sw"}.get(f3, "s?")
        return f"{nm} {R(rs2)},({R(rs1)})"
    if op == 0x13:
        nm = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi",
              1: "slli", 5: ("srai" if f7 == 0x20 else "srli")}.get(f3, "?i")
        if f3 in (1, 5):
            return f"{nm} {R(rd)},{R(rs1)},{rs2}"
        return f"{nm} {R(rd)},{R(rs1)},{ii}"
    if op == 0x33:
        if f3 == 0:
            nm = "sub" if f7 == 0x20 else "add"
        elif f3 == 5:
            nm = "sra" if f7 == 0x20 else "srl"
        else:
            nm = {1: "sll", 2: "slt", 3: "sltu", 4: "xor", 6: "or", 7: "and"}.get(f3, "?")
        return f"{nm} {R(rd)},{R(rs1)},{R(rs2)}"
    return f".word {iw:08x}"


# --------------------------------------------------------------------------- #
# sample one point just after each rising clock edge
edges = sorted(t for (t, v) in clk if v == "1")
rel_hi = next((t for (t, v) in rst_n if v == "1"), edges[0])

# locate the first load-use stall to centre the window on
stall_edges = [i for i, e in enumerate(edges) if bit(stall, e + 1)]
first_stall = stall_edges[0] if stall_edges else next(
    (i for i, e in enumerate(edges) if e >= rel_hi), 0) + 6

W0 = max(0, first_stall - 7)
sel = edges[W0:W0 + 21]
smp = [e + 1 for e in sel]
Ncy = len(smp)
xs = list(range(Ncy))

# --------------------------------------------------------------------------- #
BG, INK, GRID = "white", "#1f2937", "#e5e7eb"
CTRL, HAZ, RED, PCC = "#2563eb", "#b45309", "#dc2626", "#0369a1"
STAGE_COL = {"IF": "#0369a1", "ID": "#7c3aed", "EX": "#0f766e",
             "MEM": "#b45309", "WB": "#dc2626"}

rows = [("clk", "clk", None, INK),
        ("rst_n", "bit", rst_n, CTRL),
        ("stall (load-use)", "bit", stall, HAZ),
        ("redirect (branch)", "bit", redir, RED),
        ("IF  : pc", "pc", pc_if, STAGE_COL["IF"]),
        ("ID  : ifid_pc", "pc", pc_id, STAGE_COL["ID"]),
        ("EX  : idex_pc", "pcv", pc_ex, STAGE_COL["EX"]),
        ("MEM : exmem_pc", "pc", pc_mem, STAGE_COL["MEM"]),
        ("WB  : commit_pc", "pcc", cpc, STAGE_COL["WB"])]

fig = plt.figure(figsize=(16.0, 9.0))
ax = fig.add_subplot(111)
ax.set_xlim(-3.0, Ncy - 0.3)
row_h = 1.0
ytop = len(rows) * row_h + 1.0
ax.set_ylim(-1.4, ytop + 0.3)
ax.axis("off")

fig.suptitle("Day 38  5-Stage Pipelined RISC-V RV32I Core "
             "— REAL captured waveform from riscv_pipeline.vcd (Icarus Verilog)",
             fontsize=13, fontweight="bold", color=INK, y=0.975)
ax.text(0.5, 1.045,
        "each row is a pipeline latch's PC — the same PC stepping one row lower "
        "per clock is one instruction flowing IF→ID→EX→MEM→WB; watch the load-use "
        "interlock assert `stall` and punch a bubble into the diagonal",
        transform=ax.transAxes, ha="center", fontsize=9.2, color="#4b5563")

for i in xs:
    ax.plot([i, i], [-0.6, ytop - 0.6], color=GRID, lw=0.8, zorder=0)
    ax.text(i, ytop - 0.5, f"{i}", ha="center", va="bottom", fontsize=7.4, color="#9ca3af")
ax.text(-3.0, ytop - 0.5, "cycle", ha="left", va="bottom", fontsize=7.8, color="#9ca3af")

for r, (name, kind, ser, col) in enumerate(rows):
    yb = ytop - (r + 1) * row_h - 0.6
    yc = yb + row_h / 2
    ax.text(-3.0, yc, name, ha="left", va="center", fontsize=9.2,
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
                             facecolor=col, alpha=0.16, edgecolor="none", zorder=1))
        ax.plot(px, py, color=col, lw=1.9)

    else:  # PC-valued rows drawn as hex cells
        for i, t in zip(xs, smp):
            v = as_int(ser, t)
            if kind == "pcc":                 # WB commit: honour commit_valid
                show = bit(cval, t)
                txt = f"{v & 0xffff:04x}" if (show and v is not None) else "—"
            elif kind == "pcv":               # EX: honour idex_valid (bubble = —)
                show = bit(exv, t)
                txt = f"{v & 0xffff:04x}" if (show and v is not None) else "—"
            else:
                txt = f"{v & 0xffff:04x}" if v is not None else "x"
            bub = (txt == "—")
            fc = "#f3f4f6" if bub else "#ffffff"
            ax.add_patch(plt.Rectangle((i - 0.46, yb + 0.16), 0.92, 0.66,
                         facecolor=fc, edgecolor=(GRID if bub else col),
                         lw=1.1, zorder=2))
            ax.text(i, yc, txt, ha="center", va="center",
                    fontsize=8.0, color=("#9ca3af" if bub else col),
                    zorder=3, family="monospace")

# disassembly of the instruction retiring at WB each cycle
ydis = ytop - len(rows) * row_h - 1.4
ax.text(-3.0, ydis, "WB retires:", ha="left", va="center", fontsize=8.4,
        color=INK, family="monospace")
for i, t in zip(xs, smp):
    if bit(cval, t):
        iw = as_int(cinst, t)
        ax.text(i, ydis, disasm(iw), ha="center", va="center", fontsize=6.6,
                color="#374151", family="monospace", rotation=90)

# annotate the stall column
sc = [i for i, t in zip(xs, smp) if bit(stall, t)]
if sc:
    ax.annotate("load-use interlock:\n`lw` result not ready → 1 bubble",
                xy=(sc[0], ytop - 2 * row_h - 0.6),
                xytext=(sc[0] + 1.5, ytop + 0.0),
                fontsize=8.4, color=HAZ, ha="left",
                arrowprops=dict(arrowstyle="->", color=HAZ, lw=1.4))

ax.text(0.5, -0.12,
        "PCs shown as low-16-bit hex. A blank (—) cell is a pipeline bubble "
        "(idex_valid / commit_valid = 0). Sampled one delta after each rising clk edge; "
        "all values read directly from the VCD.",
        transform=ax.transAxes, ha="center", va="top", fontsize=8.2, color="#6b7280")

plt.tight_layout(rect=(0.02, 0.04, 0.995, 0.92))
fig.savefig(OUT, dpi=140, facecolor=BG)
print("wrote", OUT, "| window start cycle-index", W0, "| first stall at edge", first_stall)
