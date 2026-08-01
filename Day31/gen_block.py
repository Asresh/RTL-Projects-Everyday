#!/usr/bin/env python3
"""Render the strat_trigger circuit / block diagram to
docs/strat_trigger_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator
capture): the registered rule table, the N parallel marketable comparators fed
by the live BBO, the throttle gate (cooldown + inflight), the priority encoder
selecting the lowest-index marketable rule, the one-shot arm-clear feedback, and
the registered child-order egress + status counters.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

RUL_C = "#2563eb"   # rule table / config
CMP_C = "#0f766e"   # compare cone
THR_C = "#c026d3"   # throttle
ORD_C = "#b45309"   # order egress
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(15.4, 9.4))
ax.set_xlim(0, 116)
ax.set_ylim(0, 100)
ax.axis("off")


def box(x, y, w, h, label, ec, fc="white", fs=10, lw=1.9):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.5,rounding_size=2",
                 linewidth=lw, edgecolor=ec, facecolor=fc, zorder=3))
    ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
            fontsize=fs, color=INK, zorder=4, linespacing=1.3)


def arrow(x1, y1, x2, y2, c=INK, lw=1.9, ls="-", rad=0.0):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>",
                 mutation_scale=14, linewidth=lw, color=c, linestyle=ls,
                 zorder=2, connectionstyle=f"arc3,rad={rad}"))


def label(x, y, t, c=INK, fs=8.4, style="italic", ha="center"):
    ax.text(x, y, t, ha=ha, va="center", fontsize=fs, color=c,
            fontstyle=style, zorder=5)


# ---- title ------------------------------------------------------------------
ax.text(58, 97, "strat_trigger — Tick-to-Trade Marketable-Order Trigger Engine",
        ha="center", va="center", fontsize=14.5, color=INK, weight="bold")
ax.text(58, 92.5,
        "one combinational cone: N parallel compares → throttle gate → priority encoder → registered order  (deterministic 1-clock BBO→fire)",
        ha="center", va="center", fontsize=9.2, color="#6b7280", fontstyle="italic")

# ---- config port ------------------------------------------------------------
box(2, 74, 20, 12,
    "CONFIG PORT\ncfg_we / idx / arm\nside / px / qty / token",
    RUL_C, fc="#eff6ff", fs=8.6)

# ---- rule table -------------------------------------------------------------
box(2, 40, 24, 28,
    "RULE TABLE  (registered, N slots)\n\narm[i]  side[i]\nlim_px[i]\nqty[i]  token[i]",
    RUL_C, fc="#eff6ff", fs=9)
arrow(12, 74, 12, 68.5, c=RUL_C)     # config -> table
label(15.5, 71.2, "1 write/clk", c=RUL_C, fs=7.8, ha="left")

# ---- BBO input --------------------------------------------------------------
box(2, 20, 24, 12,
    "BBO TICK  (from Day 27 book)\nbest_bid / bid_ok\nbest_ask / ask_ok\nbbo_valid",
    CMP_C, fc="#ecfdf5", fs=8.4)

# ---- compare cone -----------------------------------------------------------
box(36, 34, 26, 40,
    "N PARALLEL COMPARATORS\n\nBUY : ask_ok & ask ≤ lim_px[i]\nSELL: bid_ok & bid ≥ lim_px[i]\n\nmarketable[i] =\n  bbo_valid & arm[i] & hit",
    CMP_C, fc="#ecfdf5", fs=9)
arrow(26, 54, 36, 54, c=RUL_C)        # rule table -> comparators
label(31, 56.4, "lim/side/arm", c=RUL_C, fs=7.6)
arrow(26, 26, 33, 26, c=CMP_C)        # bbo -> comparators
arrow(33, 26, 33, 40, c=CMP_C)
arrow(33, 40, 36, 40, c=CMP_C)
label(30, 22, "bid/ask/ok", c=CMP_C, fs=7.6, ha="left")

# ---- throttle gate ----------------------------------------------------------
box(70, 56, 24, 18,
    "THROTTLE GATE\ncan_fire =\n any marketable\n & cooldown==0\n & inflight<MAX",
    THR_C, fc="#fdf4ff", fs=8.8)
arrow(62, 60, 70, 62, c=CMP_C)        # marketable -> gate
label(66, 63.5, "marketable[ ]", c=CMP_C, fs=7.4)

# cooldown + inflight counters feed the gate
box(70, 38, 24, 12,
    "COOLDOWN cnt\n(load=cooldown_i on fire,\nelse count down)",
    THR_C, fc="#fdf4ff", fs=8.0)
box(70, 22, 24, 12,
    "INFLIGHT cnt\n+1 on fire, −1 on ack_i\n(≤ MAX_INFLIGHT)",
    THR_C, fc="#fdf4ff", fs=8.0)
arrow(82, 50, 82, 56, c=THR_C)        # cooldown -> gate
arrow(88, 34, 88, 56, c=THR_C, rad=-0.15)  # inflight -> gate

# ---- priority encoder -------------------------------------------------------
box(70, 78, 24, 10,
    "PRIORITY ENCODER\nlowest-index wins → win_idx",
    CMP_C, fc="#ecfdf5", fs=8.8)
arrow(52, 74, 78, 78, c=CMP_C, rad=-0.12)  # marketable -> prio enc
label(62, 79.5, "marketable[ ]", c=CMP_C, fs=7.2)

# ---- order egress -----------------------------------------------------------
box(100, 50, 14, 26,
    "ORDER\nREG\n(egress)\n\nfire_o\nfire_idx\nside/px\nqty/token",
    ORD_C, fc="#fffbeb", fs=8.6)
arrow(94, 65, 100, 63, c=THR_C)       # gate -> order reg
arrow(94, 83, 99, 83, c=CMP_C)        # win_idx -> order reg
arrow(99, 83, 99, 72, c=CMP_C)
arrow(99, 72, 100, 72, c=CMP_C)
label(97, 68, "win_idx", c=CMP_C, fs=7.2, ha="left")

# to risk gate
arrow(114, 63, 116, 63, c=ORD_C)
label(112.5, 59.5, "→ Day 26\nrisk gate", c=ORD_C, fs=7.6, ha="left", style="normal")

# ---- one-shot arm-clear feedback -------------------------------------------
# dashed feedback: fire -> clear arm[win_idx] in the rule table (one-shot)
ax.add_patch(FancyArrowPatch((82, 78), (14, 68.2), arrowstyle="-|>",
             mutation_scale=13, linewidth=1.7, color="#dc2626",
             linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=0.28"))
label(46, 84.5, "one-shot arm-clear:  fire ⇒ arm[win_idx]:=0", c="#dc2626", fs=8.2)

# ---- ack input --------------------------------------------------------------
arrow(66, 28, 70, 28, c=THR_C)
label(63, 30.2, "ack_i", c=THR_C, fs=7.8, ha="right")

# ---- status outputs ---------------------------------------------------------
box(100, 24, 14, 18,
    "STATUS REG\narmed_cnt\ninflight\nblocked\ncooldown_active",
    ORD_C, fc="#fffbeb", fs=8.0)
arrow(94, 44, 100, 36, c=THR_C, rad=0.1)

# ---- footer note ------------------------------------------------------------
ax.text(58, 8,
        "All rule state + outputs are registered; the compare→encode→gate path is pure combinational logic on the current state.\n"
        "Firing depth is fixed by N (not by how many rules match) ⇒ worst-case latency == typical.  At most ONE fire per clock.",
        ha="center", va="center", fontsize=8.6, color="#374151", fontstyle="italic",
        linespacing=1.5)

fig.tight_layout()
fig.savefig("docs/strat_trigger_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/strat_trigger_block.png")
