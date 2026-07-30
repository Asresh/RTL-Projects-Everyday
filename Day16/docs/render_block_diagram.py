#!/usr/bin/env python3
"""
render_block_diagram.py -- draw the smem_xbar datapath/circuit diagram to
docs/smem_xbar_diagram.png.  This is a hand-drawn schematic of the RTL in
smem_xbar.sv (not a simulator screenshot): the warp request path, the per-bank
conflict scheduler, the banked scratchpad, and the broadcast result crossbar.
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
C_TXT   = '#111827'
C_ARROW = '#374151'

fig, ax = plt.subplots(figsize=(13.5, 8.4))
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

ax.text(50, 96, 'smem_xbar — SIMT shared-memory bank-conflict crossbar (read gather)',
        ha='center', fontsize=13, weight='bold', color=C_TXT)

# ---- request inputs -------------------------------------------------------
box(3, 82, 26, 9, 'warp request\nreq_mask[L]  req_addr[L]', fs=9)
# ---- address decode -------------------------------------------------------
box(36, 82, 28, 9, 'address decode\nbank = addr[BSEL-1:0]\nrow  = addr[MSB:BSEL]', fs=8.5)
arrow(29, 86.5, 36, 86.5)

# ---- request latch / pending ---------------------------------------------
box(70, 82, 27, 9, 'request latch\naddr_q[L], mask_q\npending[L]', fs=8.5)
arrow(64, 86.5, 70, 86.5)

# ---- conflict scheduler (combinational) -----------------------------------
box(30, 58, 40, 14,
    'per-bank conflict scheduler  (comb.)\n'
    'leader[b] = lowest pending lane -> bank b\n'
    'serve[i]  = pending[i] & addr==leader_addr[b]\n'
    '(same-address lanes broadcast together)',
    fc=C_CTRL, ec=C_CTRLE, fs=8.5)
arrow(83.5, 82, 83.5, 72, ); arrow(83.5, 72, 70, 65)     # pending -> scheduler
label(88, 76, 'pending[L]')

# ---- FSM control ----------------------------------------------------------
box(74, 58, 23, 14,
    'control FSM\nIDLE -> SERVE* -> DONE\nphase_cnt++\npending &= ~serve',
    fc=C_CTRL, ec=C_CTRLE, fs=8.5)
arrow(70, 65, 74, 65, style='<|-|>')

# ---- banked scratchpad ----------------------------------------------------
by = 34
for b in range(8):
    bx = 6 + b * 11.3
    box(bx, by, 9.4, 12, f'bank\n{b}', fc=C_MEM, ec=C_MEMED, fs=8.5, weight='bold')
ax.text(50, by + 15.5, 'banked scratchpad  —  BANKS x BANK_DEPTH words (async read, sync write)',
        ha='center', fontsize=9, color=C_MEMED, weight='bold')
# scheduler drives one row-address per bank per phase
arrow(40, 58, 30, 46.5)
label(28, 52, 'leader row / bank', fs=8)
arrow(50, 58, 50, 46.5)

# ---- broadcast result crossbar -------------------------------------------
box(24, 15, 52, 9,
    'broadcast result crossbar\nroute served banks -> data_acc[i] for every served lane',
    fc=C_BOX, ec=C_EDGE, fs=9)
for b in range(8):
    bx = 6 + b * 11.3 + 4.7
    arrow(bx, 34, min(max(bx, 26), 74), 24, lw=1.1)
label(50, 29.5, 'bank read data', fs=8)

# ---- outputs --------------------------------------------------------------
box(24, 3, 52, 8,
    'resp_valid   resp_data[L]   resp_mask   resp_phases (= conflict degree)',
    fc='#dcfce7', ec='#15803d', fs=9)
arrow(50, 15, 50, 11)

# serve mask feedback from scheduler to crossbar
arrow(30, 62, 20, 62, ls='--', lw=1.2)
arrow(20, 62, 20, 19.5, ls='--', lw=1.2)
arrow(20, 19.5, 24, 19.5, ls='--', lw=1.2)
label(15.5, 40, 'serve[L]', fs=8)

plt.tight_layout()
plt.savefig('smem_xbar_diagram.png', dpi=130, bbox_inches='tight')
print('wrote smem_xbar_diagram.png')
