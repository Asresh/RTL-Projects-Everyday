#!/usr/bin/env python3
"""Render Day14 systolic_matmul.vcd (a REAL Icarus simulation dump) to a PNG.

Parses the VCD produced by `make icarus`, then draws a cycle-accurate digital
timing view of the FIRST GEMM invocation (the directed "identity" case that
opens the testbench).  It shows the start/busy/done control handshake, the
space-time cycle counter `t`, the DIAGONAL SKEW of the west activation-valid
strobes west_v0..west_v3 (row i launches i cycles later -- the signature of a
systolic array), and two corner accumulators C[0][0] and C[3][3] settling to
their final values as MACs stream through the mesh.

This is a genuine captured waveform, not a mockup.
"""
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle


# --------------------------------------------------------------------------- #
# VCD parsing
# --------------------------------------------------------------------------- #
def parse_vcd(path):
    id2name, tv, cur = {}, {}, 0
    want = {"clk", "rst_n", "start", "busy", "done", "t_cnt",
            "west_v0", "west_v1", "west_v2", "west_v3", "c00", "c33"}
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


def to_int(bits, width):
    """Interpret a 2's-complement bit string."""
    if bits is None:
        return None
    b = bits.replace("x", "0").replace("z", "0").zfill(width)[-width:]
    u = int(b, 2)
    if b[0] == "1":
        u -= (1 << width)
    return u


# --------------------------------------------------------------------------- #
# Draw
# --------------------------------------------------------------------------- #
def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else "../systolic_matmul.vcd"
    out = sys.argv[2] if len(sys.argv) > 2 else "systolic_matmul_waveform.png"
    sig = parse_vcd(vcd)

    # Locate the first `start` pulse; sample one cycle before it through the
    # end of the first `done`.
    period = 10_000  # 10 ns in the VCD's 1 ps timebase
    start_edges = [t for (t, v) in sig["start"] if v == "1"]
    t0 = start_edges[0] - period            # one cycle of lead-in
    done_edges = [t for (t, v) in sig["done"] if v == "1"]
    t_done = done_edges[0]
    n_cyc = int(round((t_done - t0) / period)) + 3
    cycles = list(range(n_cyc))
    # Sample each signal at the clock's rising edge (mid-high) for clean levels.
    samp = [t0 + c * period + period // 2 for c in cycles]

    bin_rows = [
        ("clk",      "clk"),
        ("rst_n",    "rst_n"),
        ("start",    "start"),
        ("busy",     "busy"),
        ("done",     "done"),
        ("west_v0",  "west_v[0]  row0"),
        ("west_v1",  "west_v[1]  row1"),
        ("west_v2",  "west_v[2]  row2"),
        ("west_v3",  "west_v[3]  row3"),
    ]
    bus_rows = [
        ("t_cnt", "t (cycle)", 4, lambda b: str(int(b.replace('x', '0') or '0', 2))),
        ("c00",   "C[0][0]",  19, lambda b: str(to_int(b, 19))),
        ("c33",   "C[3][3]",  19, lambda b: str(to_int(b, 19))),
    ]

    n_rows = len(bin_rows) + len(bus_rows)
    fig, ax = plt.subplots(figsize=(13.5, 8.2))
    ax.set_xlim(-0.5, n_cyc - 0.5)
    ax.set_ylim(-n_rows - 0.5, 1.0)
    ax.axis("off")

    C_BG, C_HI, C_TXT = "#0d1b2a", "#4cc9f0", "#e0e1dd"
    C_BUS, C_BUSE = "#264653", "#2a9d8f"
    C_GRID = "#1b263b"
    fig.patch.set_facecolor("#0b141f")
    ax.set_facecolor("#0b141f")

    # vertical cycle gridlines + numbers
    for c in cycles:
        ax.axvline(c, color=C_GRID, lw=0.6, zorder=0)
        ax.text(c, 0.55, str(c), ha="center", va="bottom",
                color="#7f8fa6", fontsize=8)
    ax.text(-0.5, 0.85, "clock cycle", color="#7f8fa6", fontsize=8, ha="left")

    def hi(bits):
        return bits is not None and bits[-1] == "1"

    row = 0
    for key, label in bin_rows:
        y = -row
        s = sig.get(key, [])
        if key == "clk":
            # draw an idealized clock for readability
            for c in cycles:
                ax.add_patch(Rectangle((c - 0.5, y + 0.02), 0.5, 0.34,
                                       facecolor=C_HI, edgecolor="none",
                                       alpha=0.9, zorder=2))
        else:
            prev = None
            xs, ys = [], []
            for c in cycles:
                b = val_at(s, samp[c])
                lvl = 1 if hi(b) else 0
                if prev is not None and prev != lvl:
                    xs.append(c - 0.5); ys.append(prev * 0.36 + y + 0.02)
                xs.append(c - 0.5); ys.append(lvl * 0.36 + y + 0.02)
                xs.append(c + 0.5); ys.append(lvl * 0.36 + y + 0.02)
                prev = lvl
            ax.plot(xs, ys, color=C_HI, lw=1.8, zorder=2)
        ax.text(-0.7, y + 0.18, label, ha="right", va="center",
                color=C_TXT, fontsize=9, family="monospace")
        row += 1

    for key, label, width, fmt in bus_rows:
        y = -row
        s = sig.get(key, [])
        prev_txt = None
        for c in cycles:
            b = val_at(s, samp[c])
            txt = fmt(b) if b is not None else "x"
            changed = (txt != prev_txt)
            fc = C_BUSE if changed else C_BUS
            ax.add_patch(Rectangle((c - 0.5, y + 0.02), 1.0, 0.36,
                                   facecolor=fc, edgecolor="#0b141f",
                                   lw=0.8, zorder=2))
            ax.text(c, y + 0.20, txt, ha="center", va="center",
                    color="#ffffff", fontsize=7.5, family="monospace", zorder=3)
            prev_txt = txt
        ax.text(-0.7, y + 0.18, label, ha="right", va="center",
                color=C_TXT, fontsize=9, family="monospace")
        row += 1

    ax.set_title("Day14  systolic_matmul  —  captured Icarus waveform "
                 "(directed 'identity' case: C = A×I)",
                 color="#e0e1dd", fontsize=12, pad=14)
    fig.text(0.5, 0.015,
             "Genuine VCD capture from `make icarus`.  Note the diagonal skew of "
             "west_v[0..3] — row i launches i cycles late — and the corner "
             "accumulators settling as MACs stream through the mesh.",
             ha="center", color="#7f8fa6", fontsize=8.5)

    fig.savefig(out, dpi=130, bbox_inches="tight", facecolor=fig.get_facecolor())
    print("wrote", out)


if __name__ == "__main__":
    main()
