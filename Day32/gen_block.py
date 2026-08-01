#!/usr/bin/env python3
"""Render the rs_encoder circuit / block diagram to docs/rs_encoder_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator
capture): the elaboration-time GF(2^M) generator-polynomial derivation feeding a
2T-tap Galois-field LFSR (the polynomial-division / remainder circuit), the
systematic output mux (message symbols pass straight through, then the parity
remainder is shifted out), and the control FSM that frames K message + 2T parity
symbols into one codeword.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

GEN_C = "#7c3aed"   # elaboration-time generator derivation
LF_C  = "#0f766e"   # GF LFSR datapath
MUL_C = "#b45309"   # GF multipliers
MUX_C = "#2563eb"   # output mux / systematic path
CTL_C = "#c026d3"   # control FSM
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(16.0, 9.6))
ax.set_xlim(0, 130)
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


def xor(x, y, r=1.5, c=LF_C):
    ax.add_patch(Circle((x, y), r, edgecolor=c, facecolor="white",
                 lw=1.7, zorder=4))
    ax.text(x, y, "+", ha="center", va="center", fontsize=11, color=c, zorder=5)


def mult(x, y, r=1.9, c=MUL_C):
    ax.add_patch(Circle((x, y), r, edgecolor=c, facecolor="#fffbeb",
                 lw=1.7, zorder=4))
    ax.text(x, y, "x", ha="center", va="center", fontsize=10, color=c, zorder=5)


# ---- title ------------------------------------------------------------------
ax.text(62, 97, "rs_encoder — Reed-Solomon RS(n,k) Systematic Encoder over GF(2^M)",
        ha="center", va="center", fontsize=14.5, color=INK, weight="bold")
ax.text(62, 92.6,
        "streaming polynomial-division circuit: parity = ( message(x) · x^(2T) )  mod  g(x)   →   systematic codeword, 1 symbol/clock",
        ha="center", va="center", fontsize=9.2, color="#6b7280", fontstyle="italic")

# ---- elaboration-time generator derivation ---------------------------------
box(2, 74, 30, 13,
    "ELABORATION (constant functions)\n"
    "GF(2^M) tables from PRIM · g(x)=∏(x−α^{FCR+i})\n"
    "⇒ 2T tap constants  g[0..2T−1]",
    GEN_C, fc="#f5f3ff", fs=8.4)
label(17, 71.0, "derived at compile time — no hand-coded tables", c=GEN_C, fs=7.6)

# ---- message input ----------------------------------------------------------
box(2, 40, 20, 12,
    "MESSAGE IN\nmsg_data (K syms)\nmsg_valid / start",
    MUX_C, fc="#eff6ff", fs=8.6)

# ---- feedback tap (data XOR top register) ----------------------------------
xor(30, 46, r=1.9, c=LF_C)
arrow(22, 46, 28.1, 46, c=MUX_C)          # message -> feedback xor
label(26, 48.4, "msg", c=MUX_C, fs=7.6)

# ---- the 2T-tap Galois LFSR -------------------------------------------------
# draw P register cells left->right with a multiplier + xor per tap
P = 8
x0 = 40
cellw = 8.0
gap = 1.6
ytop = 44
regh = 8
regw = 6.0
label(30, 40.2, "feedback\nfb = msg ⊕ b[2T−1]", c=LF_C, fs=7.4)

# feedback bus runs across the bottom of the LFSR
fb_y = 33
arrow(30, 44.1, 30, fb_y, c=LF_C)
arrow(30, fb_y, x0 + (P-1)*(cellw), fb_y, c=LF_C)  # feedback line to all taps
label(x0 + P*cellw*0.5, fb_y - 2.0, "feedback broadcast to every tap  (fb · g[j])",
      c=LF_C, fs=7.6)

prev_right = None
for j in range(P):
    cx = x0 + j * cellw
    # multiplier fb * g[j]
    mx, my = cx, 38
    mult(mx, my)
    arrow(mx, fb_y + 0.2, mx, my - 1.9, c=LF_C)          # fb -> mult
    label(mx, 35.6, f"g[{j}]", c=MUL_C, fs=6.6)
    # xor combining previous register with mult output
    ex, ey = cx + 2.6, ytop
    xor(ex, ey, r=1.6, c=LF_C)
    arrow(mx, my + 1.9, ex - 0.4, ey - 1.5, c=LF_C, rad=0.0)  # mult -> xor
    # register cell b[j]
    rx = cx + 4.4
    box(rx, ytop - regh/2, regw, regh, f"b[{j}]", LF_C, fc="#ecfdf5", fs=8.2)
    arrow(ex + 1.5, ey, rx - 0.1, ey, c=LF_C)            # xor -> reg
    # chain: previous reg output feeds this xor (b[j] <= b[j-1] ^ fb*g[j])
    if prev_right is not None:
        arrow(prev_right, ytop, ex - 1.5, ey, c=LF_C)
    prev_right = rx + regw
# label the register row
label(x0 + P*cellw*0.5, ytop + 6.4,
      "2T-symbol remainder registers  (Galois-field LFSR)  —  hold the parity after K message symbols",
      c=LF_C, fs=8.0)
# top register feeds the feedback xor back
ax.add_patch(FancyArrowPatch((prev_right, ytop + 1.2), (30, 47.6),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.7,
             color=LF_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=-0.30"))
label(64, 58.5, "b[2T−1] fed back into fb  (division feedback)", c=LF_C, fs=7.8)

# ---- systematic output mux --------------------------------------------------
box(110, 40, 16, 20,
    "OUTPUT MUX\n(systematic)\n\nS_MSG: pass\n msg through\nS_PAR: shift\n out b[2T−1..0]",
    MUX_C, fc="#eff6ff", fs=8.2)
# message straight-through path (systematic)
ax.add_patch(FancyArrowPatch((22, 49.5), (110, 55),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.7,
             color=MUX_C, linestyle=(0, (4, 3)), zorder=1,
             connectionstyle="arc3,rad=-0.16"))
label(70, 69.5, "message symbols bypass straight to the output (systematic)  —  cw_is_parity = 0",
      c=MUX_C, fs=7.8)
arrow(prev_right + 0.4, ytop - 2, 110, 46, c=LF_C, rad=-0.12)   # parity -> mux
label(104, 42.5, "parity", c=LF_C, fs=7.4)

# ---- codeword egress --------------------------------------------------------
arrow(126, 50, 129.5, 50, c=MUX_C)
label(112, 34.5, "CODEWORD OUT: cw_data / cw_valid / cw_is_parity / cw_last / par_flat / done",
      c=MUX_C, fs=7.6, style="normal", ha="left")

# ---- control FSM ------------------------------------------------------------
box(46, 12, 34, 12,
    "CONTROL FSM   S_IDLE → S_MSG (count K) → S_PAR (emit 2T)\n"
    "one codeword = K message + 2T parity = N symbols",
    CTL_C, fc="#fdf4ff", fs=8.4)
arrow(63, 24, 63, 30.8, c=CTL_C)
label(72, 27.5, "phase / counter ctrl", c=CTL_C, fs=7.4, ha="left")

# ---- footer -----------------------------------------------------------------
ax.text(62, 6.0,
        "GF(2^M) multiply is a combinational shift-and-reduce cone using the primitive polynomial PRIM.  The whole field, the generator, and the\n"
        "2T tap constants are derived at elaboration from {M, T, PRIM, FCR} — retarget RS(16,8) → DVB RS(255,239) by changing parameters only.",
        ha="center", va="center", fontsize=8.6, color="#374151", fontstyle="italic",
        linespacing=1.5)

fig.tight_layout()
fig.savefig("docs/rs_encoder_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/rs_encoder_block.png")
