#!/usr/bin/env python3
"""
render_block_diagram.py -- draw the datapath / circuit diagram of the
GPU global-memory coalescing unit (gpu_coalescer.sv) and save it to
gpu_coalescer_circuit.png.

This is a schematic of the built RTL (hand-drawn with matplotlib), NOT a
simulator screenshot -- it shows the pipeline: warp lane addresses ->
segment extract -> parallel leader detection -> pending-leader register ->
priority select -> group gather -> coalesced transaction stream.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle

C_BG    = '#ffffff'
C_BOX   = '#1e3a8a'
C_BOX2  = '#0e7490'
C_BOX3  = '#7c3aed'
C_FILL  = '#eff6ff'
C_FILL2 = '#ecfeff'
C_FILL3 = '#f5f3ff'
C_REG   = '#b45309'
C_REGF  = '#fffbeb'
C_TXT   = '#0f172a'
C_ARR   = '#334155'
C_MUT   = '#64748b'

fig, ax = plt.subplots(figsize=(15, 9.2))
ax.set_xlim(0, 15); ax.set_ylim(0, 9.2); ax.axis('off')
fig.patch.set_facecolor(C_BG)

def box(x, y, w, h, label, ec, fc, fs=10, bold=True, tc=None):
    p = FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.03,rounding_size=0.10",
                       linewidth=1.8, edgecolor=ec, facecolor=fc, zorder=3)
    ax.add_patch(p)
    ax.text(x + w/2, y + h/2, label, ha='center', va='center',
            fontsize=fs, color=tc or C_TXT, zorder=4,
            fontweight='bold' if bold else 'normal')

def reg(x, y, w, h, label, fs=9):
    box(x, y, w, h, label, C_REG, C_REGF, fs=fs)

def arrow(x1, y1, x2, y2, color=C_ARR, lw=1.8, style='-|>', ls='-'):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 mutation_scale=15, linewidth=lw, color=color,
                 linestyle=ls, zorder=2))

def label(x, y, t, fs=8.5, color=C_MUT, ha='center', style='italic', rot=0):
    ax.text(x, y, t, ha=ha, va='center', fontsize=fs, color=color,
            style=style, zorder=5, rotation=rot)

# ---- title -----------------------------------------------------------------
ax.text(7.5, 8.85, 'gpu_coalescer  —  Warp Global-Memory Coalescing Unit (GPU LSU front-end)',
        ha='center', va='center', fontsize=14.5, fontweight='bold', color=C_BOX)
ax.text(7.5, 8.45, 'single-pass parallel leader detection  →  sequenced coalesced-transaction emit',
        ha='center', va='center', fontsize=10, color=C_MUT, style='italic')

# ---- inputs: warp of lane requests ----------------------------------------
box(0.4, 5.0, 2.5, 2.9, '', C_BOX, C_FILL)
ax.text(1.65, 7.62, 'WARP REQUEST', ha='center', fontsize=10, fontweight='bold', color=C_BOX)
ax.text(1.65, 7.30, 'in_valid / req_mask[LANES]', ha='center', fontsize=8, color=C_MUT)
for i in range(6):
    yy = 6.95 - i*0.31
    tag = f'lane{i}: addr[{i}]' if i < 5 else '…  (LANES lanes)'
    ax.text(1.65, yy, tag, ha='center', fontsize=8,
            color=C_TXT if i < 5 else C_MUT,
            family='DejaVu Sans Mono')
arrow(2.9, 6.45, 3.7, 6.45)

# ---- segment extract -------------------------------------------------------
box(3.7, 5.55, 2.3, 1.8, 'SEGMENT\nEXTRACT', C_BOX2, C_FILL2, fs=10)
ax.text(4.85, 5.9, 'seg[i]=addr[i]>>log2(SEG_BYTES)', ha='center',
        fontsize=7.2, color=C_MUT, family='DejaVu Sans Mono')
label(4.85, 7.55, 'IDLE: register mask + seg', fs=8, color=C_REG, style='italic')

arrow(6.0, 6.45, 6.85, 6.45)
reg(6.85, 5.55, 1.15, 1.8, 'seg_q[]\nreqm_q', fs=8.5)

arrow(8.0, 6.45, 8.85, 6.45)

# ---- leader detection matrix ----------------------------------------------
box(8.85, 5.3, 3.0, 2.3, '', C_BOX3, C_FILL3)
ax.text(10.35, 7.35, 'PARALLEL LEADER DETECT', ha='center', fontsize=9.5,
        fontweight='bold', color=C_BOX3)
ax.text(10.35, 7.03, 'leader[i] = active[i] &', ha='center', fontsize=7.6,
        color=C_TXT, family='DejaVu Sans Mono')
ax.text(10.35, 6.78, '¬(∨_{j<i} active[j] & seg[j]==seg[i])', ha='center',
        fontsize=7.6, color=C_TXT, family='DejaVu Sans Mono')
# little N x N compare grid
gx, gy, gs = 9.35, 5.55, 0.19
for r in range(5):
    for c in range(5):
        on = (c <= r)
        ax.add_patch(Rectangle((gx + c*gs, gy + r*gs), gs*0.82, gs*0.82,
                     facecolor=('#c4b5fd' if on else '#ede9fe'),
                     edgecolor='#8b5cf6', lw=0.5))
ax.text(10.55, 5.62, 'lower-triangle seg-compare matrix', ha='left',
        va='center', fontsize=6.6, color=C_MUT, style='italic')
ax.text(10.35, 5.18, 'num_txn = popcount(leader)', ha='center', va='center',
        fontsize=7.6, color=C_BOX2, family='DejaVu Sans Mono')

label(10.35, 7.75, 'DECODE: mark segment leaders', fs=8, color=C_REG, style='italic')

# ---- pending register ------------------------------------------------------
arrow(11.85, 6.45, 12.55, 6.45)
reg(12.55, 5.55, 1.9, 1.8, 'pending_q[]\n(leaders left)', fs=8.5)

# down to the emit engine
arrow(13.5, 5.55, 13.5, 4.55)
arrow(13.5, 4.55, 6.2, 4.55, style='-|>')
label(9.9, 4.72, 'EMIT: one transaction per cycle  (priority-select lowest pending leader)',
      fs=8.5, color=C_REG, style='italic')

# ---- emit engine -----------------------------------------------------------
box(3.5, 2.3, 3.4, 2.1, '', C_BOX, C_FILL)
ax.text(5.2, 4.15, 'EMIT ENGINE', ha='center', fontsize=10, fontweight='bold', color=C_BOX)
ax.text(5.2, 3.82, 'sel_p = lowest set bit', ha='center', fontsize=7.8,
        color=C_TXT, family='DejaVu Sans Mono')
ax.text(5.2, 3.55, 'group = {k: seg_q[k]==seg_q[sel_p]}', ha='center',
        fontsize=7.6, color=C_TXT, family='DejaVu Sans Mono')
ax.text(5.2, 3.28, 'base  = seg_q[sel_p] << log2(SEG)', ha='center',
        fontsize=7.6, color=C_TXT, family='DejaVu Sans Mono')
ax.text(5.2, 2.98, 'pending &= ~(1<<sel_p)', ha='center', fontsize=7.6,
        color=C_TXT, family='DejaVu Sans Mono')
ax.text(5.2, 2.62, 'last = (pending==0)', ha='center', fontsize=7.6,
        color=C_MUT, family='DejaVu Sans Mono')

# feedback loop pending -> emit (clears leader)
arrow(3.5, 3.35, 2.85, 3.35, color=C_BOX3)
arrow(2.85, 3.35, 2.85, 6.0, color=C_BOX3, ls=(0,(4,3)))
arrow(2.85, 6.0, 3.6, 6.0, color=C_BOX3, ls=(0,(4,3)))
label(2.55, 4.7, 'retire emitted\nleader', fs=7.5, color=C_BOX3, ha='center')

# ---- transaction output stream --------------------------------------------
arrow(6.9, 3.35, 7.8, 3.35)
box(7.8, 2.3, 3.6, 2.1, '', C_BOX2, C_FILL2)
ax.text(9.6, 4.15, 'COALESCED TXN STREAM', ha='center', fontsize=10,
        fontweight='bold', color=C_BOX2)
for i, (nm, ds) in enumerate([
        ('txn_valid', '1 = transaction valid this cycle'),
        ('txn_base',  'SEG_BYTES-aligned segment base'),
        ('txn_lane_mask', 'lanes served (partition of req_mask)'),
        ('txn_index / txn_last', '0..num_txn-1, last on final txn'),
        ('warp_done', '1-cycle pulse: warp retired')]):
    yy = 3.85 - i*0.33
    ax.text(8.0, yy, nm, ha='left', fontsize=7.8, color=C_TXT,
            family='DejaVu Sans Mono', fontweight='bold')
    ax.text(10.05, yy, ds, ha='left', fontsize=7.0, color=C_MUT)

# ---- perf counters ---------------------------------------------------------
box(12.0, 2.55, 2.7, 1.6, '', C_REG, C_REGF)
ax.text(13.35, 3.9, 'PERF COUNTERS', ha='center', fontsize=9, fontweight='bold', color=C_REG)
ax.text(13.35, 3.55, 'perf_lanes  += popcount(mask)', ha='center', fontsize=7.0,
        color=C_TXT, family='DejaVu Sans Mono')
ax.text(13.35, 3.28, 'perf_txns   += 1 / txn', ha='center', fontsize=7.0,
        color=C_TXT, family='DejaVu Sans Mono')
ax.text(13.35, 2.95, 'ratio = lanes / txns', ha='center', fontsize=7.2,
        color=C_MUT, family='DejaVu Sans Mono', style='italic')
ax.text(13.35, 2.72, '(coalescing efficiency)', ha='center', fontsize=7.0,
        color=C_MUT, style='italic')
arrow(11.4, 3.0, 12.0, 3.2, color=C_REG, lw=1.3)

# ---- FSM strip -------------------------------------------------------------
ax.text(0.5, 1.55, 'FSM:', ha='left', fontsize=9, fontweight='bold', color=C_TXT)
fx = 1.4
for st, cc in [('IDLE', C_BOX), ('DECODE', C_BOX3), ('EMIT', C_BOX2)]:
    box(fx, 1.2, 1.5, 0.7, st, cc, '#ffffff', fs=9)
    if st != 'EMIT':
        arrow(fx+1.5, 1.55, fx+1.9, 1.55)
    fx += 1.9
arrow(fx-0.4, 1.2, fx-0.4, 0.85, color=C_ARR)
arrow(fx-0.4, 0.85, 2.15, 0.85, color=C_ARR)
arrow(2.15, 0.85, 2.15, 1.2, color=C_ARR)
label((fx-0.4+2.15)/2, 0.66, 'warp_done → IDLE (accept next warp)', fs=7.5, color=C_MUT)

# ---- footnote --------------------------------------------------------------
ax.text(7.5, 0.28,
        'Parameters: LANES (warp width) · ADDRW (byte-address width) · SEG_BYTES (coalescing granularity, power of two).  '
        'Verified with Icarus Verilog against an independent golden set-partition model.',
        ha='center', fontsize=8, color=C_MUT, style='italic')

plt.tight_layout()
plt.savefig('gpu_coalescer_circuit.png', dpi=150, bbox_inches='tight', facecolor=C_BG)
print('wrote gpu_coalescer_circuit.png')
