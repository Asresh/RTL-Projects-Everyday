#!/usr/bin/env python3
"""Render the ooo_tomasulo circuit / datapath diagram to docs/ooo_tomasulo_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, NOT a simulator
capture): the in-order dispatch port, the register alias table and the
architectural register file, the four-way priority operand-resolution mux that
picks between the ARF, a finished ROB entry, a same-cycle Common-Data-Bus
bypass and "wait on a tag", the unified reservation-station pool with its
per-entry tag comparators, the age-based oldest-ready select per functional
unit, the three functional units (1-cycle ALU, pipelined multiplier, iterative
restoring divider), the rotating-priority arbiter that hands out the single
Common Data Bus, and the reorder buffer that turns all of that back into
strictly in-order architectural state.  Insets give the opcode/unit/latency
map, the operand-resolution and wakeup equations, and which hazard each piece
of the machine exists to solve.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

DIS_C = "#0369a1"   # dispatch / front end
RAT_C = "#0f766e"   # rename state
ARF_C = "#166534"   # architectural state
RS_C  = "#7c3aed"   # reservation stations
SEL_C = "#b45309"   # wakeup / select
ALU_C = "#2563eb"   # ALU
MUL_C = "#9333ea"   # multiplier
DIV_C = "#dc2626"   # divider
CDB_C = "#be185d"   # common data bus
ROB_C = "#4338ca"   # reorder buffer
CMT_C = "#16a34a"   # commit
FLS_C = "#ea580c"   # flush
INK   = "#1f2937"
MUT   = "#6b7280"
GRID  = "#e5e7eb"

fig, ax = plt.subplots(figsize=(19.0, 14.2))
ax.set_xlim(0, 191)
ax.set_ylim(0, 141)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=9.0, lw=1.9, z=3):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=z))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=z + 1, linespacing=1.35)


def plain(x, y, w, h, label, ec, fc="white", fs=8.0, lw=1.2, z=3, rot=0, tc=None):
    ax.add_patch(Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                 facecolor=fc, zorder=z))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=(tc or INK), zorder=z + 1, rotation=rot,
            linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.7, ls="-", rad=0.0, ms=12, z=4):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=ms, linewidth=lw, color=c, linestyle=ls,
                 zorder=z, connectionstyle=f"arc3,rad={rad}"))


def lab(x, y, t, c=INK, fs=7.8, style="italic", ha="center", va="center",
        rot=0, fw="normal", z=6):
    ax.text(x, y, t, ha=ha, va=va, fontsize=fs, color=c, style=style,
            rotation=rot, fontweight=fw, zorder=z, linespacing=1.4)


def mux(x, y, w, h, label, ec):
    ax.add_patch(plt.Polygon([[x, y], [x + w, y + h * 0.20],
                              [x + w, y + h * 0.80], [x, y + h]],
                 closed=True, linewidth=1.8, edgecolor=ec,
                 facecolor="white", zorder=3))
    ax.text(x + w * 0.40, y + h / 2, label, ha="center", va="center",
            fontsize=9.0, color=ec, zorder=4, fontweight="bold")


def route(pts, c=INK, lw=1.7, ls="-", z=2, arrowhead=True, ms=12):
    """Orthogonal multi-segment wire with an arrowhead on the last leg."""
    for i in range(len(pts) - 2):
        ax.plot([pts[i][0], pts[i + 1][0]], [pts[i][1], pts[i + 1][1]],
                color=c, lw=lw, ls=ls, zorder=z, solid_capstyle="round")
    a, b = pts[-2], pts[-1]
    if arrowhead:
        arrow(a[0], a[1], b[0], b[1], c=c, lw=lw, ls=ls, ms=ms, z=z + 2)
    else:
        ax.plot([a[0], b[0]], [a[1], b[1]], color=c, lw=lw, ls=ls, zorder=z)


# ======================================================================= title
ax.text(95.5, 138.0,
        "Day 41   Out-of-Order Execution Engine  —  Tomasulo register renaming, "
        "reservation stations, single CDB, in-order reorder buffer",
        ha="center", fontsize=14.6, fontweight="bold", color=INK)
ax.text(95.5, 134.4,
        "circuit / datapath schematic of the synthesized design   "
        "(hand-drawn figure, not a simulator capture)",
        ha="center", fontsize=9.4, color=MUT, style="italic")

for x0, w, nm, c in [(2, 46, "IN-ORDER FRONT END", DIS_C),
                     (52, 60, "OUT-OF-ORDER WINDOW", RS_C),
                     (116, 73, "EXECUTE + RESULT BUS", ALU_C)]:
    ax.add_patch(Rectangle((x0, 129.6), w, 3.2, facecolor=c, alpha=0.13,
                 edgecolor=c, lw=1.0, zorder=1))
    lab(x0 + w / 2, 131.2, nm, c, 8.6, "normal", fw="bold")

# ============================================================== dispatch port
box(2, 116.5, 46, 11.0,
    "in-order dispatch port   (1 instruction / cycle)\n"
    "disp_valid / disp_ready · op · rs1 · rs2 · rd\n"
    "rd_wen · imm · use_imm\n"
    "disp_ready = ROB has room && a station is free && !flush",
    DIS_C, fc="#f0f9ff", fs=7.0)

# ROB allocation, routed round the right-hand side so it crosses nothing
route([(48, 122.0), (50, 122.0), (50, 126.4), (154, 126.4), (154, 52),
       (150.5, 52), (150.5, 50)], ROB_C, 1.5, ls=(0, (5, 3)))
lab(101, 127.9, "allocate a ROB entry at the tail  —  that entry index IS the "
                "rename tag", ROB_C, 7.4)

# ======================================================================= flush
plain(52, 114.0, 13, 4.8, "flush", FLS_C, fc="#fff7ed", fs=8.6, lw=1.7)
lab(68, 117.6, "1-cycle squash of the entire speculative window: RAT.busy, every ROB\n"
               "and station entry, and all functional-unit state.  The ARF is untouched,\n"
               "which is exactly what branch-mispredict recovery needs.",
    FLS_C, 7.0, ha="left")
route([(58.5, 114.0), (58.5, 112.0)], FLS_C, 1.4, ls=(0, (3, 2)))

# ================================================================== RAT / ARF
box(2, 100, 21.5, 11.5,
    "RAT  (register alias table)\nAREGS x { busy, tag[TW] }\n"
    "\"which ROB entry owns the\nnewest definition of rN\"", RAT_C,
    fc="#f0fdfa", fs=7.6)
box(26.5, 100, 21.5, 11.5,
    "ARF  (architectural RF)\nAREGS x XLEN\nwritten ONLY at commit\n"
    "-> always a precise state", ARF_C, fc="#f0fdf4", fs=7.6)

arrow(12.5, 117.5, 12.5, 111.5, DIS_C, 1.5)
arrow(37.5, 117.5, 37.5, 111.5, DIS_C, 1.5)
lab(30.0, 115.6, "rs1 / rs2", DIS_C, 6.6)

# ===================================================== operand resolution mux
SRC = ["ARF[rs]", "ROB[q].val", "CDB bypass", "wait on q"]
for k, t in enumerate(SRC):
    yy = 94.6 - k * 3.1
    lab(3.4, yy, t, MUT, 6.4, "normal", ha="left")
    ax.plot([11.6, 16], [yy, yy], color=GRID, lw=1.1, zorder=1)
lab(3.4, 82.4, "4-way priority,\ntop entry wins", MUT, 6.2, ha="left")

mux(16, 84, 9, 12, "A", RAT_C)
mux(35, 84, 9, 12, "B", RAT_C)
lab(20.5, 97.6, "operand A resolve", RAT_C, 7.2, "normal", fw="bold")
lab(39.5, 97.6, "operand B resolve", RAT_C, 7.2, "normal", fw="bold")
lab(39.5, 81.9, "same 4-way priority,\nplus imm when use_imm", MUT, 6.2)

arrow(12.5, 100, 17.0, 96.4, RAT_C, 1.3)
arrow(37.5, 100, 38.0, 96.4, ARF_C, 1.3)

# operands captured into the freshly allocated station
route([(18.5, 84), (18.5, 76.5), (49.0, 76.5), (49.0, 95), (52, 95)], RAT_C, 1.6)
route([(37.0, 84), (37.0, 79.5), (47.0, 79.5), (47.0, 90), (52, 90)], RAT_C, 1.6)
lab(32, 73.2, "operand VALUES are captured into the station at dispatch",
    RAT_C, 6.3)

# =================================================== reservation-station pool
box(52, 78, 60, 34, "", RS_C, fc="#faf5ff", lw=2.1)
lab(82, 109.4, "UNIFIED RESERVATION-STATION POOL   (RS_DEPTH entries)",
    RS_C, 8.8, "normal", fw="bold")

cols = [("busy", 5.0), ("op", 5.5), ("fu", 5.0), ("tag", 5.5),
        ("Vj", 8.0), ("Qj", 5.5), ("Rj", 4.0),
        ("Vk", 8.0), ("Qk", 5.5), ("Rk", 4.0)]
x = 54.0
for nm, w in cols:
    lab(x + w / 2, 106.4, nm, RS_C, 7.0, "normal", fw="bold")
    x += w

rows_txt = [["1", "MUL", "MUL", "3", "0000_1f04", "-", "1", "?", "5", "0"],
            ["1", "ADD", "ALU", "4", "?", "3", "0", "0000_0002", "-", "1"],
            ["1", "DIV", "DIV", "5", "8fa1_0c00", "-", "1", "0000_0007", "-", "1"],
            ["0", "-", "-", "-", "-", "-", "-", "-", "-", "-"]]
for r, rw in enumerate(rows_txt):
    y = 101.2 - r * 5.2
    x = 54.0
    for (nm, w), t in zip(cols, rw):
        fc = "white"
        if nm in ("Rj", "Rk"):
            fc = "#dcfce7" if t == "1" else ("#fee2e2" if t == "0" else "white")
        if nm == "busy":
            fc = "#ede9fe" if t == "1" else "#f8fafc"
        plain(x + 0.3, y, w - 0.6, 4.2, t, GRID, fc=fc, fs=6.6, lw=0.9,
              tc=(MUT if t == "-" else INK))
        x += w
lab(82, 80.0, "an entry waits here until BOTH ready bits are green  —  that is "
              "the entire dataflow scheduler", MUT, 7.0)

# ============================================================ wakeup / select
box(52, 62, 60, 12,
    "WAKEUP   +   SELECT\n"
    "wakeup:  every entry compares Qj / Qk against cdb_tag,\n"
    "                 captures cdb_val and sets that ready bit\n"
    "select:  per unit, take the OLDEST ready entry,\n"
    "                 age = (tag - rob_head) mod ROB_DEPTH",
    SEL_C, fc="#fffbeb", fs=6.9)
arrow(82, 78, 82, 74, RS_C, 1.6)
lab(90.0, 76.2, "ready entries", RS_C, 6.6)

# ========================================================= functional units
box(116, 104, 36, 9.5,
    "ALU   1 cycle,  1-deep output register\nadd sub and or xor sll srl slt",
    ALU_C, fc="#eff6ff", fs=7.8)
box(116, 88, 36, 13,
    "MUL   MUL_STAGES-deep pipeline\nmul / mulh,  one result per cycle\n"
    "the whole pipe stalls if its output is blocked",
    MUL_C, fc="#faf5ff", fs=7.8)
box(116, 66, 36, 18,
    "DIV   unpipelined restoring divider\nXLEN iterations, one quotient bit per cycle\n"
    "shift  ->  compare  ->  conditional subtract\n"
    "b == 0 short-circuits: q = all ones, r = a\nholds its result until it wins the bus",
    DIV_C, fc="#fef2f2", fs=7.6)

for ysrc, ydst, c, nm in [(71.5, 108.7, ALU_C, "fire_alu"),
                          (69.0, 94.5, MUL_C, "fire_mul"),
                          (66.5, 75.0, DIV_C, "fire_div")]:
    route([(112, ysrc), (114, ysrc), (114, ydst), (116, ydst)], c, 1.5)
    lab(115.1, (ysrc + ydst) / 2.0, nm, c, 6.2, rot=90)

lab(152, 61.6, "a unit takes new work only when its output slot is free,\n"
               "or is freed this cycle by winning the bus", MUT, 6.8)

# ============================================================== CDB arbiter
box(158, 66, 31, 47.5, "", CDB_C, fc="#fff1f5", lw=2.1)
lab(173.5, 111.0, "CDB  ARBITER", CDB_C, 9.0, "normal", fw="bold")
lab(173.5, 107.6, "rotating priority", CDB_C, 7.4)
for k, (nm, c) in enumerate([("ALU req", ALU_C), ("MUL req", MUL_C),
                             ("DIV req", DIV_C)]):
    plain(161, 99.0 - k * 6.0, 24, 4.6, nm, c, fc="white", fs=7.2)
    arrow(152, 108.7 - k * 15.5, 161, 101.3 - k * 6.0, c, 1.4, rad=-0.08)
plain(161, 76.0, 24, 6.0,
      "the priority pointer advances\nafter every grant -> no unit\ncan be starved",
      CDB_C, fc="#ffe4e6", fs=6.4)
plain(161, 68.5, 24, 5.2, "one winner drives the bus;\nthe losers hold and stall",
      CDB_C, fc="white", fs=6.6)
arrow(173.5, 76.0, 173.5, 73.7, CDB_C, 1.4)

# ================================================================== CDB bus
ax.add_patch(Rectangle((2, 55.0), 187, 4.2, facecolor=CDB_C, alpha=0.16,
             edgecolor=CDB_C, lw=1.8, zorder=2))
lab(95.5, 57.1, "COMMON  DATA  BUS       { cdb_valid ,  cdb_tag[TW] ,  cdb_val[XLEN] }       "
                "—  exactly one result per cycle, for the whole machine",
    CDB_C, 8.6, "normal", fw="bold")
route([(173.5, 66), (173.5, 59.2)], CDB_C, 2.0)

# CDB fan-out taps
route([(23.0, 59.2), (23.0, 84)], CDB_C, 1.5, ls=(0, (4, 2)))
lab(25.5, 66.5, "same-cycle bypass into dispatch:\nan operand produced THIS cycle\nis read straight off the bus",
    CDB_C, 6.3, ha="left")
route([(82, 59.2), (82, 62)], CDB_C, 1.5, ls=(0, (4, 2)))
lab(84.5, 60.6, "wakeup broadcast", CDB_C, 6.3, ha="left")
route([(133, 55.0), (133, 50)], CDB_C, 1.5, ls=(0, (4, 2)))
lab(135.5, 52.4, "write the result into ROB[cdb_tag], set its done bit",
    CDB_C, 6.3, ha="left")

# =================================================================== the ROB
box(2, 26, 150, 24, "", ROB_C, fc="#eef2ff", lw=2.1)
lab(77, 47.4, "REORDER  BUFFER    (circular:  allocate at the tail in order, "
              "retire from the head in order)", ROB_C, 9.0, "normal", fw="bold")
lab(66, 44.6, "the done bits fill in OUT of program order — that is what "
              "out-of-order execution looks like in state", MUT, 6.8)

NE = 8
ew = 16.5
for e in range(NE):
    x0 = 7 + e * ew
    done = e in (1, 2, 4, 5)
    plain(x0, 32.5, ew - 1.6, 10.0, "", ROB_C, fc="white", lw=1.2)
    lab(x0 + (ew - 1.6) / 2, 40.6, f"tag {e}", ROB_C, 6.8, "normal", fw="bold")
    plain(x0 + 1.0, 37.4, 5.6, 2.6, "busy", GRID, fc="#e0e7ff", fs=5.6)
    plain(x0 + 7.4, 37.4, 5.9, 2.6, "done" if done else "—", GRID,
          fc=("#dcfce7" if done else "#f8fafc"), fs=5.6,
          tc=(INK if done else MUT))
    plain(x0 + 1.0, 33.6, 4.0, 3.0, "rd", GRID, fc="white", fs=5.8)
    plain(x0 + 5.4, 33.6, 3.2, 3.0, "we", GRID, fc="white", fs=5.8)
    plain(x0 + 9.0, 33.6, 4.3, 3.0, "val", GRID, fc="white", fs=5.8)

arrow(7 + 7, 30.2, 7 + 7, 32.3, CMT_C, 1.8)
lab(7 + 7, 28.5, "head (retire)", CMT_C, 6.8, "normal", fw="bold")
arrow(7 + 6 * ew + 7, 30.2, 7 + 6 * ew + 7, 32.3, DIS_C, 1.8)
lab(7 + 6 * ew + 7, 28.5, "tail (allocate)", DIS_C, 6.8, "normal", fw="bold")

# ==================================================================== commit
box(156, 26, 33, 24,
    "COMMIT   (in-order retire)\n\n"
    "if ROB[head].busy && .done:\n"
    "   ARF[rd] <- val   (if wen)\n"
    "   release RAT[rd] only if\n"
    "   RAT[rd].tag == head\n"
    "   head <- head + 1\n\n"
    "registered commit port out",
    CMT_C, fc="#f0fdf4", fs=7.2)
arrow(152, 38, 156, 38, ROB_C, 1.8)

# commit write-back to the architectural state, routed round the left edge
route([(156, 30.0), (154, 30.0), (154, 22.5), (1.2, 22.5), (1.2, 113.5),
       (6, 113.5), (6, 111.5)], CMT_C, 1.6, ls=(0, (5, 3)))
route([(6, 113.5), (43, 113.5), (43, 111.5)], CMT_C, 1.5, ls=(0, (5, 3)))
lab(74, 21.0, "commit write-back:  ARF[rd] <- value  and  release the RAT alias   "
              "—  the ONLY writer of architectural state", CMT_C, 7.2)


# ============================================================ inset panels
def inset(x, y, w, h, title, c):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.4",
                 linewidth=1.5, edgecolor=c, facecolor="white", zorder=3))
    ax.text(x + 2.0, y + h - 2.4, title, ha="left", va="center", fontsize=8.4,
            color=c, fontweight="bold", zorder=5)


# ---- opcodes -------------------------------------------------------------
inset(2, 2, 58, 16.5, "opcode map  /  unit  /  latency to the result bus", ALU_C)
rows = [("0-7", "ADD SUB AND OR XOR SLL SRL SLT", "ALU", "1 cycle"),
        ("8-9", "MUL  MULH   (unsigned, low / high)", "MUL", "MUL_STAGES"),
        ("10-11", "DIV  REM    (unsigned)", "DIV", "XLEN + 1")]
ax.text(4.5, 13.0, "op", fontsize=6.8, color=MUT, fontweight="bold")
ax.text(11.5, 13.0, "mnemonics", fontsize=6.8, color=MUT, fontweight="bold")
ax.text(41.0, 13.0, "unit", fontsize=6.8, color=MUT, fontweight="bold")
ax.text(48.5, 13.0, "latency", fontsize=6.8, color=MUT, fontweight="bold")
for k, (o, m, u, l) in enumerate(rows):
    yy = 10.2 - k * 2.6
    ax.text(4.5, yy, o, fontsize=6.8, color=INK, family="monospace")
    ax.text(11.5, yy, m, fontsize=6.8, color=INK, family="monospace")
    ax.text(41.0, yy, u, fontsize=6.8, color=INK, family="monospace")
    ax.text(48.5, yy, l, fontsize=6.8, color=INK, family="monospace")
ax.text(4.5, 3.4, "divide by zero: quotient = all ones, remainder = dividend "
                  "(the RISC-V rule)",
        fontsize=6.4, color=MUT, style="italic")

# ---- equations -----------------------------------------------------------
inset(63, 2, 60, 16.5, "the three equations the machine runs on", SEL_C)
eqs = [
    "resolve(s)  =  !RAT[s].busy                        ? ARF[s]",
    "               : ROB[RAT[s].tag].done              ? ROB[RAT[s].tag].val",
    "               : cdb_valid && cdb_tag==RAT[s].tag  ? cdb_val",
    "               : WAIT on  q = RAT[s].tag",
    "",
    "wakeup(i)   =  rs_busy[i] && !R[i] && (Q[i] == cdb_tag)",
    "select(fu)  =  argmin (tag - rob_head)  over the ready entries of fu",
]
for k, e in enumerate(eqs):
    ax.text(65.0, 13.2 - k * 1.5, e, fontsize=6.2, color=INK,
            family="monospace")
ax.text(65.0, 3.1, "wakeup costs one cycle: an entry woken by the bus in cycle T "
                   "becomes selectable in T+1",
        fontsize=6.4, color=MUT, style="italic")

# ---- hazards -------------------------------------------------------------
inset(126, 2, 63, 16.5, "which hazard each block exists to solve", RS_C)
hz = [("RAW", "true dependency", "tag + CDB wakeup / same-cycle bypass", RS_C),
      ("WAW", "two writers, one reg", "distinct tags; the RAT release is guarded", RAT_C),
      ("WAR", "reader before writer", "operands are CAPTURED at dispatch", RAT_C),
      ("structural", "one bus, three units", "rotating arbiter; the loser holds+stalls", CDB_C),
      ("precise state", "mispredict / fault", "in-order retire; flush keeps the ARF", CMT_C)]
for k, (h, d, s, c) in enumerate(hz):
    yy = 13.2 - k * 2.4
    ax.text(128.5, yy, h, fontsize=6.6, color=c, fontweight="bold",
            family="monospace")
    ax.text(145.5, yy, d, fontsize=6.2, color=MUT, style="italic")
    ax.text(161.0, yy, s, fontsize=6.2, color=INK)

fig.savefig("docs/ooo_tomasulo_block.png", dpi=140, facecolor="white",
            bbox_inches="tight", pad_inches=0.25)
print("wrote docs/ooo_tomasulo_block.png")
