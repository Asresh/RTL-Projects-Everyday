#!/usr/bin/env python3
"""Generate the Day 45 circuit diagram and the waveform plot.

The waveform is rendered from the real VCD produced by the Icarus run
(`make icarus` writes mesi_snoop_coherence.vcd), not hand-modelled.  The
circuit diagram is hand-drawn documentation.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

HERE = Path(__file__).resolve().parent
DOCS = HERE / "docs"
DOCS.mkdir(exist_ok=True)

NUM_CORES, SETS, WAYS, LINE_WORDS, DATA_W, TAG_W = 4, 8, 2, 4, 32, 4
SIDX, WOFF, CSEL = 3, 2, 2
LADDR_W = TAG_W + SIDX
LINE_W = LINE_WORDS * DATA_W

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
# Waveform figure - the simultaneous-upgrade race (stimulus phase 7)
# ---------------------------------------------------------------------------
CMD_NAME   = {0: "Rd", 1: "RdX", 2: "Upgr", 3: "WB"}
BSTATE     = {0: "-", 1: "snp", 2: "c2c", 3: "mwr",
              4: "mrd", 5: "mwt", 6: "cmt"}
MESI       = {0: "I", 1: "S", 2: "E", 3: "M"}
FSM_NAME   = {0: "idle", 1: "look", 2: "wb", 3: "req", 4: "wait", 5: "resp"}


def waveform():
    vcd = HERE / "mesi_snoop_coherence.vcd"
    if not vcd.exists():
        raise SystemExit("mesi_snoop_coherence.vcd not found - run `make icarus` first")
    ch = parse_vcd(vcd)

    sig = {n: find(ch, n) for n in [
        "clk", "phase", "cr_valid", "cr_we", "cr_rvalid",
        "bus_gnt", "bus_cmd", "bus_line", "bus_owner", "bus_state", "bus_commit",
        "snp_hit", "snp_dirty", "watch_state", "dbg_fsm", "mem_req", "mem_we",
        "p_busupgr", "p_busrdx", "p_race", "p_c2c"]}

    edges = [t for t, v in sig["clk"] if v == "1"]

    # Phase 7 is the race: both cores hold the line Shared and store to
    # different words of it in the same cycle.  Anchor on the BusUpgr snoop
    # phase inside phase 7 and back up far enough to catch both requests.
    anchor = None
    for i, t in enumerate(edges):
        s = t - 1
        if (integer(sig["phase"], s, 8) == 7
                and integer(sig["bus_state"], s, 3) == 1        # B_SNOOP
                and integer(sig["bus_cmd"], s, 2) == 2):        # BUSUPGR
            anchor = i
            break
    if anchor is None:
        raise SystemExit("could not locate the phase-7 BusUpgr in the VCD")

    start = max(0, anchor - 4)
    edges = edges[start:start + 22]
    times = [t - 1 for t in edges]
    n = len(times)

    def vec_bit(name, width):
        return lambda t, name=name, width=width: bits(sig[name], t, width)

    def core_state(c):
        return lambda t, c=c: MESI.get(
            field(bits(sig["watch_state"], t, NUM_CORES * 2), c*2 + 1, c*2), "?")

    def core_fsm(c):
        return lambda t, c=c: FSM_NAME.get(
            field(bits(sig["dbg_fsm"], t, NUM_CORES * 4), c*4 + 3, c*4), "?")

    def bus_busy(t):
        return integer(sig["bus_state"], t, 3) not in (0, None)

    def gnt_txt(t):
        g = bits(sig["bus_gnt"], t, NUM_CORES)
        if "1" not in g:
            return ""
        return "c%d" % (NUM_CORES - 1 - g.index("1"))

    def line_txt(t):
        v = integer(sig["bus_line"], t, LADDR_W)
        if v is None or not bus_busy(t):
            return ""
        return "t%d s%d" % (v >> SIDX, v & (SETS - 1))

    def mem_txt(t):
        if integer(sig["mem_req"], t, 1) != 1:
            return ""
        return "WR" if integer(sig["mem_we"], t, 1) == 1 else "RD"

    rows = [
        ("clk",                 "clk",  None, INK, None),
        ("cr_valid [3:0]",      "bin",  vec_bit("cr_valid", NUM_CORES), BLUE, None),
        ("core0 cache fsm",     "text", core_fsm(0), BLUE, None),
        ("core1 cache fsm",     "text", core_fsm(1), BLUE, None),
        ("bus grant",           "text", gnt_txt, AMBER, None),
        ("bus_state",           "text", lambda t: BSTATE.get(integer(sig["bus_state"], t, 3), "?"), AMBER, None),
        ("bus_cmd",             "text", lambda t: CMD_NAME.get(integer(sig["bus_cmd"], t, 2), "?"), AMBER, bus_busy),
        ("bus line",            "text", line_txt, AMBER, None),
        ("snp_hit   [3:0]",     "bin",  vec_bit("snp_hit", NUM_CORES), VIOLET, None),
        ("snp_dirty [3:0]",     "bin",  vec_bit("snp_dirty", NUM_CORES), VIOLET, None),
        ("bus_commit",          "bit",  lambda t: integer(sig["bus_commit"], t, 1), VIOLET, None),
        ("memory port",         "text", mem_txt, TEAL, None),
        ("core0 state",         "text", core_state(0), GREEN, None),
        ("core1 state",         "text", core_state(1), GREEN, None),
        ("core2 state",         "text", core_state(2), GREEN, None),
        ("core3 state",         "text", core_state(3), GREEN, None),
        ("cr_rvalid [3:0]",     "bin",  vec_bit("cr_rvalid", NUM_CORES), BLUE, None),
        ("perf_busupgr",        "dec",  lambda t: integer(sig["p_busupgr"], t), RED, None),
        ("perf_busrdx",         "dec",  lambda t: integer(sig["p_busrdx"], t), RED, None),
        ("perf_upgr_race",      "dec",  lambda t: integer(sig["p_race"], t), RED, None),
        ("perf_c2c",            "dec",  lambda t: integer(sig["p_c2c"], t), RED, None),
    ]

    fig, ax = plt.subplots(figsize=(15.5, 10.6))
    ax.set_xlim(-6.4, n - 0.25)
    ax.set_ylim(-0.6, len(rows) + 1.1)
    ax.axis("off")
    fig.suptitle("Day 45 - MESI coherence: the simultaneous-upgrade race, "
                 "real captured Icarus VCD",
                 fontsize=14.5, fontweight="bold", y=0.985)
    fig.text(0.5, 0.935,
             "Cores 0 and 1 both hold tag 6 / set 1 Shared and store to different words of it in the same cycle (cr_valid = 0011), so both request the bus.\n"
             "The arbiter grants core 0 at cycle 4; its BusUpgr moves no data and commits two cycles later, taking core 1's copy away - core 0 becomes M,\n"
             "core 1 becomes I.  Core 1, granted at cycle 6, can no longer issue an invalidate-only transaction, so it promotes its request to BusRdX\n"
             "(perf_upgr_race increments), takes core 0's dirty line by cache-to-cache transfer, flushes it to memory, and merges its own word at cycle 12.\n"
             "Both stores survive and exactly one owner remains.  Bus states: snp = snoop, c2c = intervention, mwr = memory write, cmt = commit.",
             ha="center", va="top", fontsize=8.8, color=MUTED, linespacing=1.55)

    for x in range(n):
        ax.axvline(x, color=GRID, lw=0.7)
        if x % 2 == 0:
            ax.text(x, len(rows) + 0.42, str(x), ha="center", fontsize=7, color=MUTED)
    ax.text(-6.1, len(rows) + 0.42, "cycle", fontsize=8, color=MUTED)

    for ri, (label, kind, fn, color, gate) in enumerate(rows):
        y = len(rows) - ri - 1
        ax.text(-6.1, y + 0.42, label, ha="left", va="center",
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
            filled = txt not in ("0000", "0", "-", "I")
            ax.add_patch(Rectangle((x - 0.46, y + 0.14), 0.92, 0.64,
                                   facecolor=color if filled else "white",
                                   alpha=0.16 if filled else 1.0,
                                   edgecolor=color, lw=0.9))
            ax.text(x, y + 0.46, txt, ha="center", va="center",
                    family="monospace", fontsize=6.4, color=color)

    fig.subplots_adjust(left=0.004, right=0.997, top=0.855, bottom=0.015)
    out = DOCS / "mesi_snoop_coherence_waveform.png"
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
    fig, ax = plt.subplots(figsize=(18, 10.4))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    fig.suptitle("Day 45 - MESI Snooping Cache-Coherence Complex: circuit diagram",
                 fontsize=15.5, fontweight="bold", y=0.972)
    ax.text(0.5, 0.962,
            "four write-back L1 caches on one atomic snooping bus - every "
            "coherence event is ordered by the arbiter",
            transform=ax.transAxes, ha="center", fontsize=10, color=MUTED)

    # -- the four caches ----------------------------------------------------
    cx = [0.028, 0.263, 0.498, 0.733]
    cw = 0.222
    for i, x in enumerate(cx):
        box(ax, x, 0.585, cw, 0.315, "", "#f8fafc", BLUE, 8)
        ax.text(x + cw / 2, 0.874, "core %d  L1 data cache" % i, ha="center",
                fontsize=9.6, color=BLUE, fontweight="bold")

        box(ax, x + 0.012, 0.828, cw - 0.024, 0.036,
            "core port  valid/ready  we, addr, wdata", "#ffffff", BLUE, 6.6,
            weight="normal")

        box(ax, x + 0.012, 0.700, 0.098, 0.118,
            "tag / state /\ndata arrays\n\n%d sets x %d ways\nstate: M E S I\n"
            "line = %d words" % (SETS, WAYS, LINE_WORDS),
            "#eff6ff", BLUE, 6.6, weight="normal")

        box(ax, x + 0.118, 0.700, 0.092, 0.118,
            "request FSM\n\nidle - look\nwb - req\nwait - resp\n\n"
            "invalid-first,\nthen round-robin\nvictim",
            "#eff6ff", VIOLET, 6.6, weight="normal")

        box(ax, x + 0.012, 0.640, 0.098, 0.05,
            "snoop tag\ncomparator", "#faf5ff", VIOLET, 6.8, weight="normal")
        box(ax, x + 0.118, 0.640, 0.092, 0.05,
            "race guards\nupgr -> rdx\nwb cancel", "#fff1f2", RED, 6.4,
            weight="normal")

        ax.text(x + cw / 2, 0.606,
                "hit + M/E -> store completes with no bus traffic",
                ha="center", fontsize=6.4, color=MUTED, style="italic")

        # request up to the bus, snoop broadcast down from it
        arrow(ax, (x + 0.075, 0.585), (x + 0.075, 0.540), BLUE)
        arrow(ax, (x + 0.155, 0.540), (x + 0.155, 0.585), VIOLET)

    ax.text(0.012, 0.555, "bus_req / cmd / line / victim line", fontsize=6.8,
            color=BLUE, rotation=0)
    ax.text(0.786, 0.555, "snoop cmd+line, invalidate, fill", fontsize=6.8,
            color=VIOLET, ha="left")

    # -- the snooping bus ---------------------------------------------------
    box(ax, 0.028, 0.245, 0.927, 0.285, "", "#fffbeb", AMBER, 8)
    ax.text(0.4915, 0.503, "snooping bus  -  one atomic transaction in flight",
            ha="center", fontsize=10.4, color=AMBER, fontweight="bold")

    box(ax, 0.048, 0.348, 0.145, 0.128,
        "round-robin\narbiter\n\nfirst requester at\nor after rr_ptr\n\n"
        "one grant per cycle", "#ffffff", AMBER, 7.6)

    box(ax, 0.214, 0.348, 0.163, 0.128,
        "snoop phase\n\nbroadcast cmd + line\nto every cache\n\n"
        "shared_any = |hit\ndirty_any  = |dirty\nlowest dirty index\nsupplies the line",
        "#ffffff", VIOLET, 7.4)

    box(ax, 0.398, 0.348, 0.150, 0.128,
        "transaction FSM\n\nidle - snoop\nc2c - memwr\nmemrd - memwt\ncommit\n\n"
        "commit is the single\nordering point", "#ffffff", AMBER, 7.4)

    box(ax, 0.569, 0.348, 0.168, 0.128,
        "intervention path\n\ndirty owner drives the\nline straight onto the bus\n"
        "(C2C_LAT cycles), the bus\nflushes it to memory in the\n"
        "same transaction", "#ffffff", TEAL, 7.2)

    box(ax, 0.758, 0.348, 0.177, 0.128,
        "commit actions\n\nBusRd   -> sharers to S,\n            filler S or E\n"
        "BusRdX  -> sharers to I\nBusUpgr -> sharers to I,\n            no data moves\n"
        "BusWB   -> victim to I", "#ffffff", GREEN, 7.2)

    for a, b in [(0.193, 0.214), (0.377, 0.398), (0.548, 0.569), (0.737, 0.758)]:
        arrow(ax, (a, 0.412), (b, 0.412), AMBER)

    ax.text(0.4915, 0.283,
            "no snoop can interleave with a granted transaction, so a cache only "
            "races between deciding what it wants and winning the bus - which is "
            "exactly what the two race guards above cover",
            ha="center", fontsize=7.4, color=MUTED, style="italic")

    # -- memory -------------------------------------------------------------
    box(ax, 0.335, 0.075, 0.31, 0.115,
        "backing memory port\n\nreq / we / line / wdata  ->  ready, rvalid, rdata\n"
        "line granular, %d bits\n\n"
        "read only when no cache can supply the line;\n"
        "written on every writeback and every dirty snoop" % LINE_W,
        "#f0fdfa", TEAL, 7.6)
    arrow(ax, (0.44, 0.245), (0.44, 0.190), TEAL)
    arrow(ax, (0.545, 0.190), (0.545, 0.245), TEAL)

    # -- protocol legend ----------------------------------------------------
    box(ax, 0.028, 0.075, 0.28, 0.115, "", "#ffffff", INK, 8)
    ax.text(0.168, 0.174, "invariants held by construction", ha="center",
            fontsize=8.4, color=INK, fontweight="bold")
    for k, txt in enumerate([
            "I1  at most one M or E copy per line",
            "I2  an M or E copy is the only valid copy",
            "I3  memory is stale only while a copy is M"]):
        ax.text(0.040, 0.146 - k * 0.024, txt, fontsize=7.4, color=MUTED,
                family="monospace")

    box(ax, 0.672, 0.075, 0.283, 0.115, "", "#ffffff", INK, 8)
    ax.text(0.8135, 0.174, "why MESI beats MSI", ha="center",
            fontsize=8.4, color=INK, fontweight="bold")
    for k, txt in enumerate([
            "read miss with no sharer  -> fill E",
            "store to E                -> M, zero bus cycles",
            "store to S                -> BusUpgr, no data moved"]):
        ax.text(0.684, 0.146 - k * 0.024, txt, fontsize=7.0, color=MUTED,
                family="monospace")

    fig.subplots_adjust(left=0.008, right=0.992, top=0.935, bottom=0.012)
    out = DOCS / "mesi_snoop_coherence_block.png"
    fig.savefig(out, dpi=125)
    plt.close(fig)
    print("wrote", out)


if __name__ == "__main__":
    diagram()
    waveform()
