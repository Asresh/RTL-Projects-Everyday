#!/usr/bin/env python3
"""
render_block_diagram.py  --  draw the Kogge-Stone segmented-scan datapath for
N=8 as a schematic PNG (prefix_scan_diagram.png).

This is a hand-drawn schematic of the actual generated hardware: 8 lanes, three
combine stages at Kogge-Stone distances 1, 2 and 4, a pipeline register bank
after every stage, and the segmented-combine operator applied at each node.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, Rectangle, Circle

N = 8
STAGES = [1, 2, 4]                 # combine distance per Kogge-Stone stage

C_WIRE = '#9ca3af'
C_NODE = '#7c3aed'
C_COMB = '#2563eb'
C_REG  = '#dbeafe'
C_REGE = '#2563eb'
C_TXT  = '#111827'

fig, ax = plt.subplots(figsize=(13, 8.5))

x = {i: 1.0 + i * 1.5 for i in range(N)}       # lane x-positions
# y levels (top -> bottom): inputs, [stage combine, reg] x3, outputs
y_in   = 9.5
y_stage = [7.8, 5.8, 3.8]
y_reg   = [7.0, 5.0, 3.0]
y_out  = 1.2

# ---- lane vertical wires ---------------------------------------------------
for i in range(N):
    ax.plot([x[i], x[i]], [y_out, y_in], color=C_WIRE, lw=1.2, zorder=1)

# ---- input labels ----------------------------------------------------------
for i in range(N):
    ax.text(x[i], y_in + 0.35, f'x{i}\nseg{i}', ha='center', va='bottom',
            fontsize=8.5, family='monospace', color=C_TXT)
    ax.add_patch(Circle((x[i], y_in), 0.06, color=C_TXT, zorder=3))

# ---- combine stages --------------------------------------------------------
for s, dist in enumerate(STAGES):
    ys = y_stage[s]
    yr = y_reg[s]
    ax.text(0.1, ys, f'stage {s+1}\ndist={dist}', ha='left', va='center',
            fontsize=9, family='monospace', color=C_COMB, fontweight='bold')
    # combine nodes: lane i (>= dist) adds partner lane i-dist.  The partner is
    # tapped from its own lane a little above the node and routed diagonally in,
    # so the Kogge-Stone fan-in (distance 1, 2, 4) is visible rather than a bar.
    y_tap = ys + 0.5
    for i in range(N):
        if i >= dist:
            ax.add_patch(Circle((x[i-dist], y_tap), 0.05, color=C_COMB, zorder=4))
            ax.plot([x[i-dist], x[i-dist], x[i]], [y_tap+0.0, y_tap, ys],
                    color=C_COMB, lw=1.5, zorder=2)
            # combine (+) node on lane i
            ax.add_patch(Circle((x[i], ys), 0.16, facecolor='white',
                                 edgecolor=C_NODE, lw=1.8, zorder=5))
            ax.text(x[i], ys, '+', ha='center', va='center', fontsize=11,
                    color=C_NODE, fontweight='bold', zorder=6)
        else:
            # pass-through (no partner within reach)
            ax.add_patch(Circle((x[i], ys), 0.05, color=C_WIRE, zorder=4))
    # pipeline register bank after this stage
    ax.add_patch(Rectangle((x[0]-0.45, yr-0.18), x[N-1]-x[0]+0.9, 0.36,
                           facecolor=C_REG, edgecolor=C_REGE, lw=1.4, zorder=3))
    ax.text(x[N-1]+0.65, yr, 'pipe reg', ha='left', va='center',
            fontsize=8.5, family='monospace', color=C_REGE)

# ---- output labels ---------------------------------------------------------
for i in range(N):
    ax.add_patch(Circle((x[i], y_out), 0.06, color=C_TXT, zorder=3))
    ax.text(x[i], y_out - 0.3, f'y{i}', ha='center', va='top',
            fontsize=9, family='monospace', color=C_TXT)

# ---- operator legend -------------------------------------------------------
ax.text(x[0]-0.5, 0.2,
        'segmented combine  (left = lane i-dist, right = lane i):\n'
        '   value = seg_right ? val_right : val_left + val_right\n'
        '   seg   = seg_left | seg_right        '
        '(head flag stops accumulation at a segment boundary)',
        ha='left', va='top', fontsize=9, family='monospace', color=C_TXT,
        bbox=dict(boxstyle='round,pad=0.5', facecolor='#f9fafb',
                  edgecolor='#d1d5db'))

ax.set_xlim(-0.3, x[N-1] + 2.2)
ax.set_ylim(-1.4, y_in + 1.3)
ax.axis('off')
ax.set_title('prefix_scan  —  pipelined Kogge-Stone segmented prefix-sum '
             'network (N=8, 3 stages)\n'
             'latency = log2(N) = 3 cycles,  throughput = 1 vector / cycle',
             fontsize=12)

plt.tight_layout()
plt.savefig('prefix_scan_diagram.png', dpi=130, bbox_inches='tight')
print('wrote prefix_scan_diagram.png')
