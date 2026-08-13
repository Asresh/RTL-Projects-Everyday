#!/usr/bin/env python3
"""Generate the Day 44 circuit diagram and a waveform plot.

The waveform is rendered from the real VCD produced by the Icarus run
(`make icarus` writes dram_fr_fcfs_ctrl.vcd), not hand-modelled.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

HERE = Path(__file__).resolve().parent
DOCS = HERE / "docs"
DOCS.mkdir(exist_ok=True)

BANKS, ROW_BITS, COL_BITS, DATA_W, ID_W = 4, 8, 6, 32, 6
QDEPTH, QCW = 8, 4
BB = 2
ADDR_W = ROW_BITS + BB + COL_BITS

INK    = "#1e293b"
MUTED  = "#64748b"
GRID   = "#e2e8f0"
BLUE   = "#0369a1"
VIOLET = "#7c3aed"
GREEN  = "#15803d"
AMBER  = "#b45309"
RED    = "#be123c"
TEAL   = "#0f766e"


# ---------------------------------------------------------------------------
# VCD parsing
# ---------------------------------------------------------------------------
def parse_vcd(path):
    names, changes, scopes, defs, now = {}, {}, [], True, 0
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if defs:
                if line.startswith("$scope"):
                    scopes.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scopes.pop()
                elif line.startswith("$var"):
                    p = line.split()
                    names.setdefault(p[3], []).append(".".join(scopes + [p[4]]))
                elif line.startswith("$enddefinitions"):
                    defs = False
                continue
            if line[0] == "#":
                now = int(line[1:])
            elif line[0] in "01xXzZ":
                for name in names.get(line[1:], []):
                    changes.setdefault(name, []).append((now, line[0].lower()))
            elif line[0] in "bB":
                value, code = line[1:].split()
                for name in names.get(code, []):
                    changes.setdefault(name, []).append((now, value.lower()))
    return changes


def find(changes, suffix):
    """Prefer the shallowest match, i.e. the testbench-level signal."""
    hits = [n for n in changes if n.endswith("." + suffix) or n == suffix]
    if not hits:
        raise KeyError(suffix)
    return changes[min(hits, key=lambda n: n.count("."))]


def value(series, t):
    answer = "x"
    for when, val in series:
        if when > t:
            break
        answer = val
    return answer


def bits(series, t, width):
    """Zero-extended binary string, MSB first (VCD strips leading zeros)."""
    v = value(series, t)
    if any(c in v for c in "xz"):
        return "x" * width
    return v.rjust(width, "0")


def field(s, hi, lo):
    """Extract s[hi:lo] from an MSB-first string as an int, or None if X."""
    n = len(s)
    chunk = s[n - 1 - hi:n - lo]
    if any(c in chunk for c in "xz"):
        return None
    return int(chunk, 2)


def integer(series, t, width=32):
    return field(bits(series, t, width), width - 1, 0)


# ---------------------------------------------------------------------------
# Waveform figure
# ---------------------------------------------------------------------------
CMD_NAME = {0: "-", 1: "ACT", 2: "RD", 3: "WR", 4: "PRE", 5: "PREA", 6: "REF"}


def waveform():
    vcd = HERE / "dram_fr_fcfs_ctrl.vcd"
    if not vcd.exists():
        raise SystemExit("dram_fr_fcfs_ctrl.vcd not found - run `make icarus` first")
    ch = parse_vcd(vcd)

    sig = {n: find(ch, n) for n in [
        "clk", "phase", "req_valid", "req_ready", "req_we", "req_addr",
        "dram_cmd", "dram_bank", "dram_row", "dram_col",
        "dbg_bank_open", "dbg_occupancy", "dram_rvalid",
        "r_valid", "r_id", "r_data", "perf_row_hits", "perf_row_misses"]}

    edges = [t for t, v in sig["clk"] if v == "1"]

    # Phase 2 is the directed row-locality test: four reads that all hit the
    # open row of bank 1, then one read to a different row of the same bank,
    # which forces PRE -> ACT.  Start the window a few cycles before its ACT.
    first_ph2 = None
    for i, t in enumerate(edges):
        if integer(sig["phase"], t - 1, 8) == 2:
            first_ph2 = i
            break
    if first_ph2 is None:
        raise SystemExit("could not locate phase 2 in the VCD")

    start = None
    for i in range(first_ph2, len(edges)):
        if integer(sig["dram_cmd"], edges[i] - 1, 3) == 1:      # ACT
            start = max(0, i - 4)
            break
    if start is None:
        raise SystemExit("could not locate the phase-2 ACT in the VCD")

    edges = edges[start:start + 34]
    times = [t - 1 for t in edges]
    n = len(times)

    def occ_of(t, b):
        return field(bits(sig["dbg_occupancy"], t, BANKS * QCW),
                     b * QCW + QCW - 1, b * QCW)

    def req_txt(t):
        a = integer(sig["req_addr"], t, ADDR_W)
        if a is None:
            return ""
        we = integer(sig["req_we"], t, 1)
        return "%s b%d r%d c%d" % ("WR" if we else "RD",
                                   (a >> COL_BITS) & (BANKS - 1),
                                   a >> (COL_BITS + BB),
                                   a & ((1 << COL_BITS) - 1))

    def req_active(t):
        return integer(sig["req_valid"], t, 1) == 1

    def cmd_active(t):
        c = integer(sig["dram_cmd"], t, 3)
        return c is not None and c != 0

    def col_active(t):
        return integer(sig["dram_cmd"], t, 3) in (2, 3)

    def row_active(t):
        # The row field only carries meaning for ACT and the column commands;
        # on PRE / PREA / REF it is a don't-care, so leave those cells blank.
        return integer(sig["dram_cmd"], t, 3) in (1, 2, 3)

    def rvalid_active(t):
        return integer(sig["r_valid"], t, 1) == 1

    rows = [
        ("clk",                    "clk",  None, INK, None),
        ("req_valid",              "bit",  lambda t: integer(sig["req_valid"], t, 1), BLUE, None),
        ("req_ready",              "bit",  lambda t: integer(sig["req_ready"], t, 1), BLUE, None),
        ("request",                "text", req_txt, BLUE, req_active),
        ("bank1 occupancy",        "dec",  lambda t: occ_of(t, 1), VIOLET, None),
        ("dbg_bank_open [3:0]",    "bin",  lambda t: bits(sig["dbg_bank_open"], t, BANKS), VIOLET, None),
        ("dram_cmd_o",             "text", lambda t: CMD_NAME.get(integer(sig["dram_cmd"], t, 3), "?"), GREEN, cmd_active),
        ("dram_bank_o",            "dec",  lambda t: integer(sig["dram_bank"], t, BB), GREEN, cmd_active),
        ("dram_row_o",             "dec",  lambda t: integer(sig["dram_row"], t, ROW_BITS), GREEN, row_active),
        ("dram_col_o",             "dec",  lambda t: integer(sig["dram_col"], t, COL_BITS), GREEN, col_active),
        ("dram_rvalid_i",          "bit",  lambda t: integer(sig["dram_rvalid"], t, 1), AMBER, None),
        ("r_valid_o",              "bit",  lambda t: integer(sig["r_valid"], t, 1), TEAL, None),
        ("r_id_o",                 "dec",  lambda t: integer(sig["r_id"], t, ID_W), TEAL, rvalid_active),
        ("perf_row_hits_o",        "dec",  lambda t: integer(sig["perf_row_hits"], t), RED, None),
        ("perf_row_misses_o",      "dec",  lambda t: integer(sig["perf_row_misses"], t), RED, None),
    ]

    fig, ax = plt.subplots(figsize=(21, 9.6))
    ax.set_xlim(-6.6, n - 0.25)
    ax.set_ylim(-0.9, len(rows) + 1.3)
    ax.axis("off")
    fig.suptitle("Day 44 - FR-FCFS DRAM controller: real captured Icarus VCD",
                 fontsize=15, fontweight="bold", y=0.985)
    ax.text(0.5, 1.025,
            "Bank 1 activates row 5, then four reads issue one per tCCD=2 - the "
            "first is charged as the row MISS that caused the ACT, the next three "
            "as row HITS.  The fifth read targets row 9, so the bank precharges "
            "once tRAS is met and re-activates.  Read data returns CAS_LAT=5 "
            "cycles after each RD.",
            transform=ax.transAxes, ha="center", fontsize=9.5, color=MUTED)

    for x in range(n):
        ax.axvline(x, color=GRID, lw=0.7)
        if x % 2 == 0:
            ax.text(x, len(rows) + 0.42, str(x), ha="center", fontsize=7, color=MUTED)
    ax.text(-6.3, len(rows) + 0.42, "cycle", fontsize=8, color=MUTED)

    for ri, (label, kind, fn, color, gate) in enumerate(rows):
        y = len(rows) - ri - 1
        ax.text(-6.3, y + 0.42, label, ha="left", va="center",
                family="monospace", fontsize=8.6, color=color)
        ax.axhline(y, color=GRID, lw=0.6)

        if kind == "clk":
            for x in range(n):
                ax.plot([x - 0.48, x - 0.48, x, x, x + 0.48],
                        [y + 0.12, y + 0.78, y + 0.78, y + 0.12, y + 0.12],
                        color=color, lw=1.3)
            continue

        if kind == "bit":
            prev = None
            for x, t in enumerate(times):
                v = fn(t)
                lvl = y + (0.78 if v else 0.12)
                ax.plot([x - 0.5, x + 0.5], [lvl, lvl], color=color, lw=1.8)
                if prev is not None and prev != v:
                    ax.plot([x - 0.5, x - 0.5], [y + 0.12, y + 0.78],
                            color=color, lw=1.8)
                prev = v
            continue

        # bussed rows: one cell per cycle holding the decoded value
        for x, t in enumerate(times):
            if gate is not None and not gate(t):
                ax.plot([x - 0.46, x + 0.46], [y + 0.46, y + 0.46],
                        color=GRID, lw=1.1)
                continue
            v = fn(t)
            if kind == "bin":
                txt = v if isinstance(v, str) else ""
            elif kind == "dec":
                txt = "" if v is None else str(v)
            else:
                txt = v or ""
            if txt in ("", None):
                continue
            filled = txt not in ("0000", "0", "-")
            ax.add_patch(Rectangle((x - 0.46, y + 0.14), 0.92, 0.64,
                                   facecolor=color if filled else "white",
                                   alpha=0.16 if filled else 1.0,
                                   edgecolor=color, lw=0.9))
            ax.text(x, y + 0.46, txt, ha="center", va="center",
                    family="monospace", fontsize=6.4, color=color)

    fig.tight_layout(rect=(0, 0.02, 1, 0.93))
    out = DOCS / "dram_fr_fcfs_ctrl_waveform.png"
    fig.savefig(out, dpi=125)
    plt.close(fig)
    print("wrote", out)


# ---------------------------------------------------------------------------
# Circuit / dataflow diagram
# ---------------------------------------------------------------------------
def box(ax, x, y, w, h, label, fc, ec, fs=9, tc=None, weight="bold"):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0.012,rounding_size=0.03",
                                facecolor=fc, edgecolor=ec, lw=1.3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=tc or ec, fontweight=weight, linespacing=1.35)


def arrow(ax, p, q, color, lw=1.3, style="-|>", ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, color=color, lw=lw,
                                 linestyle=ls, mutation_scale=11,
                                 connectionstyle="arc3,rad=%g" % rad,
                                 shrinkA=1, shrinkB=1))


def diagram():
    fig, ax = plt.subplots(figsize=(18, 9.9))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    fig.suptitle("Day 44 - FR-FCFS DRAM Memory Controller: circuit diagram",
                 fontsize=15.5, fontweight="bold", y=0.978)
    ax.text(0.5, 0.955,
            "one command per cycle, chosen from three readiness tiers and gated "
            "by the full JEDEC timing set",
            transform=ax.transAxes, ha="center", fontsize=10, color=MUTED)

    # -- ingress ------------------------------------------------------------
    box(ax, 0.015, 0.70, 0.13, 0.115,
        "request port\nvalid / ready\nwe, addr, wdata, id", "#f0f9ff", BLUE, 8.2)
    box(ax, 0.015, 0.545, 0.13, 0.105,
        "address decode\n{row, bank, col}\nbank in the middle", "#f0f9ff", BLUE, 8.2)
    arrow(ax, (0.08, 0.70), (0.08, 0.65), BLUE)

    # -- per-bank queues ----------------------------------------------------
    box(ax, 0.185, 0.505, 0.20, 0.34, "", "#faf5ff", VIOLET, 8)
    ax.text(0.285, 0.822, "per-bank transaction queues", ha="center",
            fontsize=9.4, color=VIOLET, fontweight="bold")
    for i in range(BANKS):
        y = 0.755 - i * 0.062
        box(ax, 0.200, y, 0.17, 0.05,
            "bank %d  queue[8]  {we,row,col,data,id,age}" % i,
            "#ffffff", VIOLET, 6.6, weight="normal")
    ax.text(0.285, 0.523, "collapsing queues - entry 0 is that bank's oldest",
            ha="center", fontsize=7.2, color=MUTED, style="italic")
    arrow(ax, (0.145, 0.597), (0.185, 0.62), BLUE)

    # -- candidate analysis -------------------------------------------------
    box(ax, 0.415, 0.615, 0.155, 0.23,
        "per-bank candidate\nanalysis\n\n"
        "has_hit / hit_idx\n(oldest hit)\nhas_miss\n"
        "cap_stop  (hit streak\n>= ROW_HIT_CAP)\nneed_act / need_pre",
        "#fdf4ff", VIOLET, 7.8)
    arrow(ax, (0.385, 0.70), (0.415, 0.72), VIOLET)

    # -- bank state ---------------------------------------------------------
    # Kept narrower than the boxes above and below it so the channel at
    # x ~ 0.585 stays clear for the counter tap.
    box(ax, 0.415, 0.395, 0.135, 0.145,
        "bank row-buffer state\n\nopen[b], open_row[b]\nhit_streak[b]\n\n"
        "rewritten by every issued\ncommand, with its timers",
        "#f0fdf4", GREEN, 7.6)
    arrow(ax, (0.4425, 0.540), (0.4425, 0.615), GREEN)

    # -- selector -----------------------------------------------------------
    box(ax, 0.615, 0.565, 0.19, 0.28, "", "#eff6ff", BLUE, 8)
    ax.text(0.710, 0.822, "FR-FCFS command selector", ha="center",
            fontsize=9.4, color=BLUE, fontweight="bold")
    box(ax, 0.628, 0.742, 0.164, 0.062,
        "tier 1  RD / WR on the open row", "#dbeafe", BLUE, 7.2, weight="normal")
    box(ax, 0.628, 0.672, 0.164, 0.062,
        "tier 2  ACT a precharged bank", "#e0e7ff", VIOLET, 7.2, weight="normal")
    box(ax, 0.628, 0.602, 0.164, 0.062,
        "tier 3  PRE a bank that must\nturn its row", "#ede9fe", VIOLET, 7.2,
        weight="normal")
    ax.text(0.710, 0.578, "within a tier: wrap-safe oldest age wins",
            ha="center", fontsize=7.2, color=MUTED, style="italic")
    arrow(ax, (0.570, 0.73), (0.615, 0.73), VIOLET)

    # -- timing gates -------------------------------------------------------
    box(ax, 0.615, 0.315, 0.19, 0.215,
        "timing legality gates\n\n"
        "per bank:  tRCD  tRP  tRAS  tWR\n"
        "channel :  tCCD  tRRD  tWTR  tRTW\n"
        "tFAW: <=4 ACTs in a rolling\n"
        "        14-cycle window\n"
        "read-ID FIFO not full",
        "#fffbeb", AMBER, 7.8)
    arrow(ax, (0.690, 0.530), (0.690, 0.565), AMBER)
    ax.text(0.700, 0.543, "veto", fontsize=7, color=AMBER, ha="left")

    # -- refresh FSM --------------------------------------------------------
    box(ax, 0.615, 0.115, 0.19, 0.165,
        "refresh FSM\n\n"
        "tREFI counter -> IDLE ->\nR_PRE (PREA when tRAS/tWR\n"
        "clear) -> R_RP -> REF ->\nR_RFC (wait tRFC)",
        "#fef2f2", RED, 7.8)
    arrow(ax, (0.660, 0.280), (0.660, 0.315), RED)
    ax.text(0.670, 0.294, "blocks all issue", fontsize=7, color=RED, ha="left")

    # -- command register ---------------------------------------------------
    box(ax, 0.845, 0.615, 0.14, 0.155,
        "command bus\nregister\n\ncmd, bank,\nrow, col, wdata",
        "#f0fdf4", GREEN, 8.2)
    arrow(ax, (0.805, 0.70), (0.845, 0.70), BLUE)

    box(ax, 0.845, 0.435, 0.14, 0.115,
        "DRAM device\n/ PHY\n\nACT RD WR PRE\nPREA REF", "#ffffff", INK, 8.0)
    arrow(ax, (0.915, 0.615), (0.915, 0.550), GREEN)

    # -- read return path ---------------------------------------------------
    box(ax, 0.845, 0.255, 0.14, 0.115,
        "read-ID FIFO\n\nRD order == data\nreturn order", "#fffbeb", AMBER, 8.0)
    arrow(ax, (0.880, 0.435), (0.880, 0.370), AMBER)
    ax.text(0.888, 0.400, "rvalid, rdata\n(CAS_LAT later)", fontsize=6.8,
            color=AMBER, ha="left", va="center")

    box(ax, 0.845, 0.085, 0.14, 0.135,
        "response channels\n\nr_valid, r_id, r_data\nb_valid, b_id",
        "#f0f9ff", TEAL, 8.0)
    arrow(ax, (0.915, 0.255), (0.915, 0.220), TEAL)

    # -- perf counters ------------------------------------------------------
    box(ax, 0.415, 0.105, 0.145, 0.265,
        "performance counters\n\ncounts each issued\ncommand\n\n"
        "row_hits\nrow_misses\nacts / pres\nrefreshes\nidle command slots",
        "#f8fafc", MUTED, 7.8, tc=INK)
    # Tap the issued command down the clear channel to the right of the
    # bank-state box.
    arrow(ax, (0.618, 0.566), (0.564, 0.372), MUTED, ls=":", rad=0.18)

    # -- feedback: issue updates state and queues ---------------------------
    arrow(ax, (0.640, 0.565), (0.552, 0.505), GREEN, ls="--")
    # Dequeue feedback runs in the clear channel between the queues and the
    # candidate-analysis box.
    arrow(ax, (0.613, 0.560), (0.388, 0.560), VIOLET, ls="--", rad=0.05)
    ax.text(0.500, 0.590, "dequeue on column command", fontsize=7.0,
            color=VIOLET, ha="center", va="center")

    # -- backpressure -------------------------------------------------------
    arrow(ax, (0.200, 0.845), (0.080, 0.815), VIOLET, ls="--", rad=-0.15)
    ax.text(0.140, 0.878, "ready = selected bank's\nqueue not full",
            fontsize=6.9, color=VIOLET, ha="center", va="center")

    # -- legend -------------------------------------------------------------
    ax.text(0.015, 0.045,
            "solid = datapath     dashed = control feedback     dotted = state / "
            "veto     one command leaves the register every cycle",
            fontsize=8.2, color=MUTED)
    ax.text(0.015, 0.015,
            "BANKS=4  ROWS=256  COLS=64  QDEPTH=8/bank  ROW_HIT_CAP=4  "
            "CAS_LAT=5  tREFI=512",
            fontsize=8.2, color=MUTED, family="monospace")

    fig.tight_layout(rect=(0, 0, 1, 0.965))
    out = DOCS / "dram_fr_fcfs_ctrl_block.png"
    fig.savefig(out, dpi=115)
    plt.close(fig)
    print("wrote", out)


if __name__ == "__main__":
    diagram()
    waveform()
