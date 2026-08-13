#!/usr/bin/env python3
"""Render docs/crc32_parallel_waveform.png from the REAL Icarus-generated VCD.

Samples the design at each rising clock edge and draws a digital timing diagram
of the first frame ("123456789" -> 0xCBF43926) through the 8-bit-slice engine.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

VCD = "../crc32_parallel.vcd"
CODES = {"clk": "/", "init": ")", "en": "(", "last": "*",
         "data": "'", "crc": "<", "rvalid": "$", "result": "%"}

# ---- parse VCD value-change stream --------------------------------------
inv = {v: k for k, v in CODES.items()}
cur = {k: "x" for k in CODES}
timeline = []          # (time, snapshot dict)
t = 0
with open(VCD) as f:
    body = False
    for line in f:
        line = line.strip()
        if not body:
            if line.startswith("$enddefinitions"):
                body = True
            continue
        if not line:
            continue
        if line[0] == "#":
            timeline.append((t, dict(cur)))
            t = int(line[1:])
        elif line[0] in "01xz":
            code = line[1:]
            if code in inv:
                cur[inv[code]] = line[0]
        elif line[0] == "b":
            val, code = line[1:].split()
            if code in inv:
                cur[inv[code]] = val
    timeline.append((t, dict(cur)))

def val_at(time):
    snap = {k: "x" for k in CODES}
    for tt, s in timeline:
        if tt <= time:
            snap = s
        else:
            break
    return snap

# timescale is 1ns/1ps -> VCD time unit = 1ps. Clock period = 10ns = 10000.
# Rising edges at 5000, 15000, 25000, ...  Find the frame where init pulses.
edges = list(range(5000, 400000, 10000))
def sample(time):
    # sample just after the posedge so registered values have settled
    return val_at(time + 100)

start_idx = None
for i, e in enumerate(edges):
    if sample(e)["init"] == "1":
        start_idx = i
        break
assert start_idx is not None, "no init edge found"

# take the frame + a couple trailing cycles (result strobe)
win = edges[start_idx - 1: start_idx + 12]
samples = [sample(e) for e in win]

# ---- draw ----------------------------------------------------------------
ascii_map = list("123456789")
rows = [
    ("clk",     "clk",     "clk"),
    ("init",    "init",    "bit"),
    ("en",      "en",      "bit"),
    ("last",    "last",    "bit"),
    ("data",    "data[7:0]", "bus"),
    ("crc",     "crc_r[31:0]", "bus"),
    ("rvalid",  "result_valid", "bit"),
    ("result",  "result[31:0]", "bus"),
]

n = len(samples)
fig, ax = plt.subplots(figsize=(13, 6.2))
ax.set_xlim(-0.6, n)
ax.set_ylim(0, len(rows))
ax.axis("off")

BLUE = "#1f4e8c"; VIOLET = "#6d3bcf"; GREY = "#888"; GREEN = "#1b8a4b"
lo, hi = 0.18, 0.78

for r, (key, label, kind) in enumerate(rows):
    y = len(rows) - 1 - r
    ax.text(-0.65, y + 0.5, label, ha="right", va="center",
            fontsize=10, family="monospace", color="#222")
    ax.plot([-0.05, n], [y, y], color="#eee", lw=0.6, zorder=0)

    for c in range(n):
        x0, x1 = c, c + 1
        if kind == "clk":
            # two clock pulses per sampled cycle for visual clock
            ax.plot([x0, x0, x0+0.5, x0+0.5, x1, x1],
                    [y+lo, y+hi, y+hi, y+lo, y+lo, y+hi],
                    color=BLUE, lw=1.4)
        elif kind == "bit":
            v = samples[c][key]
            hgh = (v == "1")
            yv = y + (hi if hgh else lo)
            ax.plot([x0, x1], [yv, yv], color=(GREEN if hgh else GREY), lw=1.8)
            if c > 0:
                pv = samples[c-1][key]
                if pv != v and pv in ("0", "1"):
                    ax.plot([x0, x0], [y+lo, y+hi], color="#555", lw=1.0)
        else:  # bus
            raw = samples[c][key]
            try:
                num = int(raw, 2)
                txt = f"{num:X}"
            except ValueError:
                txt = "x"
            col = VIOLET if key == "crc" else (GREEN if key == "result" else BLUE)
            ax.add_patch(Rectangle((x0+0.04, y+lo), 0.92, hi-lo,
                                   facecolor="none", edgecolor=col, lw=1.3))
            ax.text((x0+x1)/2, y+(lo+hi)/2, txt, ha="center", va="center",
                    fontsize=8.0, family="monospace", color=col)

# byte annotations on the data row
data_row_y = len(rows) - 1 - 4
for c in range(n):
    if samples[c]["en"] == "1":
        raw = samples[c]["data"]
        try:
            ch = chr(int(raw, 2))
            if ch.isprintable():
                ax.text(c+0.5, data_row_y+0.03, f"'{ch}'", ha="center",
                        va="top", fontsize=7, color="#a33")
        except Exception:
            pass

ax.set_title("Day 22 — Parallel CRC-32 (8-bit slice): frame \"123456789\" -> FCS 0xCBF43926\n"
             "captured from the Icarus Verilog VCD (real simulator run)",
             fontsize=11, color="#1f2d4d", pad=12)
# cycle ruler
for c in range(n):
    ax.text(c+0.5, len(rows)+0.02, str(c), ha="center", va="bottom",
            fontsize=7, color="#aaa")

plt.tight_layout()
plt.savefig("crc32_parallel_waveform.png", dpi=140, bbox_inches="tight")
print("wrote crc32_parallel_waveform.png")
