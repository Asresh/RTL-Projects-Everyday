#!/usr/bin/env python3
"""Render the sha256_core circuit / block diagram to docs/sha256_core_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator
capture): the 16-word rolling message-schedule window that produces one W[t] per
clock without a 64-word RAM, the 64-round compression datapath (the a..h working
register looped through the Ch/Maj/Sigma mixing network with the T1/T2 adders),
the on-the-fly K[t] round-constant ROM, and the eight running hash registers
H0..H7 that both feed the Davies-Meyer feed-forward and receive the final add.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

SCH_C = "#7c3aed"   # message schedule
CMP_C = "#0f766e"   # compression datapath
MIX_C = "#b45309"   # Ch/Maj/Sigma mixing + adders
K_C   = "#c026d3"   # K[t] ROM / control
H_C   = "#2563eb"   # running hash / feed-forward
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(16.0, 10.0))
ax.set_xlim(0, 132)
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


def add(x, y, r=1.7, c=MIX_C, sym="+"):
    ax.add_patch(Circle((x, y), r, edgecolor=c, facecolor="white",
                 lw=1.7, zorder=4))
    ax.text(x, y, sym, ha="center", va="center", fontsize=12, color=c, zorder=5)


# ---- title ------------------------------------------------------------------
ax.text(66, 97, "sha256_core - SHA-256 Iterative Hash Core (FIPS 180-4)",
        ha="center", va="center", fontsize=14.5, color=INK, weight="bold")
ax.text(66, 92.6,
        "one 512-bit block folded into the 256-bit digest in a fixed 66 clocks (1 load + 64 rounds + feed-forward); "
        "schedule kept in a 16-word rolling window, not a 64-word RAM",
        ha="center", va="center", fontsize=9.0, color="#6b7280", fontstyle="italic")

# =====================  MESSAGE SCHEDULE (top band)  ========================
box(3, 74, 20, 12,
    "512-bit block\nload -> w[0..15]\n(word0 = [511:480])", SCH_C, fc="#f5f3ff", fs=8.6)

# the 16-word rolling window
box(28, 74, 40, 12,
    "16-WORD ROLLING SCHEDULE WINDOW   w[0] w[1] ... w[15]\n"
    "shift-register: each clock w[i] <= w[i+1]",
    SCH_C, fc="#faf5ff", fs=8.8)
arrow(23, 80, 27.9, 80, c=SCH_C)

# sigma recurrence -> new word into w[15]
add(88, 80, r=2.2, c=SCH_C, sym="+")
box(74, 74, 12, 12, "sigma1(w[14])\n+ w[9]\n+ sigma0(w[1])\n+ w[0]", MIX_C, fc="#fff7ed", fs=7.6)
arrow(68, 80, 73.9, 80, c=SCH_C)
arrow(86, 80, 85.6, 80, c=MIX_C)                          # box -> adder (short)
label(96, 84.4, "new word W[t+16]", c=SCH_C, fs=7.8)
# feedback of new word back into w[15]
ax.add_patch(FancyArrowPatch((90.2, 81.5), (58, 86.4),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.6,
             color=SCH_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=-0.3"))
label(72, 89.4, "shifted into w[15] -> 16 regs cover all 64 words W[0..63]",
      c=SCH_C, fs=8.0)

# W[t] tap down to the compression datapath
arrow(33, 74, 33, 63.2, c=SCH_C)
label(37.5, 68.5, "W[t] = w[0]  (one word per clock)", c=SCH_C, fs=8.0, ha="left")

# =====================  COMPRESSION DATAPATH (middle band)  =================
box(3, 40, 20, 16,
    "WORKING STATE\nregister  a b c d\n           e f g h\n(8 x 32b)", CMP_C, fc="#ecfdf5", fs=8.6)
label(13, 37.4, "loaded from H0..H7 at each block start", c=CMP_C, fs=7.4)

# mixing / round function
box(30, 46, 16, 10, "Sigma1(e)\nCh(e,f,g)\n= (e&f)^(~e&g)", MIX_C, fc="#fff7ed", fs=8.0)
box(30, 32, 16, 10, "Sigma0(a)\nMaj(a,b,c)", MIX_C, fc="#fff7ed", fs=8.2)
arrow(23, 50, 29.9, 50, c=CMP_C)
arrow(23, 44, 29.9, 37, c=CMP_C)

# T1 adder
add(60, 51, r=2.4, c=MIX_C, sym="+")
label(60, 56.2, "T1 = h + Sigma1(e) + Ch + K[t] + W[t]", c=MIX_C, fs=8.0)
arrow(46, 51, 57.6, 51, c=MIX_C)
# K[t] ROM into T1
box(48, 60, 12, 7, "K[t] ROM\n(64 consts)", K_C, fc="#fdf4ff", fs=8.0)
arrow(56, 60, 59, 53.2, c=K_C)
# W[t] into T1  (from the schedule tap, redraw short stub)
arrow(33, 63.2, 57.9, 52.4, c=SCH_C, ls=(0, (4, 3)), rad=0.05)

# T2 adder
add(60, 37, r=2.4, c=MIX_C, sym="+")
label(60, 32.0, "T2 = Sigma0(a) + Maj(a,b,c)", c=MIX_C, fs=8.0)
arrow(46, 37, 57.6, 37, c=MIX_C)

# new a = T1 + T2 ; new e = d + T1
add(78, 44, r=2.4, c=CMP_C, sym="+")
arrow(62.4, 51, 76.4, 45.2, c=MIX_C)
arrow(62.4, 37, 76.4, 42.8, c=MIX_C)
label(78, 48.6, "a' = T1+T2", c=CMP_C, fs=7.8)
label(84, 40.2, "e' = d+T1;  h=g g=f f=e d=c c=b b=a  (shift a..h)", c=CMP_C, fs=7.6, ha="left")

# feedback into the working register (next round)
ax.add_patch(FancyArrowPatch((80.4, 44), (13, 56.4),
             arrowstyle="-|>", mutation_scale=14, linewidth=1.7,
             color=CMP_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=0.32"))
label(45, 61.0, "round feedback - working state re-clocked for 64 rounds",
      c=CMP_C, fs=8.2)

# =====================  RUNNING HASH / FEED-FORWARD (bottom band)  ==========
box(3, 12, 26, 12,
    "RUNNING HASH  H0..H7  (8 x 32b)\n= IV on first block, else previous digest",
    H_C, fc="#eff6ff", fs=8.6)

# feed-forward add: H := H + (a..h)
add(46, 18, r=2.6, c=H_C, sym="+")
label(46, 23.4, "feed-forward add", c=H_C, fs=8.0)
arrow(29, 18, 43.4, 18, c=H_C)                            # H -> add
# working state (final a..h) into feed-forward add
ax.add_patch(FancyArrowPatch((13, 39.6), (45, 20.4),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.6,
             color=CMP_C, linestyle=(0, (4, 3)), zorder=1,
             connectionstyle="arc3,rad=0.18"))
label(30, 30.0, "final (a..h)", c=CMP_C, fs=7.6)

# commit back to H  and  out as digest
ax.add_patch(FancyArrowPatch((46, 20.6), (16, 24),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.6,
             color=H_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=0.3"))
label(33, 26.4, "commit -> H (chaining)", c=H_C, fs=7.4)
box(64, 13, 16, 10, "digest_o\n256-bit\nvalid / done", H_C, fc="#eff6ff", fs=8.4)
arrow(48.6, 18, 63.9, 18, c=H_C)

# also H feeds the working register at block start
arrow(16, 24, 13, 39.6, c=H_C, ls=(0, (3, 3)), rad=-0.1)
label(6.5, 32.0, "(a..h)=H\nat start", c=H_C, fs=7.2, ha="center")

# =====================  CONTROL FSM  ========================================
box(88, 30, 40, 40,
    "CONTROL FSM\n\n"
    "S_IDLE\n  start_i -> load block + (a..h)\n"
    "S_RUN  (round t = 0..63)\n  one compression round / clock\n  shift schedule window\n"
    "S_FINAL\n  H += (a..h); done_o pulse\n\n"
    "round counter selects K[t];\nbusy/done/valid;\n"
    "fixed 66-clock latency\n(outcome-independent)",
    K_C, fc="#fdf4ff", fs=8.4)

# ---- footer -----------------------------------------------------------------
ax.text(66, 4.0,
        "Ch/Maj/Sigma are pure combinational mod-2^32 logic; the message schedule costs 16 registers + one small adder cone instead of a 2 Kbit W-RAM.\n"
        "Iterative reuse of one round datapath -> small area; fixed 66-clock latency independent of message content -> no data-dependent timing side channel.",
        ha="center", va="center", fontsize=8.4, color="#374151", fontstyle="italic",
        linespacing=1.5)

fig.tight_layout()
fig.savefig("docs/sha256_core_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/sha256_core_block.png")
