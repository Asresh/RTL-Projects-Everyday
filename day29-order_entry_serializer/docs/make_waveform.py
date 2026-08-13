#!/usr/bin/env python3
"""Render the REAL captured VCD from the Day29 Icarus run into a timing PNG.
Parses the VCD, samples the chosen signals on each rising clock edge, and draws
a cycle-based digital timing diagram of one order being serialized (including a
downstream backpressure stall)."""
import re, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "oe_egress_serializer.vcd"

# signals we want, by their leaf name inside the testbench/dut
WANT = ["clk", "rst", "in_valid", "in_ready", "m_valid", "m_ready", "m_data", "m_last"]

def parse_vcd(path):
    id2name, name2id = {}, {}
    widths = {}
    with open(path) as f:
        lines = f.readlines()
    # header: map ids -> names (take first occurrence of each wanted leaf name)
    i = 0
    while i < len(lines):
        ln = lines[i].strip()
        if ln.startswith("$var"):
            # $var wire 1 ! clk $end   /  $var wire 8 # m_data [7:0] $end
            parts = ln.split()
            width = int(parts[2]); sid = parts[3]; nm = parts[4]
            if nm in WANT and nm not in name2id:
                name2id[nm] = sid; id2name[sid] = nm; widths[nm] = width
        elif ln.startswith("$enddefinitions"):
            i += 1
            break
        i += 1
    # value changes
    t = 0
    cur = {n: "x" for n in WANT}
    timeline = []  # (time, dict copy) on changes
    def snap():
        timeline.append((t, dict(cur)))
    for ln in lines[i:]:
        ln = ln.strip()
        if not ln:
            continue
        if ln[0] == "#":
            t = int(ln[1:])
            continue
        if ln[0] in "01xz":
            sid = ln[1:]
            if sid in id2name:
                cur[id2name[sid]] = ln[0]
        elif ln[0] == "b":
            m = ln.split()
            if len(m) == 2 and m[1] in id2name:
                cur[id2name[m[1]]] = m[0][1:]  # strip 'b'
        # record snapshot lazily; we sample later anyway
        timeline.append((t, dict(cur)))
    return timeline, widths

def val_at(timeline, time, name):
    v = "x"
    for (t, d) in timeline:
        if t > time:
            break
        v = d.get(name, "x")
    return v

def main():
    timeline, widths = parse_vcd(VCD)
    # find rising clock edges (clk 0->1) as sample points, along with times
    edges = []
    prev = "x"
    seen = {}
    # collapse timeline to last value per time for clk
    times = sorted(set(t for t, _ in timeline))
    for t in times:
        c = val_at(timeline, t, "clk")
        if prev == "0" and c == "1":
            edges.append(t)
        prev = c
    # locate the first accept: in_valid=1 & in_ready=1 at a rising edge
    start_idx = None
    for k, t in enumerate(edges):
        if val_at(timeline, t, "in_valid") == "1" and val_at(timeline, t, "in_ready") == "1":
            start_idx = k
            break
    if start_idx is None:
        start_idx = 0
    lo = max(0, start_idx - 1)
    hi = min(len(edges), lo + 21)   # ~20 cycles
    sample_edges = edges[lo:hi]
    N = len(sample_edges)

    # build per-signal sampled sequences (sample value present DURING that cycle
    # => value just before the edge; use time-epsilon)
    def hexbyte(s):
        try:
            return "%02X" % int(s, 2)
        except ValueError:
            return "--"

    rows_bin = ["clk", "in_valid", "in_ready", "m_valid", "m_ready", "m_last"]
    seq = {r: [] for r in rows_bin}
    mdata = []
    for t in sample_edges:
        for r in rows_bin:
            if r == "clk":
                continue
            seq[r].append(val_at(timeline, t - 1, r))
        mdata.append(hexbyte(val_at(timeline, t - 1, "m_data")))

    # ---- draw ----
    disp = ["clk", "in_valid", "in_ready", "m_valid", "m_ready", "m_data", "m_last"]
    labels = {
        "clk": "clk", "in_valid": "in_valid", "in_ready": "in_ready",
        "m_valid": "m_valid", "m_ready": "m_ready", "m_data": "m_data[7:0]",
        "m_last": "m_last",
    }
    fig, ax = plt.subplots(figsize=(13.5, 6.2))
    yrow = {name: (len(disp) - 1 - k) * 2.0 for k, name in enumerate(disp)}
    hi_h, lo_h = 0.72, 0.0
    col_hi = "#1f6feb"; col_bus = "#8957e5"

    for x in range(N + 1):
        ax.axvline(x, color="#e6e6e6", lw=0.6, zorder=0)

    def draw_bin(name, values, clk=False):
        y0 = yrow[name]
        prev = None
        for x, v in enumerate(values):
            if clk:
                # two ticks per cycle: low then high
                ax.plot([x, x+0.5, x+0.5, x+1.0], [y0, y0, y0+hi_h, y0+hi_h],
                        color="#444", lw=1.6)
                ax.plot([x+1.0, x+1.0], [y0+hi_h, y0], color="#444", lw=1.6)
                continue
            hv = hi_h if v == "1" else lo_h
            ax.plot([x, x+1], [y0+hv, y0+hv], color=col_hi if v == "1" else "#999",
                    lw=2.0)
            if prev is not None and prev != v:
                ax.plot([x, x], [y0+(hi_h if prev=="1" else 0), y0+hv],
                        color=col_hi, lw=2.0)
            prev = v

    # clock
    y0 = yrow["clk"]
    for x in range(N):
        ax.plot([x, x+0.5, x+0.5, x+1.0], [y0, y0, y0+hi_h, y0+hi_h], color="#444", lw=1.7)
    # binary rows
    for r in ["in_valid", "in_ready", "m_valid", "m_ready", "m_last"]:
        draw_bin(r, seq[r])
    # bus row (m_data)
    yb = yrow["m_data"]
    for x, hx in enumerate(mdata):
        active = seq["m_valid"][x] == "1"
        fc = "#efe9fb" if active else "#f4f4f4"
        ec = col_bus if active else "#cfcfcf"
        ax.add_patch(Rectangle((x+0.06, yb+0.06), 0.88, hi_h-0.12, fc=fc, ec=ec, lw=1.4))
        ax.text(x+0.5, yb+hi_h/2, hx, ha="center", va="center", fontsize=8.5,
                family="monospace", color="#3a1f6e" if active else "#bbb")

    # highlight the accept cycle & the stall cycles
    for x in range(N):
        if seq["in_valid"][x] == "1" and seq["in_ready"][x] == "1":
            ax.add_patch(Rectangle((x, -0.6), 1, len(disp)*2.0+0.2, fc="#1f6feb",
                                   ec="none", alpha=0.06, zorder=0))
            ax.text(x+0.5, len(disp)*2.0-0.2, "accept", ha="center", va="bottom",
                    fontsize=8, color="#1f6feb")
        if seq["m_valid"][x] == "1" and seq["m_ready"][x] == "0":
            ax.add_patch(Rectangle((x, -0.6), 1, len(disp)*2.0+0.2, fc="#d1242f",
                                   ec="none", alpha=0.07, zorder=0))
            ax.text(x+0.5, len(disp)*2.0-0.2, "stall", ha="center", va="bottom",
                    fontsize=8, color="#d1242f")

    for name in disp:
        ax.text(-0.25, yrow[name]+hi_h/2, labels[name], ha="right", va="center",
                fontsize=10, family="monospace")
    ax.set_xlim(-2.6, N)
    ax.set_ylim(-0.8, len(disp)*2.0+0.4)
    ax.set_xticks([x+0.5 for x in range(N)])
    ax.set_xticklabels([str(x) for x in range(N)], fontsize=8)
    ax.set_xlabel("clock cycle (sampled from the real Icarus VCD)", fontsize=10)
    ax.set_yticks([])
    for s in ["top", "right", "left"]:
        ax.spines[s].set_visible(False)
    ax.set_title("Day 29 - oe_egress_serializer : captured egress of one 17-byte order frame\n"
                 "('O' type -> token -> side -> price -> shares -> symbol -> XOR checksum on m_last)",
                 fontsize=11)
    plt.tight_layout()
    plt.savefig("docs/oe_egress_serializer_waveform.png", dpi=140)
    print("wrote docs/oe_egress_serializer_waveform.png  (%d cycles)" % N)

if __name__ == "__main__":
    main()
