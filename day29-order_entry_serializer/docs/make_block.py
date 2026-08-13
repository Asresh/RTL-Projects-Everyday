#!/usr/bin/env python3
"""Block / circuit diagram for the Day29 cut-through egress serializer."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

fig, ax = plt.subplots(figsize=(13.5, 7.2))
ax.set_xlim(0, 100); ax.set_ylim(0, 62); ax.axis("off")

BLUE="#1f6feb"; VIO="#8957e5"; INK="#24292f"; GREY="#57606a"
FILL="#eef4ff"; FILL2="#f3eefb"; GREEN="#1a7f37"; RED="#d1242f"

def box(x,y,w,h,title,sub="",fc=FILL,ec=BLUE,fs=10):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0.25,rounding_size=1.2",
                                fc=fc,ec=ec,lw=1.8))
    ax.text(x+w/2,y+h-3.0,title,ha="center",va="top",fontsize=fs,weight="bold",color=INK)
    if sub:
        ax.text(x+w/2,y+h-6.4,sub,ha="center",va="top",fontsize=8.0,color=GREY)

def arrow(x1,y1,x2,y2,c=INK,lw=2.0,style="-|>"):
    ax.add_patch(FancyArrowPatch((x1,y1),(x2,y2),arrowstyle=style,mutation_scale=15,
                                 lw=lw,color=c,shrinkA=0,shrinkB=0))

ax.text(50,60,"Day 29  -  Cut-Through Order-Entry Egress Serializer  (HFT tick-to-trade : the 'trade' hop)",
        ha="center",fontsize=13,weight="bold",color=INK)

# ---- input descriptor bus ----
ax.add_patch(FancyBboxPatch((2,29),17,22,boxstyle="round,pad=0.25,rounding_size=1.2",
                            fc="#f6f8fa",ec=GREY,lw=1.8))
ax.text(10.5,48.6,"Order descriptor",ha="center",va="top",fontsize=10,weight="bold",color=INK)
ax.text(10.5,45.8,"from risk gate (Day 26)",ha="center",va="top",fontsize=7.4,color=GREY)
for i,(lbl) in enumerate(["token[31:0]","side","price[31:0]","shares[31:0]","symbol[15:0]"]):
    ax.text(10.5,42.6-2.4*i,lbl,ha="center",va="center",fontsize=7.6,family="monospace",color=INK)
ax.text(10.5,27.0,"in_valid / in_ready",ha="center",fontsize=7.6,color=BLUE,family="monospace")

# ---- assembler (combinational, cut-through) ----
box(26,28,20,24,"Frame assembler","big-endian field pack",fc=FILL,ec=BLUE)
ax.text(36,42.5,"'O' | token | side('B'/'S')",ha="center",fontsize=7.4,family="monospace",color=INK)
ax.text(36,39.8,"| price | shares | symbol",ha="center",fontsize=7.4,family="monospace",color=INK)
ax.text(36,35.5,"XOR checksum\n(byte 16 trailer)",ha="center",fontsize=8,color=VIO,weight="bold")

# ---- latch on accept ----
box(52,30,15,20,"Frame reg","latched @ accept\n(msg_r, 17 bytes)",fc=FILL,ec=BLUE)

# ---- serializer FSM ----
box(52,4,15,20,"Serializer FSM","idx counter\n1 byte / clock\nm_last on byte16",fc=FILL,ec=BLUE)

# ---- skid buffer ----
box(73,16,22,26,"2-slot SKID buffer","registered egress\nEMPTY / BUSY / FULL\nabsorbs 1-cyc stall,\nno drop / no dup,\nfull throughput",fc=FILL2,ec=VIO)

# ---- egress stream out ----
ax.text(98.5,29,"egress\nbyte lane",ha="right",va="center",fontsize=8.5,color=VIO,weight="bold")

# arrows
arrow(19,40,26,40)                       # descriptor -> assembler
arrow(46,40,52,40)                       # assembler -> frame reg
arrow(59.5,30,59.5,24, c=BLUE)           # frame reg -> FSM (byte select)
ax.text(61.5,27,"byte[idx]",fontsize=7,family="monospace",color=BLUE)
arrow(67,14,73,20, c=VIO)                # FSM -> skid (p_data/p_valid/p_last)
ax.text(69,11.5,"p_valid\np_data\np_last",fontsize=6.6,family="monospace",color=VIO)
arrow(73,26,67,20, c=GREY, style="-|>")  # skid ready back to FSM
ax.text(70.5,25.5,"sk_in_ready",fontsize=6.6,family="monospace",color=GREY)
arrow(95,29,99.2,29, c=VIO)              # skid -> out
ax.text(90,44,"m_valid / m_ready / m_data[7:0] / m_last",ha="center",fontsize=7.4,
        family="monospace",color=VIO)

# accept handshake note
arrow(10.5,30,10.5,24, c=BLUE, style="-|>")
arrow(19,33,52,33, c="#c9d1d9", lw=1.2, style="-")

# latency callout
ax.add_patch(FancyBboxPatch((2,2),44,9,boxstyle="round,pad=0.3,rounding_size=1.0",
                            fc="#fff8e6",ec="#d4a72c",lw=1.4))
ax.text(24,8.6,"Ultra-low-latency properties",ha="center",fontsize=9.5,weight="bold",color="#7a5c00")
ax.text(24,5.0,"fixed 17-byte frame  =>  worst-case latency == typical  |  cut-through assemble\n"
        "registered skid egress => short comb path (high fmax) + stall-safe @ 1 byte/clock",
        ha="center",fontsize=7.6,color="#7a5c00")

plt.tight_layout()
plt.savefig("docs/oe_egress_serializer_block.png", dpi=140)
print("wrote docs/oe_egress_serializer_block.png")
