#!/usr/bin/env python3
"""Generate the Day 42 schematic and a waveform plot from the real Icarus VCD."""
from pathlib import Path
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

HERE = Path(__file__).resolve().parent
DOCS = HERE / "docs"
DOCS.mkdir(exist_ok=True)


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
                    name = ".".join(scopes + [p[4]])
                    names.setdefault(p[3], []).append(name)
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
    for name, series in changes.items():
        if name.endswith("." + suffix) or name == suffix:
            return series
    raise KeyError(suffix)


def value(series, t):
    answer = "x"
    for when, val in series:
        if when > t:
            break
        answer = val
    return answer


def integer(series, t):
    val = value(series, t)
    return None if any(c in val for c in "xz") else int(val, 2)


def waveform():
    changes = parse_vcd(HERE / "simt_operand_collector.vcd")
    sig = {name: find(changes, name) for name in [
        "clk", "rst_n", "req_valid_i", "req_ready_o", "req_warp_i", "req_tag_i",
        "req_src_valid_i", "req_src_reg_i", "dbg_busy_o", "dbg_pending_o",
        "issue_valid_o", "issue_ready_i", "issue_warp_o", "issue_tag_o",
        "issue_operand_o", "perf_bank_reads_o", "perf_reuse_hits_o",
        "perf_conflict_cycles_o"]}
    edges = [t for t, v in sig["clk"] if v == "1"]
    reset_edges = [i for i, t in enumerate(edges)
                   if i > 100 and integer(sig["rst_n"], t-1) == 0]
    start = max(0, reset_edges[0]-1)
    edges = edges[start:start+18]
    times = [t-1 for t in edges]

    rows = [
        ("clk", "clk", None, "#334155"),
        ("rst_n", "bit", "rst_n", "#dc2626"),
        ("req_valid", "bit", "req_valid_i", "#0369a1"),
        ("req_ready", "bit", "req_ready_o", "#0369a1"),
        ("req_warp", "dec", "req_warp_i", "#0369a1"),
        ("req_tag", "dec", "req_tag_i", "#0369a1"),
        ("src_valid", "bin3", "req_src_valid_i", "#0369a1"),
        ("src regs {s2,s1,s0}", "regs", "req_src_reg_i", "#0369a1"),
        ("collector busy", "bin4", "dbg_busy_o", "#7c3aed"),
        ("pending operands", "bin12", "dbg_pending_o", "#b45309"),
        ("issue_valid", "bit", "issue_valid_o", "#15803d"),
        ("issue_ready", "bit", "issue_ready_i", "#15803d"),
        ("issue_warp", "dec", "issue_warp_o", "#15803d"),
        ("issue_tag", "dec", "issue_tag_o", "#15803d"),
        ("operands {s2,s1,s0}", "ops", "issue_operand_o", "#15803d"),
        ("bank reads", "dec", "perf_bank_reads_o", "#be123c"),
        ("reuse hits", "dec", "perf_reuse_hits_o", "#be123c"),
        ("conflict bank-cycles", "dec", "perf_conflict_cycles_o", "#be123c"),
    ]
    fig, ax = plt.subplots(figsize=(19, 10.5))
    ax.set_xlim(-5.2, len(times)-0.25)
    ax.set_ylim(-0.8, len(rows)+1.0)
    ax.axis("off")
    fig.suptitle("Day 42 — SIMT Operand Collector: real captured Icarus VCD",
                 fontsize=15, fontweight="bold", y=.985)
    ax.text(.5, 1.015, "captured reset → bank-1 triple conflict serializes r1/r5/r9 → following request reuses r9/r5 while r2 takes one physical read",
            transform=ax.transAxes, ha="center", fontsize=9.5, color="#475569")
    for x in range(len(times)):
        ax.axvline(x, color="#e2e8f0", lw=.7)
        ax.text(x, len(rows)+.35, str(x), ha="center", fontsize=7, color="#64748b")
    ax.text(-4.9, len(rows)+.35, "cycle", fontsize=8, color="#64748b")
    for ri, (label, kind, key, color) in enumerate(rows):
        y = len(rows)-ri-1
        ax.text(-4.9, y+.42, label, ha="left", va="center", family="monospace",
                fontsize=8.3, color=color)
        ax.axhline(y, color="#e2e8f0", lw=.6)
        if kind == "clk":
            for x in range(len(times)):
                ax.plot([x-.48, x-.48, x, x, x+.48],
                        [y+.15, y+.75, y+.75, y+.15, y+.15], color=color, lw=1.2)
            continue
        vals = [integer(sig[key], t) for t in times]
        if kind == "bit":
            last = None
            for x, val in enumerate(vals):
                level = y + (.75 if val else .15)
                if last is not None and last != level:
                    ax.plot([x-.5, x-.5], [last, level], color=color, lw=1.5)
                ax.plot([x-.5, x+.5], [level, level], color=color, lw=1.7)
                if val:
                    ax.fill_between([x-.5, x+.5], y+.12, y+.78, color=color, alpha=.10)
                last = level
        else:
            prev = object()
            for x, val in enumerate(vals):
                if val == prev:
                    continue
                if kind.startswith("bin"):
                    width = int(kind[3:])
                    text = "x" if val is None else f"{val:0{width}b}"
                elif kind == "regs":
                    text = "x" if val is None else "/".join(str((val >> (5*k)) & 31) for k in (2,1,0))
                elif kind == "ops":
                    text = "x" if val is None else "/".join(f"{(val >> (32*k)) & 0xffffffff:08x}" for k in (2,1,0))
                else:
                    text = "x" if val is None else str(val)
                ax.text(x, y+.43, text, ha="center", va="center", fontsize=6.8,
                        family="monospace", color=color,
                        bbox=dict(boxstyle="round,pad=.16", fc="white", ec=color, lw=.7))
                prev = val
    ax.text(0, -.52, "Captured from simt_operand_collector.vcd — every signal and bus label above is parsed from the passing RTL simulation.",
            fontsize=8.5, color="#475569")
    fig.tight_layout(rect=[0, 0, 1, .97])
    fig.savefig(DOCS / "simt_operand_collector_waveform.png", dpi=180, bbox_inches="tight")
    plt.close(fig)


def schematic():
    fig, ax = plt.subplots(figsize=(18, 10.5))
    ax.set_xlim(0, 18); ax.set_ylim(0, 10.5); ax.axis("off")
    ink, blue, purple, amber, green, red = "#1e293b", "#0369a1", "#7c3aed", "#b45309", "#15803d", "#be123c"

    def box(x, y, w, h, text, edge, face="white", fs=9):
        ax.add_patch(FancyBboxPatch((x,y), w,h, boxstyle="round,pad=.12,rounding_size=.12",
                                   ec=edge, fc=face, lw=1.8))
        ax.text(x+w/2, y+h/2, text, ha="center", va="center", fontsize=fs,
                color=ink, linespacing=1.35)

    def arrow(x1,y1,x2,y2,color=ink,label=None):
        ax.add_patch(FancyArrowPatch((x1,y1),(x2,y2),arrowstyle="-|>",mutation_scale=13,
                                    lw=1.7,color=color))
        if label: ax.text((x1+x2)/2,(y1+y2)/2+.18,label,ha="center",fontsize=7.5,color=color)

    ax.text(9, 10.15, "Day 42 — SIMT Register-File Operand Collector", ha="center",
            fontsize=16, fontweight="bold", color=ink)
    ax.text(9, 9.78, "multi-warp buffering · bank arbitration · reuse bypass · backpressured issue",
            ha="center", fontsize=10, color="#64748b")
    box(.4, 7.5, 2.5, 1.45, "Warp scheduler\nrequest\nwarp · tag · rA/rB/rC", blue, "#f0f9ff")
    box(3.5, 6.8, 4.0, 2.8, "COLLECTOR POOL\n\n4 instruction slots\n3× {reg, pending, value}\nwarp + scoreboard tag\n\nready = no pending bits", purple, "#faf5ff")
    arrow(2.9,8.2,3.5,8.2,blue,"valid / ready")
    box(3.65, 4.85, 3.7, 1.15, "2-entry reuse cache / warp\n(tag compare + value bypass)", green, "#f0fdf4", 8.5)
    arrow(5.5,6.8,5.5,6.0,green,"hits clear pending at allocate")

    box(8.2, 6.8, 3.5, 2.8, "PER-BANK ARBITERS\n\n1 rotating grant / bank / cycle\ncollector × source request matrix\nconflicts serialize; banks parallel", amber, "#fffbeb")
    arrow(7.5,8.2,8.2,8.2,amber,"pending reads")
    for i in range(4):
        box(12.45, 8.78-i*.72, 2.1, .52, f"RF bank {i}", red, "#fff1f2", 8)
        arrow(11.7,8.98-i*.72,12.45,8.98-i*.72,red)
    box(15.1, 6.75, 2.45, 2.85, "Warped register file\n\nREG_COUNT × WARP_COUNT\nDATA_WIDTH-bit words\n\nbank = reg[BANK_W-1:0]", red, "#fff1f2", 8.5)
    for i in range(4): arrow(14.55,9.04-i*.72,15.1,9.04-i*.72,red)
    arrow(15.1,6.95,7.35,5.45,red,"read response fills one source slot")
    arrow(12.45,7.35,7.35,5.25,green,"successful reads populate reuse cache")

    box(8.2, 3.0, 3.5, 1.45, "READY SELECT\nrotating collector priority\nfree only on issue handshake", green, "#f0fdf4")
    arrow(7.5,7.0,9.0,4.45,purple,"pending == 0")
    box(12.55, 3.0, 4.6, 1.45, "Execution pipeline\nwarp · instruction tag · operand A/B/C", blue, "#f0f9ff")
    arrow(11.7,3.72,12.55,3.72,green,"valid / ready")

    box(.55, 1.0, 5.1, 1.75, "Bank-conflict example\nr1, r5, r9 → bank 1\nthree reads require three cycles", amber, "#fffbeb")
    box(6.45, 1.0, 5.1, 1.75, "Parallel example\nr0 → B0, r1 → B1, r2 → B2\nall three captured in one cycle", green, "#f0fdf4")
    box(12.35, 1.0, 5.1, 1.75, "Recovery + observability\nflush drops every collector + cache\nread / reuse / conflict counters", red, "#fff1f2")
    ax.text(9, .35, "Circuit/dataflow schematic of the implemented RTL — hand-drawn documentation image, not a simulator capture.",
            ha="center", fontsize=8.5, color="#64748b", style="italic")
    fig.tight_layout()
    fig.savefig(DOCS / "simt_operand_collector_block.png", dpi=180, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    waveform()
    schematic()
    print("wrote", DOCS / "simt_operand_collector_waveform.png")
    print("wrote", DOCS / "simt_operand_collector_block.png")
