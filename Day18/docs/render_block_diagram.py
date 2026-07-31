#!/usr/bin/env python3
"""
render_block_diagram.py -- draw the simt_stack datapath/circuit diagram to
docs/simt_stack_diagram.png.  This is a hand-drawn schematic of the RTL in
simt_stack.sv (not a simulator screenshot): the command decode, the LIFO of
{pc, rpc, mask} entries with its stack pointer, the top-of-stack view consumed
by fetch, the divergence-split combinational logic, the reconvergence
comparator, and the fetch/execute feedback loop that advances and pops groups.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

C_BOX   = '#eef2ff'; C_EDGE  = '#4338ca'
C_MEM   = '#ecfeff'; C_MEMED = '#0e7490'
C_CTRL  = '#fef3c7'; C_CTRLE = '#b45309'
C_SEL   = '#dcfce7'; C_SELED = '#15803d'
C_DIV   = '#fce7f3'; C_DIVED = '#be185d'
C_TXT   = '#111827'; C_ARROW = '#374151'

fig, ax = plt.subplots(figsize=(14.0, 9.0))
ax.set_xlim(0, 100); ax.set_ylim(0, 100); ax.axis('off')

def box(x, y, w, h, label, fc=C_BOX, ec=C_EDGE, fs=10, weight='normal'):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle="round,pad=0.4,rounding_size=1.6", fc=fc, ec=ec, lw=1.8))
    ax.text(x + w/2, y + h/2, label, ha='center', va='center',
            fontsize=fs, color=C_TXT, weight=weight, family='monospace')

def arrow(x1, y1, x2, y2, style='-|>', color=C_ARROW, lw=1.6, ls='-'):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 mutation_scale=13, color=color, lw=lw, linestyle=ls,
                 shrinkA=2, shrinkB=2))

def label(x, y, t, fs=8.5, color=C_ARROW, style='italic'):
    ax.text(x, y, t, ha='center', va='center', fontsize=fs,
            color=color, style=style, family='monospace')

ax.text(50, 96.5, 'simt_stack — SIMT branch-divergence reconvergence (IPDOM) stack',
        ha='center', fontsize=13.5, weight='bold', color=C_TXT)
ax.text(50, 92.6, 'one shared PC per warp; hardware serializes divergent paths and '
        'reconverges at the immediate post-dominator', ha='center', fontsize=9.5,
        color=C_ARROW, style='italic')

# ---- command decode --------------------------------------------------------
box(2, 74, 20, 12,
    'command decode\ncmd_valid / cmd\nNOP DIVERGE\nSETPC POP', fc=C_CTRL, ec=C_CTRLE, fs=9)

# ---- divergence split logic ------------------------------------------------
box(27, 72, 25, 16,
    'divergence split (comb.)\n'
    't = taken_mask & TOS.mask\n'
    'n = ~taken_mask & TOS.mask\n'
    'uniform  -> just retarget PC\n'
    'diverge  -> push {n} then {t}\n'
    '(t | n == TOS.mask, t & n = 0)',
    fc=C_DIV, ec=C_DIVED, fs=8)
arrow(22, 80, 27, 80)
label(24.5, 83, 'DIVERGE', fs=7.5, color=C_DIVED)

# ---- the stack (LIFO of entries) -------------------------------------------
sx, sw = 58, 30
box(sx, 40, sw, 46, '', fc='#ffffff', ec=C_MEMED, fs=8)
ax.text(sx + sw/2, 83.5, 'IPDOM reconvergence stack   (LIFO, DEPTH entries)',
        ha='center', fontsize=9.5, weight='bold', color=C_MEMED, family='monospace')
# entry rows (top = TOS)
entries = [
    ('TOS  -> { pc_taken , rpc , t   }', '#dcfce7', True),
    ('        { pc_ntkn  , rpc , n   }', '#eef2ff', False),
    ('        { rpc(reconv), TOP, mask}', '#fef3c7', False),
    ('        .  .  .  (older groups)', '#f3f4f6', False),
]
ey = 76
for i, (txt, fc, tos) in enumerate(entries):
    ax.add_patch(Rectangle((sx + 2, ey - 6.0), sw - 4, 5.4, fc=fc,
                 ec=C_MEMED, lw=1.3))
    ax.text(sx + 4, ey - 3.3, txt, ha='left', va='center', fontsize=7.8,
            family='monospace', color=C_TXT)
    ey -= 6.6
box(sx + 2, 42, sw - 4, 5.0, 'stack pointer  sp   (+ ovf / unf guards)',
    fc=C_MEM, ec=C_MEMED, fs=8)

arrow(52, 78, 58, 78, color=C_DIVED)                 # split -> push onto stack
label(55, 81, 'push x2', fs=7.5, color=C_DIVED)
arrow(12, 74, 12, 55, color=C_CTRLE)                 # SETPC/POP -> stack ctrl
arrow(12, 55, 58, 55, color=C_CTRLE)
label(32, 57.5, 'SETPC retarget TOS.pc  /  POP retire TOS (sp--)', fs=8, color=C_CTRLE)

# ---- init ------------------------------------------------------------------
box(2, 60, 20, 9, 'init_valid\npush base entry\n{init_pc,TOP,init_mask}',
    fc=C_BOX, ec=C_EDGE, fs=8)
arrow(22, 64.5, 58, 62, color=C_EDGE, ls='--')
label(40, 65, 'whole-warp base', fs=7.5, color=C_EDGE)

# ---- top-of-stack view -----------------------------------------------------
box(58, 20, 30, 14,
    'TOP-OF-STACK VIEW  (comb.)\n'
    'tos_pc  tos_rpc  tos_mask\n'
    'active_lanes = popcount(mask)\n'
    'tos_valid = (sp != 0)',
    fc=C_SEL, ec=C_SELED, fs=8.5, weight='normal')
arrow(sx + sw/2, 40, sx + sw/2, 34, color=C_SELED)   # TOS -> view
label(sx + sw/2 + 9, 37, 'read TOS entry', fs=7.5, color=C_SELED)

# ---- reconverge comparator -------------------------------------------------
box(30, 20, 22, 14,
    'reconverge\n= (tos_pc == tos_rpc)\n'
    'fetch issues POP\nwhen asserted',
    fc=C_DIV, ec=C_DIVED, fs=8.5)
arrow(58, 27, 52, 27, color=C_DIVED)
label(55, 30, 'pc,rpc', fs=7.5, color=C_DIVED)

# ---- fetch / execute -------------------------------------------------------
box(30, 2, 58, 10,
    'warp fetch / execute datapath   (external)\n'
    'fetch tos_pc under tos_mask  ->  execute active lanes  ->  next PC\n'
    'branch? -> DIVERGE     reached rpc? -> POP     else -> SETPC',
    fc=C_CTRL, ec=C_CTRLE, fs=8.5)
arrow(73, 20, 73, 12, color=C_SELED)                 # view -> fetch
label(79.5, 16, 'pc + active mask', fs=7.5, color=C_SELED)
arrow(41, 12, 41, 20, color=C_DIVED)                 # reconverge -> fetch
arrow(30, 7, 12, 7, color=C_CTRLE)                   # fetch feedback -> commands
arrow(12, 7, 12, 74, color=C_CTRLE, ls='--')
label(8, 40, 'next command\n(DIVERGE/SETPC/POP)', fs=7.5, color=C_CTRLE)

ax.text(50, -1.5,
        'A divergent branch reuses TOS as the reconvergence entry (keeping the full '
        'parent mask) and pushes the not-taken then taken sub-groups; the taken group '
        'runs first.\nWhen a group’s PC reaches its reconvergence PC it pops, and the '
        'final pop restores the original whole-warp mask — SIMT width is regained.',
        ha='center', fontsize=8.3, color=C_ARROW, style='italic')

plt.tight_layout()
plt.savefig('simt_stack_diagram.png', dpi=130, bbox_inches='tight')
print('wrote simt_stack_diagram.png')
