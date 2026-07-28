#!/usr/bin/env python3
"""Render a REAL captured waveform from seq_divider.vcd (produced by `make icarus`).

This is not a hand-drawn mock-up: it parses the VCD written by the Icarus
Verilog simulation of tb_seq_divider and plots the first division (200 / 7),
including the DUT's *internal* partial remainder (`acc`) and partial quotient
(`quo`) so the iterative shift-subtract convergence is visible cycle by cycle.
Every value shown is read straight out of the VCD.

Usage:  python3 gen_waveform.py [seq_divider.vcd] [docs/seq_divider_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.ticker import FuncFormatter

VCD = sys.argv[1] if len(sys.argv) > 1 else "seq_divider.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/seq_divider_waveform.png"


def parse_vcd(path):
    """Parse a VCD keeping *fully-qualified* signal names (scope.scope.leaf) so
    identically named nets in different scopes never collide."""
    code2names, widths, changes = {}, {}, {}
    timescale, want_ts = None, False
    t, in_defs = 0, True
    scope = []
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
                    scope.append(s.split()[2])
                elif s.startswith("$upscope"):
                    if scope:
                        scope.pop()
                elif s.startswith("$var"):
                    p = s.split()
                    width, code, leaf = int(p[2]), p[3], p[4]
                    full = ".".join(scope + [leaf])
                    code2names.setdefault(code, []).append(full)
                    widths[full] = width
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


def first_time(tv, pred, after=-1):
    for (tt, v) in tv:
        if tt > after and pred(v):
            return tt
    return None


def to_int(v):
    try:
        return int(v.replace("x", "0").replace("z", "0"), 2)
    except (ValueError, TypeError, AttributeError):
        return None


def main():
    sig, ts = parse_vcd(VCD)
    T = "tb_seq_divider"

    def G(path):
        return sig[path]["tv"] if path in sig else []

    clk_tv = [tt for (tt, _) in G(f"{T}.clk") if tt > 0]
    clk_period = (clk_tv[2] - clk_tv[0]) if len(clk_tv) >= 3 else 10000

    t_start = first_time(G(f"{T}.start"), lambda v: v == "1")
    t_done = first_time(G(f"{T}.done"), lambda v: v == "1", after=t_start)
    t0 = t_start - 2 * clk_period
    t1 = t_done + 3 * clk_period

    a_val = to_int(val_at(G(f"{T}.dividend"), t_start + clk_period))
    b_val = to_int(val_at(G(f"{T}.divisor"), t_start + clk_period))
    q_val = to_int(val_at(G(f"{T}.quotient"), t1 - clk_period))
    r_val = to_int(val_at(G(f"{T}.remainder"), t1 - clk_period))

    # (label, vcd-path, kind, base)   base: "dec" | "hex" | "state"
    rows = [
        ("clk",        f"{T}.clk",         "bit", None),
        ("start",      f"{T}.start",       "bit", None),
        ("busy",       f"{T}.busy",        "bit", None),
        ("state",      f"{T}.dut.state",   "bus", "state"),
        ("count",      f"{T}.dut.count",   "bus", "dec"),
        ("dividend",   f"{T}.dividend",    "bus", "dec"),
        ("divisor",    f"{T}.divisor",     "bus", "dec"),
        ("acc (rem)",  f"{T}.dut.acc",     "bus", "dec"),
        ("quo (quot)", f"{T}.dut.quo",     "bus", "dec"),
        ("done",       f"{T}.done",        "bit", None),
        ("quotient",   f"{T}.quotient",    "bus", "dec"),
        ("remainder",  f"{T}.remainder",   "bus", "dec"),
    ]
    rows = [r for r in rows if r[1] in sig]
    STATE_NAME = {0: "IDLE", 1: "CALC", 2: "DONE"}

    fig, ax = plt.subplots(figsize=(15, 8.6))
    ctrl_c, fsm_c, acc_c, quo_c, res_c = \
        "#2563eb", "#6b7280", "#0f766e", "#c026d3", "#b45309"
    row_h, gap = 1.0, 0.30
    ylabels, yticks, y = [], [], 0.0

    def edges_in_window(tv):
        pts = [(t0, val_at(tv, t0))]
        for (tt, v) in tv:
            if t0 < tt <= t1:
                pts.append((tt, v))
        pts.append((t1, pts[-1][1]))
        return pts

    def color_for(label):
        if label in ("acc (rem)", "remainder"):
            return acc_c
        if label in ("quo (quot)", "quotient"):
            return quo_c
        if label in ("state", "count"):
            return fsm_c
        return ctrl_c

    for (label, path, kind, base) in reversed(rows):
        tv = sig[path]["tv"]
        color = color_for(label)
        amp = row_h - 0.30
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
            ax.plot(xs, ys, color=color, lw=1.4, solid_joinstyle="miter")
        else:  # bus
            for i in range(len(pts) - 1):
                (ta, va) = pts[i]
                (tb, _) = pts[i + 1]
                if tb <= ta:
                    continue
                iv = to_int(va)
                filled = iv not in (None, 0)
                ax.add_patch(Rectangle((ta, y + 0.12), tb - ta, row_h - 0.46,
                                       facecolor=(color if filled else "none"),
                                       edgecolor=color,
                                       alpha=0.16 if filled else 1.0, lw=1.0))
                if iv is not None and (tb - ta) > (t1 - t0) * 0.018:
                    txt = (STATE_NAME.get(iv, str(iv)) if base == "state"
                           else (f"{iv:02X}" if base == "hex" else str(iv)))
                    ax.text((ta + tb) / 2, y + (row_h - 0.22) / 2, txt,
                            ha="center", va="center", fontsize=7.5, color=color)
        ylabels.append(label)
        yticks.append(y + amp / 2 if kind == "bit" else y + (row_h - 0.22) / 2)
        y += row_h + gap

    # shade the CALC region (from VCD state == CALC(1))
    st = G(f"{T}.dut.state")
    t_calc0 = first_time(st, lambda v: to_int(v) == 1, after=t_start - 1)
    t_calc1 = first_time(st, lambda v: to_int(v) != 1, after=t_calc0)
    if t_calc0 and t_calc1:
        ax.axvspan(t_calc0, t_calc1, color="#0f766e", alpha=0.05, zorder=0)
        ax.text((t_calc0 + t_calc1) / 2, y + 0.05,
                "CALC — 8 restoring iterations (acc / quo converge)",
                ha="center", va="bottom", fontsize=9.5, color="#0f766e",
                fontweight="bold")

    unit_to_ns = {"1fs": 1e-6, "1ps": 1e-3, "10ps": 1e-2, "100ps": 1e-1,
                  "1ns": 1.0, "10ns": 10.0, "1us": 1e3}.get(ts, 1e-3)
    ax.xaxis.set_major_formatter(
        FuncFormatter(lambda v, _pos: f"{v * unit_to_ns:.0f}"))
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=9)
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.3, y + 0.6)
    ax.set_xlabel(f"simulation time (ns)   [VCD timescale {ts}]", fontsize=10)
    ax.set_title(f"seq_divider — REAL captured waveform (Icarus VCD): "
                 f"{a_val} / {b_val} = {q_val} remainder {r_val}",
                 fontsize=12, pad=22)
    ax.grid(axis="x", ls=":", alpha=0.25)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)

    fig.tight_layout()
    fig.savefig(OUT, dpi=140, bbox_inches="tight")
    print(f"wrote {OUT}  {a_val}/{b_val} = {q_val} r {r_val}  "
          f"start@{t_start} done@{t_done}")


if __name__ == "__main__":
    main()
