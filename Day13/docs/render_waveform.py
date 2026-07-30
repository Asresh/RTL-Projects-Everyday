#!/usr/bin/env python3
"""Render Day13 fp_add.vcd (a REAL Icarus simulation dump) to a PNG.

Parses the VCD produced by `make icarus`, extracts the top-level DUT ports, and
draws a cycle-accurate digital-timing view of the directed corner-case sequence
that opens the testbench: clock, reset, the in_valid / sub control strobes, the
two 32-bit operand buses a / b, and the out_valid / result outputs.  Every bus
cell is annotated with the IEEE-754 hex on top and its decoded float value
underneath, so the 3-cycle pipeline latency and the special cases (Inf-Inf ->
NaN, cancellation -> +0, overflow -> Inf) are readable straight off the diagram.

This is a genuine captured waveform, not a mockup.
"""
import struct
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt


# --------------------------------------------------------------------------- #
# VCD parsing
# --------------------------------------------------------------------------- #
def parse_vcd(path):
    id2name, tv, cur = {}, {}, 0
    want = {"clk", "rst_n", "in_valid", "sub", "a", "b", "out_valid", "result"}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("$var"):
                p = line.split()
                kind, sym, name = p[1], p[3], p[4]
                if kind == "parameter":
                    continue
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


def to_uint(bits, width=32):
    if bits is None:
        return None
    return int(bits.replace("x", "0").replace("z", "0").zfill(width)[-width:], 2)


def f32(bits):
    """Decode a 32-bit pattern to a short human-readable float string."""
    u = to_uint(bits)
    if u is None:
        return "x"
    exp = (u >> 23) & 0xFF
    man = u & 0x7FFFFF
    if exp == 0xFF:
        return "NaN" if man else ("-Inf" if u >> 31 else "+Inf")
    v = struct.unpack(">f", struct.pack(">I", u))[0]
    if v == 0.0:
        return "-0" if u >> 31 else "+0"
    if abs(v) >= 1e4 or abs(v) < 1e-3:
        return f"{v:.3g}"
    return f"{v:g}"


# --------------------------------------------------------------------------- #
# drawing
# --------------------------------------------------------------------------- #
def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "../fp_add.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "fp_add_waveform.png"
    s = parse_vcd(vcd)

    # timescale 1ps; 100 MHz clock -> 10000 ticks/cycle, posedge n at 5000+n*10000
    PERIOD, POSEDGE0 = 10000, 5000
    SAMPLE = lambda c: POSEDGE0 + c * PERIOD + 100
    START_CYC, NCYC = 3, 16
    cycles = list(range(START_CYC, START_CYC + NCYC))
    xL = lambda c: c - START_CYC

    rows = [("clk", 1.0, "clk"), ("rst_n", 1.0, "scalar"),
            ("in_valid", 1.0, "scalar"), ("sub", 1.0, "scalar"),
            ("a", 1.7, "bus"), ("b", 1.7, "bus"),
            ("out_valid", 1.0, "scalar"), ("result", 1.7, "bus")]
    GAP = 0.45
    base, ht = {}, {}
    y = 0.0
    for name, h, _ in reversed(rows):
        base[name], ht[name] = y, h
        y += h + GAP
    top = y

    plt.rcParams.update({"font.family": "DejaVu Sans Mono", "font.size": 10})
    fig, ax = plt.subplots(figsize=(17.5, 9.2))
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
        xs, ys = [], []
        for c in cycles:
            b = val_at(s.get(name, []), SAMPLE(c))
            lvl = hi if b == "1" else lo
            k = xL(c)
            if prev is not None and prev != lvl:
                xs += [k, k]
                ys += [prev, lvl]
            xs += [k, k + 1]
            ys += [lvl, lvl]
            prev = lvl
        ax.plot(xs, ys, color=color, lw=1.8)

    def draw_bus(name, color):
        lo, hi = band(name, frac=0.12)
        mid = (lo + hi) / 2.0
        for c in cycles:
            k = xL(c)
            bits = val_at(s.get(name, []), SAMPLE(c))
            u = to_uint(bits)
            hexs = "xxxxxxxx" if u is None else f"{u:08x}"
            # hexagon-ish cell with slanted edges
            ax.plot([k + 0.04, k + 0.12, k + 0.88, k + 0.96, k + 0.88, k + 0.12, k + 0.04],
                    [mid, hi, hi, mid, lo, lo, mid], color=color, lw=1.3)
            ax.text(k + 0.5, mid + 0.22, hexs, ha="center", va="center",
                    fontsize=8.6, color=color, family="DejaVu Sans Mono")
            ax.text(k + 0.5, mid - 0.24, f32(bits), ha="center", va="center",
                    fontsize=8.4, color="#333")

    draw_scalar("rst_n", GREY)
    draw_scalar("in_valid", BLUE)
    draw_scalar("sub", ORANGE)
    draw_scalar("out_valid", RED)
    draw_bus("a", BLUE)
    draw_bus("b", BLUE)
    draw_bus("result", RED)

    # row labels + light cycle grid
    for name, _, _ in rows:
        ax.text(-0.15, base[name] + ht[name] / 2.0, name, ha="right", va="center",
                fontsize=11, family="DejaVu Sans Mono")
    for c in cycles:
        k = xL(c)
        ax.axvline(k, color="#e4e4e4", lw=0.7, zorder=0)
        ax.text(k + 0.5, top + 0.05, f"{c}", ha="center", va="bottom",
                fontsize=8, color="#999")
    ax.text(-0.15, top + 0.05, "cycle", ha="right", va="bottom", fontsize=8, color="#999")

    ax.text(NCYC / 2.0, -0.75,
            "Reset releases, then directed operand pairs stream in on in_valid (sub picks +/-).  "
            "After the fixed 3-cycle pipeline latency out_valid asserts and one IEEE-754 result "
            "emerges every clock: 1+2=3, 3.5+0.5=4, 1-1=+0, (-0)+(-0)=-0, 2-3=-1, a "
            "round-to-even tie, Inf+1=Inf, Inf-Inf=NaN, overflow=Inf, denormal add.  "
            "Cells: IEEE hex on top, decoded float below.",
            ha="center", va="top", fontsize=8.4, color="#444", wrap=True)

    ax.set_xlim(-2.4, NCYC + 0.1)
    ax.set_ylim(-1.35, top + 0.6)
    ax.axis("off")
    ax.set_title("Day 13  fp_add - captured Icarus Verilog simulation "
                 "(IEEE-754 binary32 add/sub, round-to-nearest-even, 3-stage pipeline)",
                 fontsize=12, pad=14)
    plt.tight_layout()
    fig.savefig(out, dpi=130, bbox_inches="tight", facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    main()
