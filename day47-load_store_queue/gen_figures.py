#!/usr/bin/env python3
"""Generate the Day 47 circuit diagram and the waveform plot.

The waveform is rendered from the real VCD produced by the Icarus run
(`make icarus` writes lsq_disambiguation.vcd), not hand-modelled.  The
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

LQ_DEPTH, SQ_DEPTH, ADDR_W, DATA_W, ROB_W = 8, 8, 12, 32, 6
NB = DATA_W // 8
LQ_AW, SQ_AW = 3, 3
LPTR_W, SPTR_W = LQ_AW + 2, SQ_AW + 2
WOFF = 2

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
    n = len(s)
    chunk = s[n - 1 - hi:n - lo]
    if any(c in chunk for c in "xz"):
        return None
    return int(chunk, 2)


def integer(series, t, width=32):
    return field(bits(series, t, width), width - 1, 0)


# ---------------------------------------------------------------------------
# Waveform figure - the memory-order violation and its recovery (phase 7)
# ---------------------------------------------------------------------------
RSN = {0: "no-data", 1: "partial", 2: "port", 3: "kill"}


def waveform():
    vcd = HERE / "lsq_disambiguation.vcd"
    if not vcd.exists():
        raise SystemExit("lsq_disambiguation.vcd not found - run `make icarus` first")
    ch = parse_vcd(vcd)

    sig = {n: find(ch, n) for n in [
        "clk", "phase_id",
        "disp_valid_i", "disp_is_store_i",
        "ag_valid_i", "ag_is_store_i", "ag_idx_i", "ag_addr_i",
        "sd_valid_i", "sd_idx_i",
        "ld_wb_valid_o", "ld_wb_data_o", "ld_wb_fwd_o", "ld_wb_spec_o",
        "ld_replay_o", "ld_replay_rsn_o",
        "viol_valid_o", "viol_idx_o",
        "dmem_req_o", "dmem_we_o", "dmem_addr_o",
        "commit_load_i", "commit_store_i",
        "lq_cnt_o", "sq_cnt_o",
        "cnt_spec_o", "cnt_viol_o", "cnt_fwd_o", "cnt_ld_exec_o"]}

    edges = [t for t, v in sig["clk"] if v == "1"]

    # Anchor on the violation inside phase 7: a load speculates past a store
    # whose address has not been computed yet, and the store then lands on it.
    anchor = None
    for i, t in enumerate(edges):
        s = t - 1
        if (integer(sig["phase_id"], s, 32) == 7
                and integer(sig["viol_valid_o"], s, 1) == 1):
            anchor = i
            break
    if anchor is None:
        raise SystemExit("could not locate the phase-7 violation in the VCD")

    start = max(0, anchor - 12)
    edges = edges[start:start + 22]
    times = [t - 1 for t in edges]
    n = len(times)

    def disp_txt(t):
        if integer(sig["disp_valid_i"], t, 1) != 1:
            return ""
        return "store" if integer(sig["disp_is_store_i"], t, 1) == 1 else "load"

    def ag_txt(t):
        if integer(sig["ag_valid_i"], t, 1) != 1:
            return ""
        st = integer(sig["ag_is_store_i"], t, 1) == 1
        idx = integer(sig["ag_idx_i"], t, SQ_AW)
        addr = integer(sig["ag_addr_i"], t, ADDR_W)
        kind = "STA" if st else "LD"
        return "%s %d\nw%d" % (kind, idx, addr >> WOFF)

    def sd_txt(t):
        if integer(sig["sd_valid_i"], t, 1) != 1:
            return ""
        return "STD %d" % integer(sig["sd_idx_i"], t, SQ_AW)

    def wb_txt(t):
        if integer(sig["ld_wb_valid_o"], t, 1) != 1:
            return ""
        d = integer(sig["ld_wb_data_o"], t, DATA_W)
        return "%08x" % d if d is not None else "?"

    def wb_flag(name):
        def fn(t, name=name):
            if integer(sig["ld_wb_valid_o"], t, 1) != 1:
                return ""
            return "yes" if integer(sig[name], t, 1) == 1 else "-"
        return fn

    def rp_txt(t):
        if integer(sig["ld_replay_o"], t, 1) != 1:
            return ""
        return RSN.get(integer(sig["ld_replay_rsn_o"], t, 2), "?")

    def viol_txt(t):
        if integer(sig["viol_valid_o"], t, 1) != 1:
            return ""
        return "LQ%d" % integer(sig["viol_idx_o"], t, LQ_AW)

    def mem_txt(t):
        if integer(sig["dmem_req_o"], t, 1) != 1:
            return ""
        a = integer(sig["dmem_addr_o"], t, ADDR_W)
        rw = "WR" if integer(sig["dmem_we_o"], t, 1) == 1 else "RD"
        return "%s w%d" % (rw, a >> WOFF)

    def com_txt(t):
        if integer(sig["commit_load_i"], t, 1) == 1:
            return "load"
        if integer(sig["commit_store_i"], t, 1) == 1:
            return "store"
        return ""

    rows = [
        ("clk",                "clk",  None, INK),
        ("dispatch",           "text", disp_txt, BLUE),
        ("agu / sta port",     "text", ag_txt, BLUE),
        ("store-data port",    "text", sd_txt, BLUE),
        ("lq_cnt",             "dec",  lambda t: integer(sig["lq_cnt_o"], t, LPTR_W), MUTED),
        ("sq_cnt",             "dec",  lambda t: integer(sig["sq_cnt_o"], t, SPTR_W), MUTED),
        ("dmem port",          "text", mem_txt, TEAL),
        ("ld_wb_data_o",       "text", wb_txt, GREEN),
        ("ld_wb_fwd_o",        "text", wb_flag("ld_wb_fwd_o"), GREEN),
        ("ld_wb_spec_o",       "text", wb_flag("ld_wb_spec_o"), AMBER),
        ("ld_replay_o",        "text", rp_txt, AMBER),
        ("viol_valid_o",       "text", viol_txt, RED),
        ("commit",             "text", com_txt, VIOLET),
        ("cnt_ld_exec",        "dec",  lambda t: integer(sig["cnt_ld_exec_o"], t), MUTED),
        ("cnt_spec",           "dec",  lambda t: integer(sig["cnt_spec_o"], t), AMBER),
        ("cnt_fwd",            "dec",  lambda t: integer(sig["cnt_fwd_o"], t), GREEN),
        ("cnt_viol",           "dec",  lambda t: integer(sig["cnt_viol_o"], t), RED),
    ]

    fig, ax = plt.subplots(figsize=(15.5, 8.9))
    ax.set_xlim(-5.6, n - 0.25)
    ax.set_ylim(-0.6, len(rows) + 1.1)
    ax.axis("off")
    fig.suptitle("Day 47 - LSQ: speculative disambiguation, memory-order "
                 "violation and recovery, real captured Icarus VCD",
                 fontsize=14.5, fontweight="bold", y=0.985)
    fig.text(0.5, 0.940,
             "Stimulus phase 7.  A store to w40 is dispatched first but its address generation is delayed; the younger load to w40 executes long before the machine\n"
             "knows where that store is going.  The load finds an older store with no address, refuses to wait, reads memory and writes back with ld_wb_spec_o set -\n"
             "recording a disambiguation barrier as it goes.  When STA finally lands on the store queue the violation CAM finds that executed younger load sitting above\n"
             "its barrier and raises viol_valid_o, naming the load queue entry.  No ROB flush is applied here: the LSU un-executes the load itself, the replay arbiter\n"
             "re-issues it, and this time the store's address and data are both present, so it forwards out of the store queue (cnt_fwd increments) and commits correct.",
             ha="center", va="top", fontsize=8.8, color=MUTED, linespacing=1.55)

    for x in range(n):
        ax.axvline(x, color=GRID, lw=0.7)
        if x % 2 == 0:
            ax.text(x, len(rows) + 0.42, str(x), ha="center", fontsize=7, color=MUTED)
    ax.text(-5.35, len(rows) + 0.42, "cycle", fontsize=8, color=MUTED)

    for ri, (label, kind, fn, color) in enumerate(rows):
        y = len(rows) - ri - 1
        ax.text(-5.35, y + 0.42, label, ha="left", va="center",
                family="monospace", fontsize=8.6, color=color)
        ax.axhline(y, color=GRID, lw=0.6)

        if kind == "clk":
            for x in range(n):
                ax.plot([x - 0.48, x - 0.48, x, x, x + 0.48],
                        [y + 0.12, y + 0.78, y + 0.78, y + 0.12, y + 0.12],
                        color=color, lw=1.3)
            continue

        for x, t in enumerate(times):
            v = fn(t)
            txt = ("" if v is None else str(v)) if kind == "dec" else (v or "")
            if txt == "":
                continue
            filled = txt not in ("0", "-")
            ax.add_patch(Rectangle((x - 0.46, y + 0.14), 0.92, 0.64,
                                   facecolor=color if filled else "white",
                                   alpha=0.16 if filled else 1.0,
                                   edgecolor=color, lw=0.9))
            ax.text(x, y + 0.46, txt, ha="center", va="center",
                    family="monospace", fontsize=6.2, color=color,
                    linespacing=1.15)

    fig.subplots_adjust(left=0.004, right=0.997, top=0.818, bottom=0.015)
    out = DOCS / "lsq_disambiguation_waveform.png"
    fig.savefig(out, dpi=125)
    plt.close(fig)
    print("wrote", out)


# ---------------------------------------------------------------------------
# Circuit / dataflow diagram
# ---------------------------------------------------------------------------
def box(ax, x, y, w, h, label, fc, ec, fs=9, tc=None, weight="bold"):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                                boxstyle="round,pad=0.004,rounding_size=0.03",
                                facecolor=fc, edgecolor=ec, lw=1.3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=tc or ec, fontweight=weight, linespacing=1.35)


def arrow(ax, p, q, color, lw=1.3, style="-|>", ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=style, color=color, lw=lw,
                                 linestyle=ls, mutation_scale=11,
                                 connectionstyle="arc3,rad=%g" % rad,
                                 shrinkA=1, shrinkB=1))




def block(ax, x, y, w, h, title, color, face="#f8fafc"):
    """Outer group box with its title on the top edge."""
    box(ax, x, y, w, h, "", face, color, 8)
    ax.text(x + w / 2, y + h - 0.026, title, ha="center", va="center",
            fontsize=9.4, color=color, fontweight="bold")


def diagram():
    fig, ax = plt.subplots(figsize=(18, 10.6))
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    fig.suptitle("Day 47 - Out-of-Order Load/Store Queue with Store-to-Load "
                 "Forwarding and Speculative Disambiguation: circuit diagram",
                 fontsize=15.0, fontweight="bold", y=0.976)
    ax.text(0.5, 0.956,
            "allocate in program order, execute in address-arrival order, "
            "retire in program order - the two CAMs are what hold that together",
            transform=ax.transAxes, ha="center", fontsize=9.6, color=MUTED)

    # =====================================================================
    #  Row A - external ports, feeding a distribution bus
    # =====================================================================
    ports = [
        (0.020, 0.152, BLUE,   "#eff6ff",
         "dispatch  (program order)\nvalid / lq_ready / sq_ready\nrob tag, is_store"),
        (0.182, 0.150, BLUE,   "#eff6ff",
         "address generation  (STA)\nvalid, is_store, idx\naddr, byte enables"),
        (0.344, 0.140, BLUE,   "#eff6ff",
         "store data  (STD)\nvalid, idx, data\nindependent of STA"),
        (0.496, 0.150, VIOLET, "#f5f3ff",
         "commit  (program order)\ncommit_load / commit_store\nfrom the ROB"),
        (0.658, 0.176, RED,    "#fef2f2",
         "flush / rollback\nflush_lq_tail, flush_sq_tail\ncheckpointed at dispatch"),
        (0.846, 0.134, MUTED,  "#ffffff",
         "counters  12 x 32b\nqueue occupancy\nhead-ready flags"),
    ]
    for x, w, col, face, text in ports:
        box(ax, x, 0.876, w, 0.058, text, face, col, 7.2, weight="normal")
        arrow(ax, (x + w / 2, 0.876), (x + w / 2, 0.866), col, lw=1.1)

    ax.plot([0.045, 0.955], [0.862, 0.862], color=MUTED, lw=1.6)
    ax.text(0.5, 0.850, "dispatch allocates in both queues; a flush rolls both "
                        "tails back; commit advances both heads",
            ha="center", fontsize=6.8, color=MUTED, style="italic")

    for x in (0.165, 0.495, 0.830):
        arrow(ax, (x, 0.862), (x, 0.840), MUTED, lw=1.1)

    # =====================================================================
    #  Row B - the two queues and the store CAM between them
    # =====================================================================
    block(ax, 0.020, 0.535, 0.290, 0.300,
          "LOAD QUEUE  -  %d entries, age-ordered ring" % LQ_DEPTH, BLUE)
    box(ax, 0.032, 0.640, 0.266, 0.148,
        "per entry\n\n"
        "val  aval  addr  be  rob      allocated / resolved\n"
        "exec  data  fwd  spec         result state\n"
        "snap = sq_tail at dispatch    age boundary\n"
        "ord  = disambiguation barrier who may violate me\n"
        "rpend  rrsn  blk              asleep, and on what",
        "#eff6ff", BLUE, 6.5, weight="normal")
    box(ax, 0.032, 0.582, 0.128, 0.050,
        "lq_head / lq_tail\n%d-bit ring pointers" % LPTR_W,
        "#ffffff", MUTED, 6.5, weight="normal")
    box(ax, 0.170, 0.582, 0.128, 0.050,
        "replay arbiter\noldest woken entry",
        "#fffbeb", AMBER, 6.8, weight="normal")
    box(ax, 0.032, 0.547, 0.266, 0.030,
        "wake:  no-data -> that store's STD   |   partial -> that store drains\n"
        "port / kill -> retry at once",
        "#ffffff", AMBER, 6.2, weight="normal")

    block(ax, 0.330, 0.535, 0.330, 0.300,
          "STORE CAM  -  a load in S0 against the store queue", VIOLET, "#ffffff")
    box(ax, 0.342, 0.614, 0.306, 0.174,
        "walk the age window  [ sq_head , load.snap )\n"
        "from YOUNGEST to OLDEST\n\n"
        "first overlapping store with a known address wins\n"
        "     overlap = same word  AND  (store.be & load.be)\n"
        "     full    = (store.be & load.be) == load.be\n\n"
        "any unknown-address store seen BEFORE that match\n"
        "is one this load is about to speculate past\n\n"
        "the STA and STD ports are bypassed into the walk,\n"
        "so a store resolving this very cycle is not missed",
        "#f5f3ff", VIOLET, 6.6, weight="normal")
    box(ax, 0.342, 0.547, 0.306, 0.058,
        "verdict out:  forward data + coverage  |  replay + reason\n"
        "speculative flag  |  disambiguation barrier  ord",
        "#ffffff", VIOLET, 6.6, weight="normal")

    block(ax, 0.680, 0.535, 0.300, 0.300,
          "STORE QUEUE  -  %d entries, age-ordered ring" % SQ_DEPTH, GREEN)
    box(ax, 0.692, 0.640, 0.276, 0.148,
        "per entry\n\n"
        "val              allocated at dispatch\n"
        "aval  addr  be   filled by STA\n"
        "dval  data       filled by STD, separately\n\n"
        "an entry keeps forwarding until it is popped,\n"
        "which happens after commit, not at commit",
        "#f0fdf4", GREEN, 6.5, weight="normal")
    box(ax, 0.692, 0.582, 0.276, 0.050,
        "sq_head   <=   sq_commit   <=   sq_tail\n"
        "popped         retired          allocated",
        "#ffffff", MUTED, 6.5, weight="normal")
    box(ax, 0.692, 0.547, 0.276, 0.030,
        "committed stores are never flushed -\n"
        "they sit below every checkpoint",
        "#ffffff", GREEN, 6.2, weight="normal")

    # =====================================================================
    #  Row C - violation CAM, the load pipeline, the memory port
    # =====================================================================
    block(ax, 0.020, 0.278, 0.290, 0.242,
          "VIOLATION CAM", RED, "#ffffff")
    box(ax, 0.032, 0.396, 0.266, 0.080,
        "driven by a store address arriving on STA\n\n"
        "scan the load queue for an entry that is\n"
        "younger + executed + overlapping + at or\n"
        "above its barrier;  report the OLDEST",
        "#fef2f2", RED, 6.6, weight="normal")
    box(ax, 0.032, 0.288, 0.266, 0.096,
        "recovery, done twice over\n\n"
        "viol_valid + rob tag  ->  the ROB flushes\n"
        "and re-dispatches, because dependents have\n"
        "already consumed the bad value\n\n"
        "and internally: un-execute the victim and\n"
        "every younger load, so the value that\n"
        "finally commits is right even with no flush",
        "#ffffff", RED, 6.4, weight="normal")

    block(ax, 0.330, 0.278, 0.330, 0.242, "LOAD PIPELINE", AMBER)
    box(ax, 0.342, 0.404, 0.306, 0.072,
        "S0   source select, CAM lookup, memory issue\n"
        "a fresh AGU load beats a woken replay\n"
        "memory is requested only if the CAM cannot\n"
        "cover the load on its own",
        "#fffbeb", AMBER, 6.8, weight="normal")
    box(ax, 0.342, 0.344, 0.306, 0.052,
        "S1   result select\n"
        "per-byte mux: store bytes vs memory bytes\n"
        "killed if an STA landed on this load's bytes",
        "#fffbeb", AMBER, 6.8, weight="normal")
    box(ax, 0.342, 0.288, 0.306, 0.046,
        "writeback   ld_wb_data / _be / _fwd / _spec\n"
        "ld_replay + reason",
        "#f0fdf4", GREEN, 6.8, weight="normal")

    block(ax, 0.680, 0.278, 0.300, 0.242,
          "MEMORY PORT  -  one access per cycle", TEAL)
    box(ax, 0.692, 0.404, 0.276, 0.072,
        "arbiter\nloads win by default;  the drain pre-empts\n"
        "when the store queue is full or it has\n"
        "waited URGENT cycles.  A load that loses\n"
        "the port replays instead of stalling S0",
        "#f0fdfa", TEAL, 6.6, weight="normal")
    box(ax, 0.692, 0.344, 0.276, 0.052,
        "store drain engine\npops sq_head once it is below sq_commit,\n"
        "one committed store per cycle",
        "#f0fdfa", TEAL, 6.6, weight="normal")
    box(ax, 0.692, 0.288, 0.276, 0.046,
        "data memory\nreq / we / addr / be / wdata -> rdata\n"
        "single-cycle synchronous read",
        "#ffffff", INK, 6.6, weight="normal")

    # =====================================================================
    #  Arrows
    # =====================================================================
    arrow(ax, (0.310, 0.700), (0.330, 0.700), BLUE)        # LQ  -> store CAM
    arrow(ax, (0.680, 0.700), (0.660, 0.700), GREEN)       # SQ  -> store CAM
    arrow(ax, (0.495, 0.535), (0.495, 0.482), VIOLET)      # CAM -> S0
    arrow(ax, (0.495, 0.404), (0.495, 0.398), AMBER)       # S0  -> S1
    arrow(ax, (0.495, 0.344), (0.495, 0.338), AMBER)       # S1  -> writeback
    arrow(ax, (0.298, 0.607), (0.344, 0.466), AMBER, rad=-0.20)   # arbiter -> S0
    arrow(ax, (0.342, 0.300), (0.234, 0.580), AMBER, rad=-0.28)   # replay  -> arbiter
    arrow(ax, (0.165, 0.520), (0.165, 0.535), RED)         # squash  -> LQ
    arrow(ax, (0.310, 0.436), (0.330, 0.436), RED)         # viol CAM-> pipeline
    arrow(ax, (0.660, 0.440), (0.680, 0.440), TEAL)        # S0  -> arbiter
    arrow(ax, (0.680, 0.356), (0.660, 0.362), TEAL)        # rdata -> S1
    arrow(ax, (0.830, 0.535), (0.830, 0.482), GREEN)       # SQ  -> drain
    arrow(ax, (0.830, 0.404), (0.830, 0.398), TEAL)        # arb -> drain
    arrow(ax, (0.830, 0.344), (0.830, 0.338), TEAL)        # drain -> memory

    # =====================================================================
    #  Row D - the two explanation panels
    # =====================================================================
    box(ax, 0.020, 0.020, 0.470, 0.238, "", "#ffffff", INK, 8)
    ax.text(0.255, 0.238, "what a load in S0 decides, in one cycle",
            ha="center", fontsize=8.6, color=INK, fontweight="bold")
    for k, txt in enumerate([
            "youngest overlapping older store, covers every requested",
            "  byte, data has arrived        -> FORWARD, no memory read",
            "overlap but not full coverage   -> replay: partial",
            "full coverage but no data yet   -> replay: no-data",
            "no overlap, an older store has no address yet",
            "                                -> SPECULATE, record barrier",
            "no overlap, every older address known -> plain memory read",
            "wanted memory, the drain took the port -> replay: port"]):
        ax.text(0.034, 0.211 - k * 0.0235, txt, fontsize=6.9, color=MUTED,
                family="monospace")

    box(ax, 0.510, 0.020, 0.470, 0.238, "", "#ffffff", INK, 8)
    ax.text(0.745, 0.238, "why the barrier makes the violation check exact",
            ha="center", fontsize=8.6, color=INK, fontweight="bold")
    for k, txt in enumerate([
            "a load that forwarded from store P is wrong only if a store",
            "BETWEEN P and itself later resolves onto its bytes",
            "                                       -> barrier = P + 1",
            "a load that forwarded from nothing can be wrong about any",
            "older store                            -> barrier = sq_head",
            "",
            "a store older than the barrier is already hidden by P and must",
            "NOT raise a violation.  Drop the barrier and the checker starts",
            "reporting loads that were never speculative in the first place."]):
        ax.text(0.524, 0.211 - k * 0.0235, txt, fontsize=6.9, color=MUTED,
                family="monospace")

    fig.subplots_adjust(left=0.008, right=0.992, top=0.940, bottom=0.012)
    out = DOCS / "lsq_disambiguation_block.png"
    fig.savefig(out, dpi=125)
    plt.close(fig)
    print("wrote", out)


if __name__ == "__main__":
    diagram()
    waveform()
