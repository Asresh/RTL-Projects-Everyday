#!/usr/bin/env python3
"""Render a REAL captured waveform from async_fifo.vcd (produced by `make icarus`).

This is not a hand-drawn mock-up: it parses the VCD written by the Icarus
Verilog simulation of tb_async_fifo and plots a window that covers the directed
"fill to full, then drain to empty" phase (reset -> writes -> wfull -> reads ->
rempty). Two independent clocks (wclk, rclk) are shown to make the dual-clock
nature explicit.

Usage:  python3 gen_waveform.py [async_fifo.vcd] [docs/async_fifo_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = sys.argv[1] if len(sys.argv) > 1 else "async_fifo.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/async_fifo_waveform.png"


def parse_vcd(path):
    """Return {name: {'width':w, 'tv':[(t,val_str)]}} plus timescale string."""
    code2names, widths = {}, {}
    changes = {}
    timescale = None
    want_ts = False
    t = 0
    in_defs = True
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs:
                if want_ts:
                    # $timescale value may sit on the following line(s)
                    for tok in line.split():
                        if tok != "$end":
                            timescale = tok
                            want_ts = False
                            break
                    if line.endswith("$end") or timescale:
                        want_ts = False
                    continue
                if line.startswith("$timescale"):
                    parts = line.split()
                    if len(parts) >= 2 and parts[1] not in ("$end",):
                        timescale = parts[1]   # inline form
                    else:
                        want_ts = True         # value is on a later line
                elif line.startswith("$var"):
                    # $var wire 1 ! wclk $end  /  $var wire 8 ' wdata [7:0] $end
                    p = line.split()
                    width = int(p[2]); code = p[3]; name = p[4]
                    code2names.setdefault(code, []).append(name)
                    widths[name] = width
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            # value-change section
            if line[0] == "#":
                t = int(line[1:])
            elif line[0] in "01xzXZ":
                val, code = line[0], line[1:]
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, val))
            elif line[0] in "bB":
                val, code = line[1:].split()
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, val))
    sig = {nm: {"width": widths.get(nm, 1), "tv": changes.get(nm, [])}
           for nm in widths}
    return sig, timescale


def val_at(tv, t):
    cur = None
    for (tt, v) in tv:
        if tt <= t:
            cur = v
        else:
            break
    return cur


def first_time(tv, pred):
    for (tt, v) in tv:
        if pred(v):
            return tt
    return None


def to_int(v):
    try:
        return int(v, 2)
    except ValueError:
        return None


def main():
    sig, ts = parse_vcd(VCD)

    # find scope-qualified names (VCD stores leaf names; pick unique leaves)
    def g(name):
        return sig[name]["tv"] if name in sig else []

    # window: reset deassert -> a little after FIFO returns to empty in drain
    t_rst = first_time(g("wrst_n"), lambda v: v == "1") or 0
    t_full = first_time(g("wfull"), lambda v: v == "1")
    # first empty AFTER we have gone full (the directed drain)
    t_empty = None
    if t_full is not None:
        for (tt, v) in g("rempty"):
            if tt > t_full and v == "1":
                t_empty = tt
                break
    t0 = max(0, t_rst - 20)
    t1 = (t_empty + 40) if t_empty else (t_rst + 400)

    rows = [
        ("wclk",   "clk"),
        ("wrst_n", "bit"),
        ("wr_en",  "bit"),
        ("wdata",  "bus"),
        ("wfull",  "bit"),
        ("rclk",   "clk"),
        ("rrst_n", "bit"),
        ("rd_en",  "bit"),
        ("rdata",  "bus"),
        ("rempty", "bit"),
    ]
    rows = [(n, k) for (n, k) in rows if n in sig]

    fig, ax = plt.subplots(figsize=(16, 7.5))
    ylabels, yticks = [], []
    row_h = 1.0
    gap = 0.35
    y = 0.0
    write_c, read_c = "#2563eb", "#c026d3"

    def edges_in_window(tv):
        pts = [(t0, val_at(tv, t0))]
        for (tt, v) in tv:
            if t0 < tt <= t1:
                pts.append((tt, v))
        pts.append((t1, pts[-1][1]))
        return pts

    for name, kind in reversed(rows):
        tv = sig[name]["tv"]
        color = write_c if name.startswith("w") else read_c
        pts = edges_in_window(tv)
        if kind in ("clk", "bit"):
            # draw a step square wave
            xs, ys = [], []
            for i in range(len(pts) - 1):
                (ta, va) = pts[i]
                (tb, _) = pts[i + 1]
                lvl = 1 if va in ("1",) else 0
                xs += [ta, tb]
                ys += [y + lvl * (row_h - 0.25), y + lvl * (row_h - 0.25)]
                if i + 1 < len(pts):
                    xs.append(tb); ys.append(y + (1 if pts[i+1][1] == "1" else 0) * (row_h - 0.25))
            ax.plot(xs, ys, color=color, lw=1.3, solid_joinstyle="miter")
        else:  # bus
            for i in range(len(pts) - 1):
                (ta, va) = pts[i]
                (tb, _) = pts[i + 1]
                if tb <= ta:
                    continue
                iv = to_int(va) if va is not None else None
                filled = iv not in (None, 0)
                ax.add_patch(Rectangle((ta, y + 0.12), tb - ta, row_h - 0.45,
                                       facecolor=(color if filled else "none"),
                                       edgecolor=color, alpha=0.18 if filled else 1.0,
                                       lw=1.0))
                if iv is not None and (tb - ta) > (t1 - t0) * 0.012:
                    ax.text((ta + tb) / 2, y + (row_h - 0.2) / 2,
                            f"{iv:02X}", ha="center", va="center",
                            fontsize=7.5, color=color)
        ylabels.append(name)
        yticks.append(y + (row_h - 0.25) / 2)
        y += row_h + gap

    # markers
    if t_full is not None and t0 <= t_full <= t1:
        ax.axvline(t_full, color="#16a34a", ls="--", lw=1.0, alpha=0.7)
        ax.text(t_full, y + 0.05, "wfull↑", color="#16a34a",
                ha="center", fontsize=9)
    if t_empty is not None and t0 <= t_empty <= t1:
        ax.axvline(t_empty, color="#b45309", ls="--", lw=1.0, alpha=0.7)
        ax.text(t_empty - (t1 - t0) * 0.01, y + 0.05, "rempty↑",
                color="#b45309", ha="right", fontsize=9)

    # convert the raw VCD time units to nanoseconds for a readable axis
    unit_to_ns = {"1fs": 1e-6, "1ps": 1e-3, "10ps": 1e-2, "100ps": 1e-1,
                  "1ns": 1.0, "10ns": 10.0, "1us": 1e3}.get(ts, 1e-3)
    from matplotlib.ticker import FuncFormatter
    ax.xaxis.set_major_formatter(
        FuncFormatter(lambda v, _pos: f"{v * unit_to_ns:.0f}"))

    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=9)
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.3, y + 0.5)
    ax.set_xlabel(f"simulation time (ns)   [VCD timescale {ts}]", fontsize=10)
    ax.set_title("async_fifo — REAL captured waveform (Icarus VCD): "
                 "reset → fill to wfull → drain to rempty",
                 fontsize=12, pad=14)
    ax.grid(axis="x", ls=":", alpha=0.3)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)

    # legend
    ax.plot([], [], color=write_c, lw=2, label="write-clock domain")
    ax.plot([], [], color=read_c,  lw=2, label="read-clock domain")
    ax.legend(loc="upper right", fontsize=9, framealpha=0.9)

    fig.tight_layout()
    fig.savefig(OUT, dpi=140, bbox_inches="tight")
    print(f"wrote {OUT}  window=[{t0},{t1}] {ts}  full@{t_full} empty@{t_empty}")


if __name__ == "__main__":
    main()
