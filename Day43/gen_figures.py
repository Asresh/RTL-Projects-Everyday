#!/usr/bin/env python3
"""Generate the Day 43 circuit diagram and a waveform plot.

The waveform is rendered from the real VCD produced by the Icarus run
(`make icarus` writes noc_vc_router.vcd), not hand-modelled.
"""
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

HERE = Path(__file__).resolve().parent
DOCS = HERE / "docs"
DOCS.mkdir(exist_ok=True)

PORTS, VCS, BUF_DEPTH = 5, 2, 4
CNTW = 3
NVC = PORTS * VCS
PORT_NAMES = ["N", "E", "S", "W", "L"]

INK    = "#1e293b"
MUTED  = "#64748b"
GRID   = "#e2e8f0"
BLUE   = "#0369a1"
VIOLET = "#7c3aed"
GREEN  = "#15803d"
AMBER  = "#b45309"
RED    = "#be123c"


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
STATE_NAME = {0: "IDLE", 1: "ROUTED", 2: "ACTIVE", 3: "?"}
FTYPE_NAME = {0: "BODY", 1: "HEAD", 2: "TAIL", 3: "H+T"}


def waveform():
    vcd = HERE / "noc_vc_router.vcd"
    if not vcd.exists():
        raise SystemExit("noc_vc_router.vcd not found - run `make icarus` first")
    ch = parse_vcd(vcd)

    sig = {n: find(ch, n) for n in [
        "clk", "rst_n", "in_valid", "in_flit", "out_valid", "out_vc", "out_flit",
        "dbg_state", "dbg_occupancy", "dbg_credit", "dbg_ovc_busy",
        "perf_flits", "perf_packets"]}

    edges = [t for t, v in sig["clk"] if v == "1"]

    # Locate test T2: the first cycle the WEST input port (bit 3) is driven.
    # That packet is a 4-flit wormhole from WEST to (2,4), i.e. out on NORTH.
    WEST, NORTH = 3, 0
    start = None
    for i, t in enumerate(edges):
        iv = bits(sig["in_valid"], t - 1, PORTS)
        if "x" not in iv and field(iv, WEST, WEST) == 1:
            start = max(0, i - 3)
            break
    if start is None:
        raise SystemExit("could not locate the WEST injection in the VCD")

    edges = edges[start:start + 20]
    times = [t - 1 for t in edges]
    n = len(times)

    def st_of(t, pv):
        return field(bits(sig["dbg_state"], t, NVC * 2), pv * 2 + 1, pv * 2)

    def occ_of(t, pv):
        return field(bits(sig["dbg_occupancy"], t, NVC * CNTW),
                     pv * CNTW + CNTW - 1, pv * CNTW)

    def cred_of(t, pv):
        return field(bits(sig["dbg_credit"], t, NVC * CNTW),
                     pv * CNTW + CNTW - 1, pv * CNTW)

    def flit_of(series, t, port):
        return field(bits(series, t, PORTS * 32), port * 32 + 31, port * 32)

    def render_flit(v):
        if v is None:
            return ""
        return "%s %06x" % (FTYPE_NAME[(v >> 30) & 3], v & 0x3FFFFFFF)

    # A flit bus holds its last value in the VCD long after the transfer, so
    # rows that are only meaningful during a handshake are gated by their valid
    # bit and left blank otherwise.
    def in_active(t):
        return field(bits(sig["in_valid"], t, PORTS), WEST, WEST) == 1

    def out_active(t):
        return field(bits(sig["out_valid"], t, PORTS), NORTH, NORTH) == 1

    rows = [
        ("clk",                  "clk",  None, INK, None),
        ("rst_n",                "bit",  lambda t: integer(sig["rst_n"], t, 1), RED, None),
        ("in_valid {L,W,S,E,N}", "bin",  lambda t: bits(sig["in_valid"], t, PORTS), BLUE, None),
        ("in_flit  W",           "flit", lambda t: flit_of(sig["in_flit"], t, WEST), BLUE, in_active),
        ("W.vc0 state",          "text", lambda t: STATE_NAME.get(st_of(t, WEST * VCS), ""), VIOLET, None),
        ("W.vc0 occupancy",      "dec",  lambda t: occ_of(t, WEST * VCS), VIOLET, None),
        ("ovc_busy (10 out VCs)", "bin", lambda t: bits(sig["dbg_ovc_busy"], t, NVC), VIOLET, None),
        ("out_valid {L,W,S,E,N}", "bin", lambda t: bits(sig["out_valid"], t, PORTS), GREEN, None),
        ("out_vc   N",           "dec",  lambda t: field(bits(sig["out_vc"], t, PORTS), NORTH, NORTH), GREEN, out_active),
        ("out_flit N",           "flit", lambda t: flit_of(sig["out_flit"], t, NORTH), GREEN, out_active),
        ("credit N.vc0",         "dec",  lambda t: cred_of(t, NORTH * VCS), AMBER, None),
        ("perf_flits_o",         "dec",  lambda t: integer(sig["perf_flits"], t), RED, None),
        ("perf_packets_o",       "dec",  lambda t: integer(sig["perf_packets"], t), RED, None),
    ]

    fig, ax = plt.subplots(figsize=(19, 9.0))
    ax.set_xlim(-6.4, n - 0.25)
    ax.set_ylim(-0.9, len(rows) + 1.1)
    ax.axis("off")
    fig.suptitle("Day 43 - Wormhole VC NoC Router: real captured Icarus VCD",
                 fontsize=15, fontweight="bold", y=0.985)
    ax.text(0.5, 1.02,
            "4-flit packet enters WEST vc0 bound for (2,4): RC computes NORTH, "
            "VA claims an output VC, then head/body/body/tail stream out of NORTH "
            "back to back as credits are spent",
            transform=ax.transAxes, ha="center", fontsize=9.5, color=MUTED)

    for x in range(n):
        ax.axvline(x, color=GRID, lw=0.7)
        ax.text(x, len(rows) + 0.38, str(x), ha="center", fontsize=7, color=MUTED)
    ax.text(-6.1, len(rows) + 0.38, "cycle", fontsize=8, color=MUTED)

    for ri, (label, kind, fn, color, gate) in enumerate(rows):
        y = len(rows) - ri - 1
        ax.text(-6.1, y + 0.42, label, ha="left", va="center",
                family="monospace", fontsize=8.4, color=color)
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

        # bussed rows: draw a hexagon-ish cell per cycle with the decoded text
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
            elif kind == "text":
                txt = v or ""
            else:  # flit
                txt = render_flit(v)
            if txt in ("", None):
                continue
            filled = txt not in ("00000", "0000000000", "IDLE", "0")
            ax.add_patch(Rectangle((x - 0.46, y + 0.14), 0.92, 0.64,
                                   facecolor=color if filled else "white",
                                   alpha=0.16 if filled else 1.0,
                                   edgecolor=color, lw=0.9))
            ax.text(x, y + 0.46, txt, ha="center", va="center",
                    family="monospace", fontsize=6.6, color=color)

    fig.tight_layout(rect=(0, 0.02, 1, 0.94))
    out = DOCS / "noc_vc_router_waveform.png"
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
    fig, ax = plt.subplots(figsize=(17.5, 10.2))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    ax.text(0.5, 0.962, "Day 43 - 5-Port Wormhole Virtual-Channel NoC Router",
            transform=ax.transAxes, ha="center", fontsize=16,
            fontweight="bold", color=INK)
    ax.text(0.5, 0.918,
            "input-buffered - 2 virtual channels per port - XY routing - "
            "separable VC + 2-stage switch allocation - credit-based flow control",
            transform=ax.transAxes, ha="center", fontsize=10, color=MUTED)

    # ---- input ports ------------------------------------------------------
    ys = [0.735, 0.605, 0.475, 0.345, 0.215]
    ax.text(0.1155, 0.862, "INPUT PORTS", fontsize=9.5, color=MUTED,
            fontweight="bold", ha="center")
    for name, y in zip(PORT_NAMES, ys):
        ax.text(0.018, y + 0.042, name, fontsize=11, color=INK,
                fontweight="bold", ha="center", va="center")
        arrow(ax, (0.033, y + 0.042), (0.058, y + 0.042), BLUE, lw=1.6)
        box(ax, 0.058, y + 0.044, 0.115, 0.038,
            "vc0  FIFO x%d" % BUF_DEPTH, "#e0f2fe", BLUE, fs=7.6)
        box(ax, 0.058, y, 0.115, 0.038,
            "vc1  FIFO x%d" % BUF_DEPTH, "#e0f2fe", BLUE, fs=7.6)

    ax.text(0.1155, 0.112,
            "10 independent input VCs, each with its own\n"
            "wormhole FSM:  IDLE -> ROUTED -> ACTIVE",
            fontsize=7.4, color=MUTED, ha="center", va="top", linespacing=1.6)

    # ---- flit datapath: collector bus over the top into the crossbar -------
    BUSX, BUSY = 0.193, 0.815
    for y in ys:
        ax.plot([0.173, BUSX], [y + 0.021, y + 0.021], color=BLUE, lw=1.0)
    ax.plot([BUSX, BUSX], [ys[-1] + 0.021, BUSY], color=BLUE, lw=2.2)
    ax.plot([BUSX, 0.6525], [BUSY, BUSY], color=BLUE, lw=2.2)
    arrow(ax, (0.6525, BUSY), (0.6525, 0.742), BLUE, lw=2.2)
    ax.text(0.425, BUSY + 0.014,
            "flit datapath:  granted buffer read -> crossbar input",
            fontsize=8, color=BLUE, ha="center")

    # ---- route computation -------------------------------------------------
    box(ax, 0.235, 0.335, 0.115, 0.395,
        "ROUTE\nCOMPUTE\n(RC)\n\ndimension-order\nXY\n\n"
        "dx>x : EAST\ndx<x : WEST\ndy>y : NORTH\ndy<y : SOUTH\nelse : LOCAL",
        "#f5f3ff", VIOLET, fs=7.8, weight="normal")
    ax.text(0.2925, 0.745, "stage 1", fontsize=8, color=VIOLET,
            ha="center", fontweight="bold")
    arrow(ax, (BUSX, 0.533), (0.235, 0.533), VIOLET, lw=1.2)
    ax.text(0.214, 0.547, "head flit", fontsize=6.6, color=VIOLET,
            ha="center")

    # ---- VC allocator ------------------------------------------------------
    box(ax, 0.385, 0.545, 0.155, 0.185,
        "VC ALLOCATOR\n(VA)\n\nrotating priority over\nall 10 input VCs;\n"
        "one grant per output VC\nper cycle",
        "#f5f3ff", VIOLET, fs=7.8, weight="normal")
    ax.text(0.4625, 0.745, "stage 2", fontsize=8, color=VIOLET,
            ha="center", fontweight="bold")
    arrow(ax, (0.350, 0.615), (0.385, 0.630), VIOLET)

    box(ax, 0.385, 0.450, 0.155, 0.060,
        "ovc_busy[10]   output-VC ownership", "#ede9fe", VIOLET, fs=7.4,
        weight="normal")
    arrow(ax, (0.4625, 0.545), (0.4625, 0.512), VIOLET, style="<|-|>", lw=1.0)

    # ---- switch allocator --------------------------------------------------
    box(ax, 0.385, 0.212, 0.155, 0.188,
        "SWITCH ALLOCATOR\n(SA, separable)\n\n"
        "stage 1: one VC per input port\nstage 2: one input per output port\n\n"
        "both rotating priority\n=> conflict-free crossbar schedule",
        "#fff7ed", AMBER, fs=7.4, weight="normal")
    ax.text(0.4625, 0.415, "stage 3", fontsize=8, color=AMBER,
            ha="center", fontweight="bold")
    arrow(ax, (0.350, 0.372), (0.385, 0.345), AMBER, lw=1.0)

    # ---- credit counters ---------------------------------------------------
    box(ax, 0.385, 0.108, 0.155, 0.072,
        "CREDIT COUNTERS\ncredit[10], reset to %d\nbid only if non-zero"
        % BUF_DEPTH, "#fef2f2", RED, fs=7.4, weight="normal")
    arrow(ax, (0.4625, 0.180), (0.4625, 0.212), RED, lw=1.1)

    # ---- crossbar ----------------------------------------------------------
    box(ax, 0.585, 0.215, 0.135, 0.527, "", "#ecfdf5", GREEN)
    ax.text(0.6525, 0.700, "5 x 5\nCROSSBAR", ha="center", va="center",
            fontsize=10.5, color=GREEN, fontweight="bold", linespacing=1.3)
    ax.text(0.6525, 0.262,
            "up to 5 flits traverse\nper cycle  (ST stage)",
            ha="center", va="center", fontsize=7.6, color=MUTED,
            linespacing=1.6)
    for i in range(5):
        gy = 0.355 + i * 0.070
        ax.plot([0.598, 0.708], [gy, gy], color=GREEN, lw=0.7, alpha=0.55)
        gx = 0.606 + i * 0.0235
        ax.plot([gx, gx], [0.345, 0.645], color=GREEN, lw=0.7, alpha=0.55)

    arrow(ax, (0.540, 0.312), (0.585, 0.372), AMBER, lw=1.5)
    ax.text(0.553, 0.347, "grants", fontsize=7.4, color=AMBER, ha="center")

    # ---- output ports ------------------------------------------------------
    ax.text(0.8325, 0.862, "OUTPUT PORTS", fontsize=9.5, color=MUTED,
            fontweight="bold", ha="center")
    for name, y in zip(PORT_NAMES, ys):
        box(ax, 0.775, y + 0.008, 0.115, 0.066,
            "%s   out_valid\n     out_vc / out_flit" % name,
            "#ecfdf5", GREEN, fs=7.4, weight="normal")
        arrow(ax, (0.720, 0.478), (0.775, y + 0.041), GREEN, lw=0.85, rad=-0.07)
        arrow(ax, (0.890, y + 0.041), (0.918, y + 0.041), GREEN, lw=1.6)
        ax.text(0.935, y + 0.041, name, fontsize=11, color=INK,
                fontweight="bold", ha="center", va="center")

    # ---- credit return loops ------------------------------------------------
    ax.plot([0.9325, 0.9325], [0.190, 0.144], color=RED, lw=1.2,
            ls=(0, (4, 2)))
    ax.plot([0.9325, 0.556], [0.144, 0.144], color=RED, lw=1.2, ls=(0, (4, 2)))
    arrow(ax, (0.556, 0.144), (0.540, 0.144), RED, lw=1.2)
    ax.text(0.745, 0.158, "credit return from the downstream router",
            fontsize=7.8, color=RED, ha="center")

    ax.plot([0.385, 0.030], [0.144, 0.144], color=RED, lw=1.2, ls=(0, (4, 2)))
    ax.plot([0.030, 0.030], [0.144, 0.234], color=RED, lw=1.2, ls=(0, (4, 2)))
    arrow(ax, (0.030, 0.234), (0.058, 0.234), RED, lw=1.2)
    ax.text(0.250, 0.157, "credit return to the upstream router",
            fontsize=7.8, color=RED, ha="center")

    # ---- legend -------------------------------------------------------------
    ax.text(0.5, 0.018,
            "Pipeline:  BW/RC (route) -> VA (claim an output VC) -> SA/ST "
            "(win the crossbar and traverse).   "
            "Body and tail flits inherit the head's output port and VC and "
            "re-run only SA/ST, so a packet streams through without being "
            "stored whole - wormhole routing.",
            ha="center", fontsize=8.4, color=MUTED)

    out = DOCS / "noc_vc_router_block.png"
    fig.savefig(out, dpi=112, bbox_inches="tight")
    plt.close(fig)
    print("wrote", out)


if __name__ == "__main__":
    diagram()
    waveform()
