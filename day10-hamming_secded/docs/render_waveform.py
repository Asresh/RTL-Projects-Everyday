#!/usr/bin/env python3
"""Render Day10 hamming_secded.vcd (a REAL Icarus simulation dump) to a PNG.

Parses the VCD produced by `make icarus`, extracts the top-level DUT ports, and
draws a cycle-accurate digital-timing view of the directed front sequence:
clock, control/status strobes (in_valid/out_valid, single/double error), and the
data_i / data_o buses in hex.  This is a genuine captured waveform, not a mockup.
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

def parse_vcd(path):
    id2name, tv = {}, {}
    cur = 0
    want = {"clk", "rst_n", "in_valid", "out_valid",
            "single_error_o", "double_error_o", "data_i", "data_o"}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("$var"):
                p = line.split()
                sym, name = p[3], p[4]
                if name in want and name not in id2name.values():
                    id2name[sym] = name
                    tv[sym] = []
            elif line.startswith("#"):
                cur = int(line[1:])
            elif line and line[0] in "01xz":
                sym = line[1:]
                if sym in id2name:
                    tv[sym].append((cur, line[0]))
            elif line and line[0] == "b":
                m = line.split()
                if len(m) == 2 and m[1] in id2name:
                    tv[m[1]].append((cur, m[0][1:]))
    return {id2name[s]: v for s, v in tv.items()}

def val_at(changes, t):
    r = None
    for (ct, cv) in changes:
        if ct <= t:
            r = cv
        else:
            break
    return r

def bits_to_hex(s, nib):
    if s is None or "x" in s or "z" in s:
        return "x"
    return f"{int(s, 2):0{nib}x}"

def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "../hamming_secded.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "hamming_secded_waveform.png"
    s = parse_vcd(vcd)

    # VCD timescale 1ns/1ps -> ticks are ps; 100 MHz clock => 10000 ticks/cyc,
    # rising edge of cycle n at 5000 + n*10000 ticks.
    PERIOD = 10000
    POSEDGE0 = 5000
    SAMPLE = lambda c: POSEDGE0 + c * PERIOD + 100   # just after posedge of cyc c
    START_CYC = 4
    NCYC = 18
    cycles = list(range(START_CYC, START_CYC + NCYC))
    xL = lambda c: c - START_CYC
    N = NCYC

    scalar_rows = ["clk", "rst_n", "in_valid", "out_valid",
                   "single_error_o", "double_error_o"]
    bus_rows    = ["data_i", "data_o"]
    labels = scalar_rows + bus_rows
    nrows = len(labels)

    lo, hi = 0.20, 0.80
    gap = 1.0
    base = {name: (nrows - 1 - i) * gap for i, name in enumerate(labels)}
    ymid = lambda name: base[name] + (lo + hi) / 2.0

    plt.rcParams.update({"font.family": "DejaVu Sans Mono", "font.size": 10})
    fig, ax = plt.subplots(figsize=(15, 7.6))
    fig.patch.set_facecolor("white")

    GREEN, BLUE, RED, ORANGE, GREY = "#0b8f3a", "#1f6feb", "#b3261e", "#d97706", "#8a8a8a"

    # clock
    b = base["clk"]
    xs, ys = [], []
    for c in cycles:
        k = xL(c)
        xs += [k, k, k + 0.5, k + 0.5, k + 1]
        ys += [b + lo, b + hi, b + hi, b + lo, b + lo]
    ax.plot(xs, ys, color=GREEN, lw=1.7)

    def draw_scalar(name, color):
        b = base[name]
        prev = None
        for c in cycles:
            k = xL(c)
            v = val_at(s.get(name, []), SAMPLE(c))
            lvl = b + (hi if v == "1" else lo)
            ax.plot([k, k + 1], [lvl, lvl], color=color, lw=1.9)
            if prev is not None and abs(prev - lvl) > 1e-9:
                ax.plot([k, k], [b + lo, b + hi], color=color, lw=1.9)
            prev = lvl

    draw_scalar("rst_n", RED)
    draw_scalar("in_valid", BLUE)
    draw_scalar("out_valid", GREEN)
    draw_scalar("single_error_o", ORANGE)
    draw_scalar("double_error_o", RED)

    # Only draw a value cell in cycles where the companion valid is high; the
    # 64-bit bus is idle (flat line) otherwise, which keeps the hex readable.
    def draw_bus(name, nib, gate):
        b = base[name]
        mid = b + (lo + hi) / 2.0
        for c in cycles:
            k = xL(c)
            live = val_at(s.get(gate, []), SAMPLE(c)) == "1"
            if not live:
                ax.plot([k, k + 1], [mid, mid], color="#9aa4b2", lw=1.3)
                continue
            txt = "0x" + bits_to_hex(val_at(s.get(name, []), SAMPLE(c)), nib)
            ax.add_patch(Polygon([[k + 0.04, b + lo], [k + 0.96, b + lo],
                                   [k + 0.96, b + hi], [k + 0.04, b + hi]],
                                  closed=True, facecolor="#eef2ff",
                                  edgecolor="#33415c", lw=1.0))
            ax.text(k + 0.5, mid, txt, ha="center", va="center",
                    fontsize=6.6, color="#111")

    draw_bus("data_i", 16, "in_valid")
    draw_bus("data_o", 16, "out_valid")

    top = (nrows - 1) * gap + hi + 0.15
    for k in range(N + 1):
        ax.plot([k, k], [-0.25, top], color="#e6e6e6", lw=0.7, zorder=0)
    for c in cycles:
        ax.text(xL(c) + 0.5, top + 0.05, f"{c}", ha="center", va="bottom",
                fontsize=8, color=GREY)
    ax.text(-0.12, top + 0.05, "cycle", ha="right", va="bottom",
            fontsize=8, color=GREY)

    for name in labels:
        ax.text(-0.12, ymid(name), name, ha="right", va="center",
                fontsize=10, color="#111")

    ax.text(N / 2.0, -0.18,
            "reset released -> words stream in on in_valid; 2 cycles later out_valid asserts. "
            "clean word: no flags. corrupted-by-1-bit: single_error_o + data_o restored. "
            "corrupted-by-2-bits: double_error_o (uncorrectable).",
            ha="center", va="top", fontsize=8.3, color="#444")

    ax.set_xlim(-2.1, N + 0.2)
    ax.set_ylim(-0.7, top + 0.4)
    ax.axis("off")
    ax.set_title("Day 10  hamming_secded — captured Icarus Verilog simulation "
                 "((72,64) SECDED, 2-cycle pipeline)", fontsize=11, pad=14)

    plt.tight_layout()
    fig.savefig(out, dpi=130, bbox_inches="tight", facecolor="white")
    print("wrote", out)

if __name__ == "__main__":
    main()
