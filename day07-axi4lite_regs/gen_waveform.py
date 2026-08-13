#!/usr/bin/env python3
"""Render a REAL captured waveform from axi4lite_regs.vcd (produced by `make icarus`).

This is not a hand-drawn mock-up: it parses the VCD written by the Icarus
Verilog simulation of tb_axi4lite_regs and plots the first two transactions -- a
write of 0x12345678 to REG1 (0x04) followed by a read of the same register --
across all five AXI4-Lite channels (AW / W / B / AR / R), with their VALID/READY
handshakes. Every level and hex value shown is read straight from the VCD.

Usage:  python3 gen_waveform.py [axi4lite_regs.vcd] [docs/axi4lite_regs_waveform.png]
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.ticker import FuncFormatter

VCD = sys.argv[1] if len(sys.argv) > 1 else "axi4lite_regs.vcd"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs/axi4lite_regs_waveform.png"


def parse_vcd(path):
    """Parse a VCD, registering only the top testbench scope (depth 1)."""
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


RESP = {0: "OKAY", 2: "SLVERR", 1: "EXOKAY", 3: "DECERR"}


def main():
    sig, ts = parse_vcd(VCD)

    def g(name):
        return sig[name]["tv"] if name in sig else []

    clk_tv = [tt for (tt, _) in g("clk") if tt > 0]
    clk_period = (clk_tv[2] - clk_tv[0]) if len(clk_tv) >= 3 else 10000

    t_aw = first_time(g("awvalid"), lambda v: v == "1")
    t_b = first_time(g("bvalid"), lambda v: v == "1", after=t_aw)
    t_ar = first_time(g("arvalid"), lambda v: v == "1", after=t_b)
    t_r = first_time(g("rvalid"), lambda v: v == "1", after=t_ar)
    t0 = t_aw - 2 * clk_period
    t1 = t_r + 5 * clk_period

    # (label, signal, kind, base)
    rows = [
        ("clk",     "clk",     "bit", None),
        ("awaddr",  "awaddr",  "bus", "hex"),
        ("awvalid", "awvalid", "bit", None),
        ("awready", "awready", "bit", None),
        ("wdata",   "wdata",   "bus", "hex"),
        ("wstrb",   "wstrb",   "bus", "strb"),
        ("wvalid",  "wvalid",  "bit", None),
        ("wready",  "wready",  "bit", None),
        ("bresp",   "bresp",   "bus", "resp"),
        ("bvalid",  "bvalid",  "bit", None),
        ("bready",  "bready",  "bit", None),
        ("araddr",  "araddr",  "bus", "hex"),
        ("arvalid", "arvalid", "bit", None),
        ("arready", "arready", "bit", None),
        ("rdata",   "rdata",   "bus", "hex"),
        ("rresp",   "rresp",   "bus", "resp"),
        ("rvalid",  "rvalid",  "bit", None),
        ("rready",  "rready",  "bit", None),
    ]
    rows = [r for r in rows if r[1] in sig]

    fig, ax = plt.subplots(figsize=(15, 12.5))
    wr_c, rd_c, clk_c = "#2563eb", "#c026d3", "#334155"
    row_h, gap = 1.0, 0.22
    ylabels, yticks, y = [], [], 0.0

    def edges_in_window(tv):
        pts = [(t0, val_at(tv, t0))]
        for (tt, v) in tv:
            if t0 < tt <= t1:
                pts.append((tt, v))
        pts.append((t1, pts[-1][1]))
        return pts

    def color_for(name):
        if name == "clk":
            return clk_c
        return rd_c if name[0] in ("a", "r") and name.startswith(
            ("ar", "r")) else wr_c

    for (label, name, kind, base) in reversed(rows):
        tv = sig[name]["tv"]
        color = color_for(name)
        amp = row_h - 0.34
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
            ax.plot(xs, ys, color=color, lw=1.3, solid_joinstyle="miter")
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
                                       alpha=0.16 if filled else 1.0, lw=1.0))
                if iv is not None and (tb - ta) > (t1 - t0) * 0.02:
                    if base == "resp":
                        txt = RESP.get(iv, str(iv))
                    elif base == "strb":
                        txt = format(iv, "04b")
                    else:
                        txt = f"{iv:X}"
                    ax.text((ta + tb) / 2, y + (row_h - 0.24) / 2, txt,
                            ha="center", va="center", fontsize=7.5, color=color)
        ylabels.append(label)
        yticks.append(y + amp / 2 if kind == "bit" else y + (row_h - 0.24) / 2)
        y += row_h + gap

    # phase bands: WRITE (t_aw .. B accepted) and READ (t_ar .. R accepted)
    t_b_end = first_time(g("bvalid"), lambda v: v == "0", after=t_b)
    t_r_end = first_time(g("rvalid"), lambda v: v == "0", after=t_r)
    ax.axvspan(t_aw, t_b_end or t_b, color=wr_c, alpha=0.05, zorder=0)
    ax.axvspan(t_ar, t_r_end or t_r, color=rd_c, alpha=0.05, zorder=0)
    ax.text((t_aw + (t_b_end or t_b)) / 2, y + 0.05,
            "WRITE  (AW + W  →  B: OKAY)", ha="center", va="bottom",
            fontsize=10.5, color=wr_c, fontweight="bold")
    ax.text((t_ar + (t_r_end or t_r)) / 2, y + 0.05,
            "READ  (AR  →  R: data + OKAY)", ha="center", va="bottom",
            fontsize=10.5, color=rd_c, fontweight="bold")

    unit_to_ns = {"1fs": 1e-6, "1ps": 1e-3, "10ps": 1e-2, "100ps": 1e-1,
                  "1ns": 1.0, "10ns": 10.0, "1us": 1e3}.get(ts, 1e-3)
    ax.xaxis.set_major_formatter(
        FuncFormatter(lambda v, _pos: f"{v * unit_to_ns:.0f}"))
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=8.5)
    ax.set_xlim(t0, t1)
    ax.set_ylim(-0.3, y + 0.7)
    ax.set_xlabel(f"simulation time (ns)   [VCD timescale {ts}]", fontsize=10)
    aw = to_int(val_at(g("awaddr"), t_aw + clk_period))
    wd = to_int(val_at(g("wdata"), t_aw + clk_period))
    ax.set_title(f"axi4lite_regs — REAL captured waveform (Icarus VCD): "
                 f"write 0x{wd:08X} → REG @0x{aw:02X}, then read it back",
                 fontsize=12, pad=24)
    ax.grid(axis="x", ls=":", alpha=0.25)
    for sp in ("top", "right", "left"):
        ax.spines[sp].set_visible(False)

    fig.tight_layout()
    fig.savefig(OUT, dpi=140, bbox_inches="tight")
    print(f"wrote {OUT}  aw@{t_aw} b@{t_b} ar@{t_ar} r@{t_r}  "
          f"wdata=0x{wd:08X} addr=0x{aw:02X}")


if __name__ == "__main__":
    main()
