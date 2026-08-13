#!/usr/bin/env python3
"""Render the aes128_enc circuit / block diagram to docs/aes128_enc_block.png.

Hand-drawn schematic of the *built* circuit (matplotlib, not a simulator
capture): the iterative round datapath (a 128-bit state register looped through
SubBytes -> ShiftRows -> MixColumns -> AddRoundKey), the on-the-fly key-expansion
datapath (RotWord/SubWord/Rcon feeding a chain of word XORs) that produces one
round key per clock without storing the whole schedule, the initial AddRoundKey
load mux, the last-round MixColumns bypass, and the round-counter control FSM.
"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Circle

STA_C = "#0f766e"   # cipher-state datapath
SUB_C = "#b45309"   # SubBytes / S-box
KEY_C = "#7c3aed"   # key expansion
MUX_C = "#2563eb"   # muxes / load path
CTL_C = "#c026d3"   # control FSM
INK   = "#1f2937"

fig, ax = plt.subplots(figsize=(16.0, 9.8))
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


def xor(x, y, r=1.6, c=STA_C):
    ax.add_patch(Circle((x, y), r, edgecolor=c, facecolor="white",
                 lw=1.7, zorder=4))
    ax.text(x, y, "+", ha="center", va="center", fontsize=12, color=c, zorder=5)


# ---- title ------------------------------------------------------------------
ax.text(66, 97, "aes128_enc — AES-128 Iterative Encryption Core (FIPS-197)",
        ha="center", va="center", fontsize=14.5, color=INK, weight="bold")
ax.text(66, 92.6,
        "one 128-bit block enciphered in a fixed 11 clocks (load + 10 rounds); round keys generated ON THE FLY — only one 128-bit key register, not the full schedule",
        ha="center", va="center", fontsize=9.0, color="#6b7280", fontstyle="italic")

# =====================  CIPHER-STATE DATAPATH (top)  =========================
# input load mux
box(3, 66, 15, 11, "load mux\npt XOR key\n(round 0)", MUX_C, fc="#eff6ff", fs=8.4)
label(10.5, 63.4, "start", c=MUX_C, fs=7.6)

# state register
box(23, 66, 13, 11, "STATE\nregister\n(128 b)", STA_C, fc="#ecfdf5", fs=9.0)
arrow(18, 71.5, 22.9, 71.5, c=MUX_C)

# SubBytes
box(41, 66, 15, 11, "SubBytes\n16× S-box\n(GF(2^8) inv\n+ affine)", SUB_C, fc="#fffbeb", fs=8.2)
arrow(36, 71.5, 40.9, 71.5, c=STA_C)

# ShiftRows
box(60, 66, 14, 11, "ShiftRows\nrow r <<< r\n(byte perm)", STA_C, fc="#ecfdf5", fs=8.4)
arrow(56, 71.5, 59.9, 71.5, c=STA_C)

# MixColumns + last-round bypass mux
box(78, 66, 15, 11, "MixColumns\ncol × fixed\nGF matrix", STA_C, fc="#ecfdf5", fs=8.4)
arrow(74, 71.5, 77.9, 71.5, c=STA_C)
box(97, 66, 11, 11, "bypass\nmux\n(rnd 10)", MUX_C, fc="#eff6ff", fs=8.0)
arrow(93, 71.5, 96.9, 71.5, c=STA_C)                       # mixcol -> mux
# shiftrows straight to bypass mux (skip MixColumns on last round)
ax.add_patch(FancyArrowPatch((67, 66), (100, 64.4),
             arrowstyle="-|>", mutation_scale=12, linewidth=1.5,
             color=MUX_C, linestyle=(0, (4, 3)), zorder=1,
             connectionstyle="arc3,rad=-0.28"))
label(84, 60.0, "last round skips MixColumns", c=MUX_C, fs=7.4)

# AddRoundKey
xor(115, 71.5, r=2.2, c=STA_C)
arrow(108, 71.5, 112.6, 71.5, c=STA_C)
label(115, 66.6, "AddRoundKey", c=STA_C, fs=7.8)

# ciphertext egress
box(122, 66, 9, 11, "ct_o\nvalid\ndone", MUX_C, fc="#eff6ff", fs=8.0)
arrow(117.4, 71.5, 121.9, 71.5, c=STA_C)

# feedback: AddRoundKey output back into the state register (next round)
ax.add_patch(FancyArrowPatch((115, 73.9), (29.5, 77.4),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.7,
             color=STA_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=0.32"))
label(66, 86.0, "round feedback — state register reloaded every clock for 10 rounds",
      c=STA_C, fs=8.4)

# =====================  KEY-EXPANSION DATAPATH (bottom)  =====================
box(3, 30, 15, 11, "KEY\nregister\n(128 b)\nw0 w1 w2 w3", KEY_C, fc="#f5f3ff", fs=8.0)
label(10.5, 27.2, "load key on start", c=KEY_C, fs=7.4)

# RotWord
box(25, 34, 12, 8, "RotWord\nw3<<<8", KEY_C, fc="#f5f3ff", fs=8.0)
arrow(18, 35.5, 24.9, 35.5, c=KEY_C)
label(21, 38.0, "w3", c=KEY_C, fs=7.2)
# SubWord
box(41, 34, 12, 8, "SubWord\n4× S-box", SUB_C, fc="#fffbeb", fs=8.0)
arrow(37, 38, 40.9, 38, c=KEY_C)
# Rcon xor
xor(61, 38, r=2.0, c=KEY_C)
arrow(53, 38, 58.6, 38, c=KEY_C)
box(56, 26, 10, 6, "Rcon[r]", KEY_C, fc="#f5f3ff", fs=7.8)
arrow(61, 32.1, 61, 35.6, c=KEY_C)

# word-chain XORs  n0=w0^t, n1=w1^n0, n2=w2^n1, n3=w3^n2
xs = [74, 87, 100, 113]
prev = None
wlbl = ["w0", "w1", "w2", "w3"]
for i, xc in enumerate(xs):
    xor(xc, 38, r=2.0, c=KEY_C)
    label(xc, 43.0, f"n{i}=", c=KEY_C, fs=7.2)
    # word input from the key register (schematic)
    arrow(xc, 31.5, xc, 35.7, c=KEY_C)
    label(xc, 29.8, wlbl[i], c=KEY_C, fs=7.0)
    if prev is None:
        arrow(63.2, 38, xc - 2.1, 38, c=KEY_C)             # t -> n0
    else:
        arrow(prev + 2.1, 38, xc - 2.1, 38, c=KEY_C)       # n(i-1) -> n(i)
    prev = xc
label(93, 47.5, "next round key  {n0,n1,n2,n3}  — one per clock, no schedule RAM",
      c=KEY_C, fs=8.2)

# next key feeds back into the key register AND into AddRoundKey
ax.add_patch(FancyArrowPatch((113, 40.1), (10.5, 41.2),
             arrowstyle="-|>", mutation_scale=13, linewidth=1.6,
             color=KEY_C, linestyle=(0, (5, 3)), zorder=1,
             connectionstyle="arc3,rad=-0.34"))
arrow(113, 40.1, 115, 69.3, c=KEY_C, ls=(0, (4, 3)), rad=-0.10)
label(120, 55.0, "round key\n→ AddRoundKey", c=KEY_C, fs=7.6)

# =====================  CONTROL FSM  ========================================
box(40, 8, 46, 11,
    "CONTROL FSM   IDLE → (round = 1..10) → IDLE\n"
    "round counter selects Rcon[r] & the last-round MixColumns bypass; busy/done/valid",
    CTL_C, fc="#fdf4ff", fs=8.4)
arrow(63, 19, 63, 25.4, c=CTL_C)
arrow(93, 19, 102, 65.6, c=CTL_C, ls=(0, (3, 3)), rad=-0.12)
label(70, 22.0, "round index", c=CTL_C, fs=7.4, ha="left")

# ---- footer -----------------------------------------------------------------
ax.text(66, 3.4,
        "SubBytes/ShiftRows/MixColumns/AddRoundKey are pure combinational GF(2^8) logic (reduction poly 0x11B); the same S-box feeds SubBytes and the key-expansion\n"
        "SubWord. Iterative reuse of one round datapath → small area; fixed 11-clock latency independent of key/data → constant-time (side-channel-friendly) throughput.",
        ha="center", va="center", fontsize=8.4, color="#374151", fontstyle="italic",
        linespacing=1.5)

fig.tight_layout()
fig.savefig("docs/aes128_enc_block.png", dpi=140, bbox_inches="tight")
print("wrote docs/aes128_enc_block.png")
