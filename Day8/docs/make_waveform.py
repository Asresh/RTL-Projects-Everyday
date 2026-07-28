#!/usr/bin/env python3
"""Render the REAL captured VCD from the iverilog run into a timing diagram.

Parses i2c_master.vcd, extracts the I2C bus + control signals, and draws the
first write transaction (reset release -> START -> address -> ACK -> data byte
-> data ACK -> STOP) as a cycle/time-accurate waveform.  This is a genuine
capture of the simulator output, not a hand-drawn diagram.
"""
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

VCD = "i2c_master.vcd"

# ----------------------------------------------------------------------------
# minimal VCD parser
# ----------------------------------------------------------------------------
id_by_name = {}
name_by_id = {}
width = {}
cur = {}
changes = {}          # id -> list of (time, value)

want = {
    "scl_i": "SCL",
    "sda_i": "SDA",
    "scl_oe": "scl_oe",
    "sda_oe": "sda_oe",
    "busy": "busy",
    "done": "done",
    "ack_error": "ack_error",
    "rst_n": "rst_n",
}

with open(VCD) as f:
    lines = f.readlines()

# --- header: map var ids to (short) names ---
in_defs = True
t = 0
scope = []
for ln in lines:
    s = ln.strip()
    if in_defs and s.startswith("$var"):
        # $var wire 1 ! scl_i $end   OR  $var reg 8 # rd_data [7:0] $end
        m = re.match(r"\$var\s+\w+\s+(\d+)\s+(\S+)\s+(\S+)", s)
        if m:
            w = int(m.group(1)); vid = m.group(2); nm = m.group(3)
            if nm in want and nm not in id_by_name:
                id_by_name[nm] = vid
                name_by_id[vid] = nm
                width[vid] = w
                changes[vid] = []
        continue
    if s == "$enddefinitions $end":
        in_defs = False
        continue
    if in_defs:
        continue
    # --- value change section ---
    if s.startswith("#"):
        t = int(s[1:])
    elif s and s[0] in "01xz":
        vid = s[1:]
        val = s[0]
        if vid in name_by_id:
            changes[vid].append((t, val))
    elif s and s[0] in "bB":
        parts = s.split()
        if len(parts) == 2:
            vid = parts[1]
            if vid in name_by_id:
                changes[vid].append((t, parts[0][1:]))

def val_at(nm, time):
    vid = id_by_name.get(nm)
    if vid is None:
        return "x"
    v = "x"
    for (tt, vv) in changes[vid]:
        if tt <= time:
            v = vv
        else:
            break
    return v

# ----------------------------------------------------------------------------
# choose a window: from just before reset release to end of the first STOP.
# done pulses at the end of each txn; take the first done as the window end.
# ----------------------------------------------------------------------------
done_id = id_by_name["done"]
first_done_t = None
for (tt, vv) in changes[done_id]:
    if vv == "1":
        first_done_t = tt
        break
if first_done_t is None:
    first_done_t = 40000

# VCD time unit is 1 ps (timescale 1ns/1ps); convert to ns for display.
PS_PER_NS = 1000
T_START = 0
T_END = first_done_t + 2000
STEP = 20  # ps sample step — finer than the 50 ns quarter phase

times = list(range(T_START, T_END, STEP))

# ---- decode: sample SDA on every SCL rising edge (real bus decode) ---------
scl_id = id_by_name["scl_i"]
scl_edges = []
prev = None
for (tt, vv) in changes[scl_id]:
    if prev == "0" and vv == "1":
        scl_edges.append(tt)
    prev = vv
sampled = [(te, val_at("sda_i", te + 1)) for te in scl_edges if te <= T_END]

# derive the actual bus levels (scl/sda already resolved in VCD as scl_i/sda_i)
def digital_trace(nm):
    ys = []
    for tt in times:
        v = val_at(nm, tt)
        ys.append(1 if v == "1" else (0 if v == "0" else 0.5))
    return ys

sig_order = [
    ("rst_n", "rst_n"),
    ("SCL",   "scl_i"),
    ("SDA",   "sda_i"),
    ("busy",  "busy"),
    ("done",  "done"),
    ("ack_error", "ack_error"),
]

fig, ax = plt.subplots(figsize=(15, 6.5))
fig.patch.set_facecolor("white")

row_h = 1.6
labels = []
xs_ns = [t / PS_PER_NS for t in times]
for i, (label, nm) in enumerate(sig_order):
    base = (len(sig_order) - 1 - i) * row_h
    ys = digital_trace(nm)
    # step plot
    plot_y = [base + 0.9 * y for y in ys]
    ax.step(xs_ns, plot_y, where="post", color="#0b7285", linewidth=1.7)
    ax.axhline(base, color="#dee2e6", linewidth=0.6, zorder=0)
    labels.append((base + 0.45, label))

for y, label in labels:
    ax.text(-140, y, label, ha="right", va="center",
            fontsize=11, family="monospace", fontweight="bold")

# annotate the bits sampled at each SCL rising edge (decoded from capture).
sda_base = (len(sig_order) - 1 - 2) * row_h   # SDA row
for (te, bv) in sampled:
    ax.text(te / PS_PER_NS, sda_base + 1.15, bv, ha="center", va="bottom",
            fontsize=8, color="#c92a2a", family="monospace")
if sampled:
    ax.text(sampled[0][0] / PS_PER_NS, sda_base + 1.55,
            "SDA @ SCL rising edges:  addr[6:0]=0101010 , R/W=0 , (ACK) , data=10100101(0xA5) , (ACK)",
            ha="left", va="bottom", fontsize=8.5, color="#c92a2a")

ax.set_title("Day 8 - I2C Master: captured VCD (first WRITE 0xA5 to slave 0x2A)\n"
             "iverilog simulation output  -  START / addr+R/W / ACK / data / ACK / STOP",
             fontsize=12, fontweight="bold")
ax.set_xlabel("time (ns)")
ax.set_yticks([])
ax.set_xlim(-160, T_END / PS_PER_NS)
ax.set_ylim(-0.4, len(sig_order) * row_h + 0.6)
for spine in ["top", "right", "left"]:
    ax.spines[spine].set_visible(False)
ax.grid(axis="x", color="#f1f3f5", linewidth=0.5)

fig.tight_layout()
fig.savefig("i2c_master_waveform.png", dpi=130, facecolor="white")
print("wrote i2c_master_waveform.png over window 0..%d ns" % T_END)
