#!/usr/bin/env python3
"""Draw the I2C master circuit / block diagram (Day 8)."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

fig, ax = plt.subplots(figsize=(14, 8))
fig.patch.set_facecolor("white")
ax.set_xlim(0, 100)
ax.set_ylim(0, 62)
ax.axis("off")

TEAL = "#0b7285"
DARK = "#1b3a4b"
GREY = "#495057"
FILL = "#e7f5f8"
FILL2 = "#fff4e6"
RED = "#c92a2a"

def box(x, y, w, h, text, fill=FILL, edge=TEAL, fs=10, bold=True):
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.15,rounding_size=0.8",
                       linewidth=1.8, edgecolor=edge, facecolor=fill)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=fs, family="monospace",
            fontweight="bold" if bold else "normal", color=DARK)

def arrow(x1, y1, x2, y2, color=GREY, style="-|>", lw=1.6, ls="-"):
    a = FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                        mutation_scale=14, linewidth=lw, color=color,
                        linestyle=ls, shrinkA=0, shrinkB=0)
    ax.add_patch(a)

def label(x, y, t, fs=9, color=GREY, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=color,
            family="monospace", fontstyle=style)

# ---- title -----------------------------------------------------------------
ax.text(50, 60, "Day 8  -  I2C Master Controller  (open-drain, single-master)",
        ha="center", va="center", fontsize=15, fontweight="bold", color=DARK)

# ---- outer chip boundary ----------------------------------------------------
chip = FancyBboxPatch((3, 6), 62, 50, boxstyle="round,pad=0.2,rounding_size=1.2",
                      linewidth=2.2, edgecolor=DARK, facecolor="#f8f9fa")
ax.add_patch(chip)
ax.text(6, 53.5, "i2c_master", ha="left", va="center", fontsize=11,
        fontweight="bold", color=DARK, family="monospace")

# ---- command interface (left inputs) ---------------------------------------
for i, sig in enumerate(["start", "rw", "addr[6:0]", "wr_data[7:0]"]):
    y = 48 - i * 4.0
    arrow(-0.5 + 0.5, y, 12, y, color=TEAL)
    label(1.5, y + 1.1, sig, fs=8.5, color=TEAL, ha="left", style="normal")

# ---- FSM ---
box(13, 30, 20, 16, "control FSM\n\nIDLE > START >\nADDR > A_ACK >\nWR/RD > ACK >\nSTOP > DONE",
    fill=FILL2, edge="#e8590c", fs=9)

# ---- bit timing / phase gen ---
box(13, 12, 20, 12,
    "bit-timing gen\n\nquarter cnt +\nphase[1:0] (0..3)\nSCL = phase>=2",
    fill=FILL, fs=9)

# ---- shift register ---
box(40, 30, 20, 16,
    "shift register\n[7:0]\n\nTX: MSB-first\nRX: <<{sda_i}\naddr / data",
    fill=FILL, fs=9)

# ---- open-drain drivers ---
box(40, 12, 20, 12,
    "open-drain\npad control\n\nscl_oe / sda_oe\nsample scl_i,\nsda_i",
    fill=FILL, fs=9)

# ---- internal arrows -------------------------------------------------------
arrow(33, 40, 40, 40, color=GREY)           # FSM -> shreg
label(36.5, 41.4, "load/\nshift", fs=7)
arrow(40, 36, 33, 36, color=GREY)           # shreg -> FSM (ack/data)
arrow(23, 30, 23, 24, color=GREY)           # FSM -> timing
label(25.8, 27, "state", fs=7.5)
arrow(19, 24, 19, 30, color=GREY, style="-|>")  # timing -> FSM (q_tick)
label(15.6, 27, "q_tick", fs=7.5)
arrow(33, 18, 40, 18, color=GREY)           # timing -> pads
label(36.5, 19.3, "phase", fs=7.5)
arrow(50, 24, 50, 30, color=GREY)           # pads <-> shreg
label(53.2, 27, "sda_i /\nsda_o", fs=7)

# ---- status outputs (bottom of chip going right/out via signals) -----------
for i, sig in enumerate(["busy", "done", "ack_error", "rd_data[7:0]"]):
    y = 46 - i * 4.0
    # route from FSM/shreg region to right edge of chip
    src = 60 if sig == "rd_data[7:0]" else 33
    arrow(60, y, 64.5, y, color="#2b8a3e")
    label(63.5, y + 1.1, sig, fs=8.5, color="#2b8a3e", ha="left", style="normal")

# ---- external open-drain bus + pull-ups + slave ----------------------------
# pull-up rail
ax.text(84, 54, "VDD", ha="center", fontsize=10, fontweight="bold", color=RED)
arrow(84, 53, 84, 50.5, color=RED, style="-")
# two pull-up resistors (zig-zag simplified as boxes)
for xr, nm in [(78, "Rp"), (90, "Rp")]:
    ax.add_patch(plt.Rectangle((xr - 1.2, 46), 2.4, 4, fill=False,
                               edgecolor=RED, linewidth=1.6))
    ax.text(xr, 48, nm, ha="center", va="center", fontsize=8, color=RED)
arrow(84, 50.5, 78, 50.5, color=RED, style="-")
arrow(84, 50.5, 90, 50.5, color=RED, style="-")

# bus lines
scl_y, sda_y = 42, 34
ax.plot([78, 96], [scl_y, scl_y], color=DARK, linewidth=2.2)
ax.plot([90, 96], [sda_y, sda_y], color=DARK, linewidth=2.2)
arrow(78, 46, 78, scl_y, color=RED, style="-")   # Rp -> SCL
arrow(90, 46, 90, sda_y, color=RED, style="-")   # Rp -> SDA
label(97.5, scl_y, "SCL", fs=10, color=DARK, ha="left", style="normal")
label(97.5, sda_y, "SDA", fs=10, color=DARK, ha="left", style="normal")

# master pad connections to bus
arrow(65, 18, 74, 18, color=GREY, style="-")
ax.plot([74, 74], [18, scl_y], color=GREY, linewidth=1.5, linestyle="--")
arrow(74, scl_y - 0.0, 78, scl_y, color=GREY, style="-")
ax.plot([70, 70], [16, sda_y], color=GREY, linewidth=1.5, linestyle="--")
arrow(65, 16, 70, 16, color=GREY, style="-")
arrow(70, sda_y, 76, sda_y, color=GREY, style="-")
label(72, 30, "open-drain\n(pull low or Hi-Z)", fs=7, color=GREY)

# slave block hanging off the bus
box(80, 14, 16, 12, "I2C slave\n(TB model)\n\naddr 0x2A\nACK / data",
    fill="#f3f0ff", edge="#7048e8", fs=9)
ax.plot([85, 85], [26, scl_y], color=DARK, linewidth=1.5)  # slave SCL tap
ax.plot([92, 92], [26, sda_y], color=DARK, linewidth=1.5)  # slave SDA tap
ax.add_patch(Circle((85, scl_y), 0.5, color=DARK))
ax.add_patch(Circle((92, sda_y), 0.5, color=DARK))
ax.add_patch(Circle((78, scl_y), 0.5, color=DARK))
ax.add_patch(Circle((76, sda_y), 0.5, color=DARK))

ax.text(50, 2.5,
        "START = SDA 1>0 while SCL high   |   STOP = SDA 0>1 while SCL high   |   "
        "data changes while SCL low, sampled while SCL high",
        ha="center", va="center", fontsize=8.5, color=GREY, fontstyle="italic")

fig.tight_layout()
fig.savefig("i2c_master_block.png", dpi=130, facecolor="white")
print("wrote i2c_master_block.png")
