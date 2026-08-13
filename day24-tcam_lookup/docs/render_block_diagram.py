#!/usr/bin/env python3
"""
render_block_diagram.py -- schematic of the tcam datapath.

Hand-drawn structural block diagram of the built RTL (matplotlib). Shows the
TCAM lookup datapath:
  (1) the DEPTH-entry ternary array, each row = {value key, care mask, valid};
  (2) the parallel ternary compare cone -- one match cell per entry computes
      match[i] = valid[i] & ( ((skey ^ key[i]) & mask[i]) == 0 );
  (3) a priority encoder that reduces the DEPTH match lines to the lowest
      winning index;
  (4) the winner read-out mux (stored key of the winner) and the output
      register that presents {match_valid, match, index, key, hit_map} one
      cycle after the search.
This is a schematic of the circuit, not a simulator capture.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

def main():
    fig, ax = plt.subplots(figsize=(13.8, 8.8))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 66)
    ax.axis('off')

    C_IN   = '#0e7490'
    C_WR   = '#be123c'
    C_ARR  = '#0f766e'
    C_CMP  = '#2563eb'
    C_ENC  = '#b45309'
    C_MUX  = '#7c3aed'
    C_OUT  = '#1f2a44'
    C_LINE = '#475569'

    def box(x, y, w, h, color, label, sub='', fc='#ffffff', fs=10):
        ax.add_patch(FancyBboxPatch((x, y), w, h,
                     boxstyle='round,pad=0.25,rounding_size=1.2',
                     linewidth=1.8, edgecolor=color, facecolor=fc, zorder=3))
        ax.text(x+w/2, y+h/2 + (1.1 if sub else 0), label, ha='center', va='center',
                color=color, fontsize=fs, fontweight='bold', zorder=4)
        if sub:
            ax.text(x+w/2, y+h/2 - 1.7, sub, ha='center', va='center',
                    color='#64748b', fontsize=7.6, zorder=4)

    def arrow(x1, y1, x2, y2, color=C_LINE, lw=1.6, style='-|>'):
        ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                     arrowstyle=style, mutation_scale=12,
                     linewidth=lw, color=color, zorder=2))

    ax.text(50, 63.5, 'tcam — Pipelined Ternary Content-Addressable Memory (TCAM) lookup engine',
            ha='center', va='center', fontsize=13.5, fontweight='bold', color=C_OUT)
    ax.text(50, 60.6, 'DEPTH ternary entries · parallel ternary compare · priority-encoded '
            'lowest-index match · deterministic 1-cycle search latency',
            ha='center', va='center', fontsize=9.5, color='#64748b')

    # ---- write / configure port ------------------------------------------
    box(2, 51, 20, 7.5, C_WR, 'configure port',
        'we · waddr\nwkey · wmask · wvalid', fc='#fff1f2')
    # ---- search port ------------------------------------------------------
    box(2, 41.5, 20, 6.5, C_IN, 'search port', 'search · skey[KEY_WIDTH]', fc='#ecfeff')
    # ---- control ----------------------------------------------------------
    box(2, 33.5, 20, 5.0, C_LINE, 'control', 'clk · rst (sync)', fc='#f1f5f9')

    # ---- ternary entry array (draw a few rows + ellipsis) ----------------
    ax.text(38.5, 57.6, 'ternary entry array (DEPTH)', ha='center',
            color=C_ARR, fontsize=10, fontweight='bold')
    rows = [('entry 0',   '#ccfbf1'),
            ('entry 1',   '#ffffff'),
            ('entry 2',   '#ffffff'),
            ('  ⋮  ',      '#ffffff'),
            ('entry N-1', '#ffffff')]
    ry = 52.0
    row_y = []
    for (lbl, fc) in rows:
        box(28, ry, 21, 4.2, C_ARR, lbl, 'key | mask | valid', fc=fc, fs=8.5)
        row_y.append(ry + 2.1)
        ry -= 5.0

    # write port fans into the array
    arrow(22, 54.7, 28, 54.1, C_WR, 1.6)
    ax.text(24.4, 55.6, 'waddr→row', color=C_WR, fontsize=7)

    # ---- parallel ternary compare cells ----------------------------------
    ax.text(62, 57.6, 'parallel ternary compare', ha='center',
            color=C_CMP, fontsize=10, fontweight='bold')
    cell_x = 55
    for i, yy in enumerate(row_y):
        lbl = 'match[i]' if i == 0 else ''
        sub = '(skey⊕key)&mask==0\n& valid' if i == 0 else ''
        fc = '#eff6ff'
        box(cell_x, yy-2.1, 15, 4.2, C_CMP,
            'cmp' if i != 3 else '⋮', '' , fc=fc, fs=8.5)
        # array row -> compare cell
        arrow(49, yy, cell_x, yy, C_ARR, 1.2)
        # match line out to encoder
        arrow(cell_x+15, yy, 78, yy, C_CMP, 1.2)

    # skey broadcast bus into every compare cell
    ax.plot([24, 53], [44.7, 44.7], color=C_IN, lw=1.6)
    ax.plot([53, 53], [44.7, 55.0], color=C_IN, lw=1.6)
    for yy in row_y:
        ax.plot([53, cell_x], [yy-1.0, yy-1.0], color=C_IN, lw=0.9, ls=(0,(3,2)))
    ax.text(40, 45.5, 'skey broadcast to all cells', color=C_IN, fontsize=7.5)

    # ---- priority encoder -------------------------------------------------
    box(78, 40.5, 15, 16.5, C_ENC, 'priority\nencoder',
        'lowest set\nmatch line →\nwin index\n(any_match)', fc='#fffbeb', fs=10)
    ax.text(85.5, 58.0, 'match lines[DEPTH]', ha='center', color=C_CMP, fontsize=7.5)

    # ---- winner key read-out mux -----------------------------------------
    box(55, 22, 20, 7.0, C_MUX, 'winner key mux',
        'key[win_index] → match_key', fc='#f5f3ff')
    arrow(85.5, 40.5, 85.5, 29.5, C_ENC, 1.8)          # index down
    ax.text(86.2, 34, 'win_index', color=C_ENC, fontsize=7.5, rotation=90, va='bottom')
    arrow(85.5, 29.5, 75, 25.5, C_ENC, 1.4)            # index -> key mux select
    # array keys feed the mux
    ax.plot([38.5, 38.5], [51.9, 25.5], color=C_ARR, lw=1.4, zorder=1)
    arrow(38.5, 25.5, 55, 25.5, C_ARR, 1.4)
    ax.text(40, 26.4, 'entry keys', color=C_ARR, fontsize=7.5)

    # ---- output register --------------------------------------------------
    box(30, 9, 44, 8.0, C_OUT, 'output register  (1-cycle latency)',
        'match_valid · match · match_index · match_key · hit_map[DEPTH]',
        fc='#f8fafc', fs=10)
    arrow(85.5, 40.5, 85.5, 13.0, C_ENC, 0.1, style='-')
    ax.plot([85.5, 85.5], [13.0, 40.5], color=C_ENC, lw=1.4, zorder=1)
    arrow(85.5, 13.0, 74, 13.0, C_ENC, 1.6)            # match/index -> reg
    arrow(65, 22, 60, 17.0, C_MUX, 1.6)                # match_key -> reg
    # hit_map (all match lines) into reg
    ax.plot([78, 27], [56.9, 56.9], color=C_CMP, lw=0.1)
    arrow(30, 13.0, 22, 13.0, C_OUT, 1.6, style='<|-')
    ax.text(6, 12.2, 'registered\nresults out', color=C_OUT, fontsize=8.5, ha='center')

    # stage badges
    for (bx, by, txt) in [(28,56.2,'1'),(55,56.2,'2'),(78,57.0,'3'),(55,29.0,'4')]:
        ax.add_patch(plt.Circle((bx+0.6, by-0.4), 1.0, color='#111827', zorder=6))
        ax.text(bx+0.6, by-0.4, txt, ha='center', va='center',
                color='white', fontsize=8.5, fontweight='bold', zorder=7)

    plt.tight_layout()
    plt.savefig('tcam_circuit.png', dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote tcam_circuit.png')

if __name__ == '__main__':
    main()
