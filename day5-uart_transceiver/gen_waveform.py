#!/usr/bin/env python3
"""Render a REAL captured waveform from uart.vcd (produced by `make icarus`).

This is not a hand-drawn mock-up: it parses the VCD written by the Icarus
Verilog simulation of tb_uart and plots the very first transmitted byte
(0xA5 at clks_per_bit = 16) as it appears on the serial line — the start bit,
the eight data bits LSB-first, and the stop bit. Every level and every hex
value shown is read back out of the VCD.

Usage:  python3 gen_waveform.py [uart.vcd] [docs/uart_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.ticker import FuncFormatter

VCD = sys.argv[1] if len(sys.argv) > 1 else "uart.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/uart_waveform.png"


def parse_vcd(path):
    """Parse a VCD, registering only the top testbench scope (depth 1) so leaf
    names never collide with identically named nets deeper in the hierarchy."""
    code2names, widths, changes = {}, {}, {}
    timescale, want_ts = None, False
    t, in_defs, depth = 0, True, 0
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if in_defs:
                if want_ts:
                    for tok in s.split():
                        if tok != "$end":
                            timescale, want_ts = tok, False
                            break
                    continue
                if s.startswith("$timescale"):
                    parts = s.split()
                    if len(parts) >= 2 and parts[1] != "$end":
                        timescale = parts[1]
                    else:
                        want_ts = True
                elif s.startswith("$scope"):
                    depth += 1
                elif s.startswith("$upscope"):
                    depth -= 1
                elif s.startswith("$var") and depth == 1:
                    p = s.split()
                    width, code, name = int(p[2]), p[3], p[4]
                    code2names.setdefault(code, []).append(name)
                    widths[name] = width
                elif s.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if s[0] == "#":
                t = int(s[1:])
            elif s[0] in "01xzXZ":
                val, code = s[0], s[1:]
                for nm in code2names.get(code, []):
                    changes.setdefault(nm, []).append((t, val))
            elif s[0] in "bB":
                parts = s[1:].split()
                if len(parts) == 2:
                    val, code = parts
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


def first_time(tv, pred, after=0):
    for (tt, v) in tv:
        if tt >= after and pred(v):
            return tt
    return None


def to_int(v):
    try:
        return int(v, 2)
    except (ValueError, TypeError):
        return None


def main():
    sig, ts = parse_vcd(VCD)

    def g(name):
        return sig[name]["tv"] if name in sig else []

    # ---- derive timing straight from the VCD --------------------------------
    # one full system-clock period = two consecutive clk toggles (skip t=0)
    clk_tv = [tt for (tt, _) in g("clk") if tt > 0]
    clk_period = (clk_tv[2] - clk_tv[0]) if len(clk_tv) >= 3 else 10000
    cpb = to_int(val_at(g("clks_per_bit"),
                        first_time(g("serial_line"), lambda v: v == "0") or 0))
    cpb = cpb or 16
    bit_period = cpb * clk_period

    # first start bit = first time the serial line falls to 0
    t_start = first_time(g("serial_line"), lambda v: v == "0")
    # window: half a bit before the start edge .. one bit after the stop bit
    t0 = t_start - bit_period
    t1 = t_start + 11 * bit_period

    # ---- sample the 10 bit cells at their centres (values from the VCD) -----
    cells = ["START", "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", "STOP"]
    centres, bits = [], []
    for k in range(10):
        c = t_start + (k + 0.5) * bit_period
        centres.append(c)
        bits.append(val_at(g("serial_line"), c))
    data_bits = bits[1:9]                       # D0..D7
    data_val = sum((1 if b == "1" else 0) << j for j, b in enumerate(data_bits))

    rows = [("tx_start", "bit"), ("tx_busy", "bit"), ("serial_line", "bit"),
            ("rx_valid", "bit"), ("tx_data", "bus"), ("rx_data", "bus")]
    rows = [(n, k) for (n, k) in rows if n in sig]

    fig, ax = plt.subplots(figsize=(15, 7.0))
    line_c, hero_c, rx_c = "#2563eb", "#0f766e", "#c026d3"
    row_h, gap = 1.0, 0.45
    ylabels, yticks, y = [], [], 0.0

    def edges_in_window(tv):
        pts = [(t0, val_at(tv, t0))]
        for (tt, v) in tv:
            if t0 < tt <= t1:
                pts.append((tt, v))
        pts.append((t1, pts[-1][1]))
        return pts

    for name, kind in reversed(rows):
        tv = sig[name]["tv"]
        is_hero = (name == "serial_line")
        color = hero_c if is_hero else (rx_c if name.startswith("rx") else line_c)
        amp = (row_h - 0.15) if is_hero else (row_h - 0.30)
        pts = edges_in_window(tv)
        if kind == "bit":
            xs, ys = [], []
            for i in range(len(pts) - 1):
                (ta, va) = pts[i]
                (tb, _) = pts[i + 1]
                lvl = 1 if va == "1" else 0
                xs += [ta, tb]
                ys += [y + lvl * amp, y + lvl * amp]
                nxt = 1 if pts[i + 1][1] == "1" else 0
                xs.append(tb)
                ys.append(y + nxt * amp)
            ax.plot(xs, ys, color=color, lw=2.2 if is_hero else 1.4,
                    solid_joinstyle="miter")
        else:  # bus
            for i in range(len(pts) - 1):
                (ta, va) = pts[i]
                (tb, _) = pts[i + 1]
                if tb <= ta:
                    continue
                iv = to_int(va)
                filled = iv not in (None, 0)
                ax.add_patch(Rectangle((ta, y + 0.14), tb - ta, row_h - 0.5,
                                       facecolor=(color if filled else "none"),
                                       edgecolor=color,
                                       alpha=0.18 if filled else 1.0, lw=1.1))
                if iv is not None and (tb - ta) > (t1 - t0) * 0.02:
                    ax.text((ta + tb) / 2, y + (row_h - 0.22) / 2,
                            f"{iv:02X}", ha="center", va="center",
                            fontsize=8, color=color)
        ylabels.append(name)
        yticks.append(y + amp / 2 if kind == "bit" else y + (row_h - 0.22) / 2)
        y += row_h + gap

    y_top = y
    # ---- annotate the serial-line frame -------------------------------------
    hero_y = yticks[ylabels.index("serial_line")] - (row_h - 0.15) / 2
    for k in range(11):
        xb = t_start + k * bit_period
        ax.axvline(xb, color="#9ca3af", ls=(0, (4, 3)), lw=0.8,
                   ymin=0.02, ymax=0.98, alpha=0.6)
    for k in range(10):
        lvl = 1 if bits[k] == "1" else 0
        ax.plot(centres[k], hero_y + lvl * (row_h - 0.15), "o",
                color="#b45309", ms=5, zorder=5)
        ax.text(centres[k], y_top + 0.10, cells[k], ha="center", va="bottom",
                fontsize=8.5, color="#374151", fontweight="bold")
        ax.text(centres[k], y_top + 0.55, bits[k], ha="center", va="bottom",
                fontsize=9, color="#b45309")
    ax.text((t_start + centres[0]) / 2, y_top + 0.55, "idle",
            ha="center", va="bottom", fontsize=8, color="#9ca3af",
            fontstyle="italic")

    # ---- axis / labels ------------------------------------------------------
    unit_to_ns = {"1fs": 1e-6, "1ps": 1e-3, "10ps": 1e-2, "100ps": 1e-1,
                  "1ns": 1.0, "10ns": 10.0, "1us": 1e3}.get(ts, 1e-3)
    ax.xaxis.set_major_formatter(
        FuncFormatter(lambda v, _pos: f"{v * unit_to_ns:.0f}"))
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=9)
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.3, y_top + 1.15)
    ax.set_xlabel(f"simulation time (ns)   [VCD timescale {ts}, "
                  f"clks_per_bit={cpb}]", fontsize=10)
    ax.set_title(f"uart — REAL captured waveform (Icarus VCD): one 8-N-1 frame, "
                 f"LSB-first  =>  0x{data_val:02X}", fontsize=12, pad=26)
    ax.grid(axis="x", ls=":", alpha=0.25)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)

    fig.tight_layout()
    fig.savefig(OUT, dpi=140, bbox_inches="tight")
    print(f"wrote {OUT}  start@{t_start} bit_period={bit_period} "
          f"cpb={cpb} decoded=0x{data_val:02X} bits(LSB->MSB)={data_bits}")


if __name__ == "__main__":
    main()
