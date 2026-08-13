#!/usr/bin/env python3
"""Render Day9 cordic_sincos.vcd (a REAL Icarus simulation dump) to a PNG.

Parses the VCD produced by `make icarus`, extracts the top-level DUT ports,
and draws a cycle-accurate digital-timing view: clock, control/status strobes,
and the fixed-point angle / cos / sin buses decoded to real values.
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon

WIDTH = 16
FRAC = 13            # Q2.FRAC fixed-point fractional bits

def twos(v, w):
    return v - (1 << w) if (v >> (w - 1)) & 1 else v

def parse_vcd(path):
    id2name, tv = {}, {}
    cur = 0
    want = {"clk", "rst_n", "in_valid", "theta", "out_valid", "cos_o", "sin_o"}
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

def bits_to_real(s):
    if s is None or "x" in s or "z" in s:
        return None
    return twos(int(s, 2), WIDTH) / (2.0 ** FRAC)

def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "../cordic_sincos.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "cordic_sincos_waveform.png"
    s = parse_vcd(vcd)

    # VCD timescale is 1ns/1ps -> ticks are ps; 100 MHz clock => 10000 ticks/cyc,
    # with the rising edge of cycle n at 5000 + n*10000 ticks.
    PERIOD = 10000                  # ticks per clock cycle
    POSEDGE0 = 5000                 # first rising edge
    SAMPLE = lambda c: POSEDGE0 + c * PERIOD + 100   # just after posedge of cyc c
    START_CYC = 3
    NCYC = 16
    cycles = list(range(START_CYC, START_CYC + NCYC))
    xL = lambda c: c - START_CYC
    N = NCYC

    scalar_rows = ["clk", "rst_n", "in_valid", "out_valid"]
    bus_rows    = ["theta", "cos_o", "sin_o"]
    labels = scalar_rows + bus_rows
    nrows = len(labels)

    lo, hi = 0.20, 0.80            # within-row low/high levels
    gap = 1.0                       # vertical spacing between rows
    base = {name: (nrows - 1 - i) * gap for i, name in enumerate(labels)}
    ymid = lambda name: base[name] + (lo + hi) / 2.0

    plt.rcParams.update({"font.family": "DejaVu Sans Mono", "font.size": 10})
    fig, ax = plt.subplots(figsize=(14, 7.4))
    fig.patch.set_facecolor("white")

    GREEN, BLUE, RED, GREY = "#0b8f3a", "#1f6feb", "#b3261e", "#8a8a8a"

    # --- clock: real half-cycle square wave ---
    b = base["clk"]
    xs, ys = [], []
    for c in cycles:
        k = xL(c)
        xs += [k, k, k + 0.5, k + 0.5, k + 1]
        ys += [b + lo, b + hi, b + hi, b + lo, b + lo]
    ax.plot(xs, ys, color=GREEN, lw=1.7)

    # --- other scalars ---
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

    # --- buses: per-cycle value cells (decoded to real) ---
    def draw_bus(name):
        b = base[name]
        for c in cycles:
            k = xL(c)
            rv = bits_to_real(val_at(s.get(name, []), SAMPLE(c)))
            txt = "x" if rv is None else f"{rv:+.3f}"
            ax.add_patch(Polygon([[k + 0.06, b + lo], [k + 0.94, b + lo],
                                   [k + 0.94, b + hi], [k + 0.06, b + hi]],
                                  closed=True, facecolor="#eef2ff",
                                  edgecolor="#33415c", lw=1.0))
            ax.text(k + 0.5, b + (lo + hi) / 2, txt, ha="center", va="center",
                    fontsize=8.0, color="#111")

    for name in bus_rows:
        draw_bus(name)

    # --- vertical cycle gridlines + cycle numbers ---
    top = (nrows - 1) * gap + hi + 0.15
    for k in range(N + 1):
        ax.plot([k, k], [-0.25, top], color="#e6e6e6", lw=0.7, zorder=0)
    for c in cycles:
        ax.text(xL(c) + 0.5, top + 0.05, f"{c}", ha="center", va="bottom",
                fontsize=8, color=GREY)
    ax.text(-0.12, top + 0.05, "cycle", ha="right", va="bottom",
            fontsize=8, color=GREY)

    # --- row labels ---
    for name in labels:
        ax.text(-0.12, ymid(name), name, ha="right", va="center",
                fontsize=10, color="#111")

    # annotation: mark first valid result
    ax.text(N / 2.0, -0.15,
            "reset released → angles stream in (in_valid) → first result "
            "appears 13 cycles later (out_valid), cos/sin decoded to real",
            ha="center", va="top", fontsize=8.5, color="#444")

    ax.set_xlim(-1.7, N + 0.2)
    ax.set_ylim(-0.6, top + 0.4)
    ax.axis("off")
    ax.set_title("Day 9  cordic_sincos — captured Icarus Verilog simulation "
                 "(WIDTH=16, ITER=12, latency=13 cyc)", fontsize=11, pad=14)

    plt.tight_layout()
    fig.savefig(out, dpi=130, bbox_inches="tight", facecolor="white")
    print("wrote", out)

if __name__ == "__main__":
    main()
