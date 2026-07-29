#!/usr/bin/env python3
"""Render Day12 booth_multiplier.vcd (a REAL Icarus simulation dump) to a PNG.

Parses the VCD produced by `make icarus`, extracts the top-level DUT ports, and
draws a cycle-accurate digital-timing view of the directed front sequence:
clock, reset, in_valid/out_valid strobes, the two operand buses a/b, and the
double-width product bus.  Each bus cell shows the value in hex with the signed
decimal underneath.

This is a genuine captured waveform, not a mockup.
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

WIDTH = 16          # operand width
OW    = 2 * WIDTH   # product width


def parse_vcd(path):
    """Return {name: [(time, value_str), ...]} for the signals we care about."""
    id2name, tv = {}, {}
    want = {"clk", "rst_n", "in_valid", "out_valid", "a", "b", "product"}
    cur = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("$var"):
                p = line.split()
                # $var <type> <width> <id> <name> ... $end
                kind, sym, name = p[1], p[3], p[4]
                if kind == "parameter":
                    continue                      # skip elaboration params
                if name in want and name not in id2name.values():
                    id2name[sym] = name
                    tv[sym] = []
            elif line.startswith("#"):
                cur = int(line[1:])
            elif line and line[0] in "01xz" and len(line) >= 2 and line[1] != " ":
                sym = line[1:]
                if sym in id2name:
                    tv[sym].append((cur, line[0]))
            elif line and line[0] == "b":
                m = line.split()
                if len(m) == 2 and m[1] in id2name:
                    tv[m[1]].append((cur, m[0][1:]))
    return {id2name[s]: v for s, v in tv.items()}


def val_at(series, t):
    v = None
    for (tt, vv) in series:
        if tt <= t:
            v = vv
        else:
            break
    return v


def to_int(bits, width):
    if bits is None:
        return None
    b = bits.replace("x", "0").replace("z", "0").zfill(width)[-width:]
    return int(b, 2)


def to_signed(bits, width):
    u = to_int(bits, width)
    if u is None:
        return None
    return u - (1 << width) if (u >> (width - 1)) & 1 else u


def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "../booth_multiplier.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "booth_multiplier_waveform.png"
    s = parse_vcd(vcd)

    # timescale 1ps; 100 MHz clock -> 10000 ticks/cycle, posedge n at 5000+n*10000
    PERIOD, POSEDGE0 = 10000, 5000
    SAMPLE = lambda c: POSEDGE0 + c * PERIOD + 100
    START_CYC, NCYC = 2, 16
    cycles = list(range(START_CYC, START_CYC + NCYC))
    xL = lambda c: c - START_CYC
    NC = NCYC

    rows = [("clk", 1.0, "clk"), ("rst_n", 1.0, "scalar"),
            ("in_valid", 1.0, "scalar"),
            ("a", 1.6, "bus"), ("b", 1.6, "bus"),
            ("out_valid", 1.0, "scalar"), ("product", 1.6, "bus")]
    GAP = 0.4
    base, ht = {}, {}
    y = 0.0
    for name, h, _ in reversed(rows):          # stack from the bottom up
        base[name], ht[name] = y, h
        y += h + GAP
    total = y

    plt.rcParams.update({"font.family": "DejaVu Sans Mono", "font.size": 10})
    fig, ax = plt.subplots(figsize=(16.8, 8.8))
    fig.patch.set_facecolor("white")
    GREEN, BLUE, RED, GREY, ORANGE = "#0b8f3a", "#1f6feb", "#b3261e", "#8a8a8a", "#d97706"

    def band(name, frac=0.30):
        lo = base[name] + ht[name] * frac
        hi = base[name] + ht[name] * (1.0 - frac)
        return lo, hi

    # clock
    lo, hi = band("clk")
    xs, ys = [], []
    for c in cycles:
        k = xL(c)
        xs += [k, k, k + 0.5, k + 0.5, k + 1]
        ys += [lo, hi, hi, lo, lo]
    ax.plot(xs, ys, color=GREEN, lw=1.7)

    def draw_scalar(name, color):
        lo, hi = band(name)
        prev = None
        for c in cycles:
            k = xL(c)
            v = val_at(s.get(name, []), SAMPLE(c))
            lvl = hi if v == "1" else lo
            ax.plot([k, k + 1], [lvl, lvl], color=color, lw=1.9)
            if prev is not None and abs(prev - lvl) > 1e-9:
                ax.plot([k, k], [lo, hi], color=color, lw=1.9)
            prev = lvl

    draw_scalar("rst_n", RED)
    draw_scalar("in_valid", BLUE)
    draw_scalar("out_valid", GREEN)

    def draw_bus(name, gate, width, face, edge, hexdig, hfs, prefix):
        lo = base[name] + 0.14
        hi = base[name] + ht[name] - 0.14
        mid = (lo + hi) / 2.0
        for c in cycles:
            k = xL(c)
            live = val_at(s.get(gate, []), SAMPLE(c)) == "1"
            if not live:
                ax.plot([k, k + 1], [mid, mid], color="#9aa4b2", lw=1.3)
                continue
            raw = val_at(s.get(name, []), SAMPLE(c))
            u = to_int(raw, width)
            sd = to_signed(raw, width)
            ax.add_patch(Polygon([[k + 0.09, lo], [k + 0.91, lo],
                                   [k + 0.91, hi], [k + 0.09, hi]],
                                  closed=True, facecolor=face,
                                  edgecolor=edge, lw=1.0))
            ax.text(k + 0.5, mid + 0.30, f"{prefix}{u:0{hexdig}X}", ha="center",
                    va="center", fontsize=hfs, color="#111")
            ax.text(k + 0.5, mid - 0.30, f"{sd}", ha="center", va="center",
                    fontsize=6.8, color="#555")

    draw_bus("a",       "in_valid",  WIDTH, "#eef2ff", "#33415c", 4, 7.4, "0x")
    draw_bus("b",       "in_valid",  WIDTH, "#eef2ff", "#33415c", 4, 7.4, "0x")
    draw_bus("product", "out_valid", OW,    "#e9f7ee", GREEN,     8, 5.6, "")

    # gridlines + cycle numbers
    top = total
    for k in range(NC + 1):
        ax.plot([k, k], [-0.25, top], color="#ececec", lw=0.7, zorder=0)
    for c in cycles:
        ax.text(xL(c) + 0.5, top + 0.02, f"{c}", ha="center", va="bottom",
                fontsize=8, color=GREY)
    ax.text(-0.12, top + 0.02, "cycle", ha="right", va="bottom",
            fontsize=8, color=GREY)
    for name, _, _ in rows:
        ax.text(-0.12, base[name] + ht[name] / 2.0, name, ha="right",
                va="center", fontsize=10, color="#111")

    # latency arrow: first accepted operand pair -> first product
    in_c  = next((c for c in cycles
                  if val_at(s.get("in_valid", []), SAMPLE(c)) == "1"), None)
    out_c = next((c for c in cycles
                  if val_at(s.get("out_valid", []), SAMPLE(c)) == "1"), None)
    if in_c is not None and out_c is not None:
        ax.annotate("", xy=(xL(out_c) + 0.5, base["product"] + ht["product"]),
                    xytext=(xL(in_c) + 0.5, base["a"]),
                    arrowprops=dict(arrowstyle="->", color=ORANGE, lw=1.5,
                                    connectionstyle="arc3,rad=-0.12"))
        ax.text((xL(in_c) + xL(out_c)) / 2.0 + 0.5,
                base["out_valid"] + ht["out_valid"] + 0.05,
                "same operands, multiplied, after the 4-stage pipeline fills",
                ha="center", va="bottom", fontsize=8.2, color=ORANGE)

    ax.text(NC / 2.0, -0.35,
            "reset released -> signed operand pairs stream in on in_valid; after the 4-stage pipeline "
            "(operand reg -> Booth partial products -> carry-save tree -> final adder) fills, out_valid "
            "asserts and one 32-bit product (a*b) emerges every clock.  Cells: hex on top, signed decimal below.",
            ha="center", va="top", fontsize=8.3, color="#444")

    ax.set_xlim(-2.6, NC + 0.2)
    ax.set_ylim(-1.0, top + 0.5)
    ax.axis("off")
    ax.set_title("Day 12  booth_multiplier — captured Icarus Verilog simulation "
                 "(WIDTH=16, SIGNED, radix-4 Booth + carry-save tree, 4-stage pipeline)",
                 fontsize=11, pad=12)
    plt.tight_layout()
    fig.savefig(out, dpi=130, bbox_inches="tight", facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()
