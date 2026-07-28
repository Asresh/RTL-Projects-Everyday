#!/usr/bin/env python3
"""Render the uart circuit / block diagram to docs/uart_block.png.

This is a schematic of the *built* circuit (hand-drawn with matplotlib, not a
simulator capture): the transmit datapath (baud generator + TX FSM + LSB-first
shift register), the serial wire carrying the 8-N-1 frame, and the receive
datapath (two-flop synchronizer + start detect + mid-bit sampler + RX FSM +
shift register).  The dashed link is the testbench loopback (tx_serial ->
rx_serial).
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

TX_C  = "#2563eb"   # transmit
RX_C  = "#c026d3"   # receive
LINE_C = "#0f766e"  # serial line
BAUD_C = "#b45309"  # baud timing
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(14, 8.4))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.8, style="round"):
    if style == "round":
        p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.6,rounding_size=2",
                           linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3)
    else:
        p = Rectangle((x, y), w, h, linewidth=lw, edgecolor=ec,
                      facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.35)


def arrow(x1, y1, x2, y2, c=INK, lw=1.8, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=15, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def lbl(x, y, t, c=INK, fs=9, ha="center", style="italic"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c, zorder=5,
            fontstyle=style)


# ---- domain background bands ------------------------------------------------
ax.add_patch(Rectangle((1, 20), 40, 72, facecolor=TX_C, alpha=0.06, zorder=0))
ax.add_patch(Rectangle((59, 20), 40, 72, facecolor=RX_C, alpha=0.06, zorder=0))
ax.text(21, 94, "uart_tx  (transmitter)", ha="center", fontsize=12,
        color=TX_C, fontweight="bold")
ax.text(79, 94, "uart_rx  (receiver)", ha="center", fontsize=12,
        color=RX_C, fontweight="bold")

# ---- transmit side ----------------------------------------------------------
box(6, 72, 30, 11, "TX FSM\nIDLE → START → DATA → STOP", TX_C, fc="#eff6ff", fs=9.5)
box(6, 56, 30, 10, "baud generator\ncounter == clks_per_bit-1", BAUD_C,
    fc="#fff7ed", fs=9)
box(6, 40, 30, 10, "shift register\n{byte} shifted out LSB-first", TX_C,
    fc="#eff6ff", fs=9)

arrow(2, 80, 6, 80, TX_C); lbl(1.5, 80, "tx_start", TX_C, ha="right", style="normal")
arrow(2, 45, 6, 45, TX_C); lbl(1.5, 45, "tx_data[7:0]", TX_C, ha="right", style="normal")
arrow(21, 72, 21, 66, BAUD_C)          # FSM <-> baud
arrow(21, 56, 21, 50, TX_C)            # baud/FSM -> shift
arrow(36, 78, 44, 78, TX_C); lbl(40, 80.5, "tx_busy", TX_C, style="normal")
arrow(36, 74, 44, 74, TX_C); lbl(40, 71.5, "tx_done", TX_C, style="normal")

# ---- serial line ------------------------------------------------------------
box(38, 42, 24, 8, "serial line\n(idle high)", LINE_C, fc="#f0fdfa", fs=9.5)
arrow(36, 45, 38, 45, TX_C)            # shift reg -> line
arrow(62, 45, 64, 45, LINE_C)          # line -> rx
lbl(50, 55, "start · d0 d1 d2 d3 d4 d5 d6 d7 · stop", LINE_C, fs=9)
lbl(50, 52, "(8-N-1, LSB-first)", LINE_C, fs=8.5)
# testbench loopback
arrow(48, 42, 48, 30, "#6b7280", ls=(0, (4, 3)))
arrow(48, 30, 79, 30, "#6b7280", ls=(0, (4, 3)))
arrow(79, 30, 79, 40, "#6b7280", ls=(0, (4, 3)))
lbl(63, 27.5, "testbench loopback  tx_serial → rx_serial", "#6b7280", fs=8.5)

# ---- receive side -----------------------------------------------------------
box(64, 72, 30, 11, "RX FSM\nIDLE → START → DATA → STOP", RX_C, fc="#fdf4ff", fs=9.5)
box(64, 56, 30, 10, "2-FF synchronizer\n+ start-bit detect", RX_C, fc="#fdf4ff", fs=9)
box(64, 40, 30, 10, "mid-bit sampler → shift reg\n(centre sample, LSB-first)",
    BAUD_C, fc="#fff7ed", fs=8.5)

arrow(94, 78, 98, 78, RX_C); lbl(98.5, 78, "rx_valid", RX_C, ha="left", style="normal")
arrow(94, 74, 98, 74, RX_C); lbl(98.5, 74, "rx_frame_err", RX_C, ha="left", style="normal")
arrow(94, 45, 98, 45, RX_C); lbl(98.5, 45, "rx_data[7:0]", RX_C, ha="left", style="normal")
arrow(79, 56, 79, 50, RX_C)            # sync/detect -> sampler
arrow(79, 66, 79, 72, RX_C)            # detect -> FSM
arrow(79, 72, 79, 66, BAUD_C, rad=0.0) # FSM -> sampler timing (visual)

ax.text(50, 15,
        "A run-time baud divider (clks_per_bit) sets the bit period; the TX FSM "
        "frames each byte as start/8-data/stop and the RX FSM re-samples each "
        "bit at its centre.",
        ha="center", fontsize=9, color="#4b5563", fontstyle="italic")
ax.set_title("uart — circuit / block diagram (configurable full-duplex 8-N-1 UART)",
             fontsize=13, pad=12)

fig.tight_layout()
fig.savefig("docs/uart_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/uart_block.png")
