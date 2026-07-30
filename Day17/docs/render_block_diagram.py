#!/usr/bin/env python3
"""
render_block_diagram.py -- draw the warp_scheduler datapath/circuit diagram to
docs/warp_scheduler_diagram.png.  This is a hand-drawn schematic of the RTL in
warp_scheduler.sv (not a simulator screenshot): the per-warp instruction
buffers, the register scoreboard, the combinational readiness check, the
Greedy-Then-Oldest selector, and the writeback pipeline that clears the
scoreboard.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

C_BOX   = '#eef2ff'
C_EDGE  = '#4338ca'
C_MEM   = '#ecfeff'
C_MEMED = '#0e7490'
C_CTRL  = '#fef3c7'
C_CTRLE = '#b45309'
C_SEL   = '#dcfce7'
C_SELED = '#15803d'
C_TXT   = '#111827'
C_ARROW = '#374151'

fig, ax = plt.subplots(figsize=(13.5, 8.6))
ax.set_xlim(0, 100)
ax.set_ylim(0, 100)
ax.axis('off')

def box(x, y, w, h, label, fc=C_BOX, ec=C_EDGE, fs=10, weight='normal'):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6",
                 fc=fc, ec=ec, lw=1.8))
    ax.text(x + w/2, y + h/2, label, ha='center', va='center',
            fontsize=fs, color=C_TXT, weight=weight, family='monospace')

def arrow(x1, y1, x2, y2, style='-|>', color=C_ARROW, lw=1.6, ls='-'):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                 arrowstyle=style, mutation_scale=13,
                 color=color, lw=lw, linestyle=ls,
                 shrinkA=2, shrinkB=2))

def label(x, y, t, fs=8.5, color=C_ARROW, style='italic'):
    ax.text(x, y, t, ha='center', va='center', fontsize=fs,
            color=color, style=style, family='monospace')

ax.text(50, 96, 'warp_scheduler — GTO issue with a register scoreboard '
        '(NVIDIA-style SM front-end)',
        ha='center', fontsize=13, weight='bold', color=C_TXT)

# ---- per-warp instruction buffers -----------------------------------------
box(3, 78, 27, 13,
    'per-warp instruction\nbuffers  (head instr)\n'
    'ib_valid / wdst / use0,1\n'
    'ib_dst / src0 / src1', fs=8.5)

# ---- readiness / hazard check ---------------------------------------------
box(37, 76, 30, 16,
    'readiness check  (comb.)\n'
    'for each warp w:\n'
    'ready[w] = ib_valid[w] &\n'
    '  ~(use0 & pend[w][src0])  RAW\n'
    '  ~(use1 & pend[w][src1])  RAW\n'
    '  ~(wdst & pend[w][dst])   WAW', fs=8)
arrow(30, 84.5, 37, 84.5)
label(33.5, 87.5, 'decoded\nheads', fs=7.5)

# ---- scoreboard (memory) --------------------------------------------------
box(37, 55, 30, 13,
    'register SCOREBOARD\npending[NW][NREG]\n'
    '1 bit per (warp, reg)\n= write in flight',
    fc=C_MEM, ec=C_MEMED, fs=8.5)
arrow(52, 68, 52, 76, color=C_MEMED)                 # pending -> readiness
label(58.5, 72, 'pending\nbits', fs=7.5, color=C_MEMED)

# ---- GTO selector ---------------------------------------------------------
box(74, 74, 23, 18,
    'Greedy-Then-Oldest\nselect  (comb.)\n\n'
    'if last_warp ready:\n'
    '   pick = last_warp   (greedy)\n'
    'else:\n'
    '   pick = lowest ready (oldest)',
    fc=C_SEL, ec=C_SELED, fs=8)
arrow(67, 84, 74, 84)
label(70.5, 87, 'ready_mask', fs=7.5)

# ---- last_warp register ---------------------------------------------------
box(78, 58, 16, 9, 'last_warp / valid\n(GTO state reg)',
    fc=C_CTRL, ec=C_CTRLE, fs=8.5)
arrow(85.5, 74, 85.5, 67, color=C_CTRLE)             # pick -> last_warp
arrow(78, 63, 74, 63, color=C_CTRLE, style='-|>')    # last_warp feedback
arrow(74, 63, 74, 78, color=C_CTRLE)
label(70.5, 70, 'greedy\nfeedback', fs=7.5, color=C_CTRLE)

# ---- issue outputs --------------------------------------------------------
box(74, 40, 23, 10,
    'ISSUE\nissue_valid / issue_warp\nissue_onehot', fs=9, weight='bold')
arrow(85.5, 74, 85.5, 50)
label(91.5, 54, 'one warp\nper cycle', fs=7.5)

# ---- consume back to IBs (PC advance) -------------------------------------
arrow(74, 45, 16.5, 45, color=C_EDGE, ls='--')
arrow(16.5, 45, 16.5, 78, color=C_EDGE, ls='--')
label(40, 42.5, 'issue_onehot -> consume head / advance warp PC', fs=8,
      color=C_EDGE)

# ---- writeback pipeline ---------------------------------------------------
box(20, 20, 55, 12,
    'writeback pipeline   wb[0..WB_LATENCY-1] = {warp, dst}\n'
    'issue.dst -> stage0  ...shift...  stage(WB_LATENCY-1) retires\n'
    'on retire: pending[warp][dst] <- 0   (scoreboard clear)',
    fc=C_CTRL, ec=C_CTRLE, fs=8.5)
arrow(80, 40, 80, 26, color=C_CTRLE)                 # issue -> wb pipe (set)
arrow(80, 26, 75, 26, color=C_CTRLE)
label(84, 33, 'set\npending', fs=7.5, color=C_CTRLE)
arrow(20, 26, 12, 26, color=C_MEMED)                 # wb retire -> scoreboard clear
arrow(12, 26, 12, 61, color=C_MEMED)
arrow(12, 61, 37, 61, color=C_MEMED)
label(8.5, 44, 'clear\npending', fs=7.5, color=C_MEMED)

ax.text(50, 8,
        'One instruction issues per cycle.  RAW/WAW interlocks come purely from '
        'the scoreboard;\nthe writeback pipeline models fixed result latency and '
        'clears each pending bit WB_LATENCY cycles after issue.',
        ha='center', fontsize=8.5, color=C_ARROW, style='italic')

plt.tight_layout()
plt.savefig('warp_scheduler_diagram.png', dpi=130, bbox_inches='tight')
print('wrote warp_scheduler_diagram.png')
