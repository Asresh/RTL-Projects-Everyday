#!/usr/bin/env python3
"""
render_block_diagram.py -- schematic of the topk_stream_engine datapath.

Hand-drawn structural block diagram of the built RTL (matplotlib). Shows the
broadcast of the incoming candidate to K parallel comparators, the monotone
priority encoder that computes the insertion position `pos`, and the
conditional shift/insert network feeding the K sorted register slots plus the
occupancy counter. This is a schematic of the circuit, not a simulator capture.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

def main():
    K = 6
    fig, ax = plt.subplots(figsize=(13.5, 8.2))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 62)
    ax.axis('off')

    C_IN   = '#0e7490'
    C_CMP  = '#2563eb'
    C_ENC  = '#b45309'
    C_MUX  = '#7c3aed'
    C_REG  = '#0f766e'
    C_OUT  = '#1f2a44'
    C_LINE = '#475569'
    C_CTRL = '#be123c'

    def box(x, y, w, h, color, label, sub='', fc='#ffffff', fs=10):
        ax.add_patch(FancyBboxPatch((x, y), w, h,
                     boxstyle='round,pad=0.25,rounding_size=1.2',
                     linewidth=1.8, edgecolor=color, facecolor=fc, zorder=3))
        ax.text(x+w/2, y+h/2 + (1.1 if sub else 0), label, ha='center', va='center',
                color=color, fontsize=fs, fontweight='bold', zorder=4)
        if sub:
            ax.text(x+w/2, y+h/2 - 1.6, sub, ha='center', va='center',
                    color='#64748b', fontsize=7.6, zorder=4)

    def arrow(x1, y1, x2, y2, color=C_LINE, lw=1.6, style='-|>'):
        ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                     arrowstyle=style, mutation_scale=12,
                     linewidth=lw, color=color, zorder=2))

    ax.text(50, 59.5, 'topk_stream_engine — Streaming Top-K Selection Engine (systolic sorted-insertion array)',
            ha='center', va='center', fontsize=13.5, fontweight='bold', color=C_OUT)
    ax.text(50, 56.6, 'one candidate/clock · parallel compare + monotone priority encode + single-cycle conditional shift/insert',
            ha='center', va='center', fontsize=9.5, color='#64748b')

    # ---- inputs -----------------------------------------------------------
    box(2, 44, 15, 7, C_IN, 'candidate in',
        'in_valid · in_data[DW] (signed) · in_tag[TW]', fc='#ecfeff')
    box(2, 33, 15, 5.5, C_CTRL, 'control', 'clk · rst · flush', fc='#fff1f2')

    # broadcast bus
    ax.plot([17, 24], [47.5, 47.5], color=C_IN, lw=2.0, zorder=2)
    ax.plot([24, 24], [8, 47.5], color=C_IN, lw=2.0, zorder=1)
    ax.text(24.5, 50, 'candidate broadcast', color=C_IN, fontsize=8, rotation=90, va='bottom')

    # ---- K register slots + comparators (rows) ----------------------------
    row_h = 6.6
    top   = 50
    slot_x = 70
    cmp_x  = 33
    eff_x  = 55
    for i in range(K):
        y = top - i*row_h
        # comparator
        box(cmp_x, y-2.4, 12, 5.0, C_CMP, f'cmp[{i}]', 'in_data ≥ eff', fc='#eff6ff', fs=9)
        # register slot
        box(slot_x, y-2.4, 20, 5.0, C_REG,
            f'slot {i}', 'r_data · r_tag · r_valid', fc='#f0fdfa', fs=9)
        # candidate into comparator
        arrow(24, y+0.1, cmp_x, y+0.1, color=C_IN, lw=1.3)
        # eff key feedback from slot to comparator (mux valid? -inf)
        ax.plot([slot_x, eff_x+6], [y-1.6, y-1.6], color=C_REG, lw=1.1, zorder=1)
        ax.plot([eff_x+6, eff_x+6], [y-1.6, y-3.2], color=C_REG, lw=1.1, zorder=1)
        ax.plot([eff_x+6, cmp_x+6], [y-3.2, y-3.2], color=C_REG, lw=1.1, zorder=1)
        ax.plot([cmp_x+6, cmp_x+6], [y-3.2, y-2.4], color=C_REG, lw=1.1, zorder=1)
        ax.text(eff_x-2.5, y-3.9, 'eff = valid ? r_data : −∞',
                color='#0f766e', fontsize=6.6, ha='left')
        # ge[i] to encoder
        arrow(cmp_x+12, y+0.1, 47.5, y+0.1, color=C_CMP, lw=1.2)

    # ---- priority encoder (monotone ge -> pos) ----------------------------
    enc_y0 = top - (K-1)*row_h - 2.4
    enc_y1 = top + 2.6
    box(47.6, enc_y0, 5.6, enc_y1-enc_y0, C_ENC, '', fc='#fffbeb')
    ax.text(50.4, (enc_y0+enc_y1)/2, 'priority\nencoder\nge→pos', ha='center', va='center',
            color=C_ENC, fontsize=8.4, fontweight='bold', rotation=0)

    # pos bus down to shift/insert control
    ax.plot([53.2, 63], [(enc_y0+enc_y1)/2, (enc_y0+enc_y1)/2], color=C_ENC, lw=1.8)
    ax.plot([63, 63], [8, (enc_y0+enc_y1)/2], color=C_ENC, lw=1.8)
    ax.text(63.6, 10, 'pos  (insertion index, K = drop)', color=C_ENC, fontsize=8, rotation=90, va='bottom')

    # shift/insert control feeding each slot's mux
    for i in range(K):
        y = top - i*row_h
        arrow(63, y-0.1, slot_x, y-0.1, color=C_MUX, lw=1.1)
    ax.text(64.5, top+3.4, 'per-slot next-state mux:', color=C_MUX, fontsize=8.2, fontweight='bold')
    ax.text(64.5, top+1.4, 'i<pos: hold · i==pos: insert candidate · i>pos: shift slot i−1',
            color=C_MUX, fontsize=7.4)

    # ---- outputs ----------------------------------------------------------
    for i in range(K):
        y = top - i*row_h
        arrow(slot_x+20, y+0.1, 94, y+0.1, color=C_OUT, lw=1.1)
    box(94.2, top-(K-1)*row_h-2.4, 5.2, (K-1)*row_h+5.0, C_OUT, '', fc='#f8fafc')
    ax.text(96.8, top-(K-1)*row_h/2, 'sorted view\nvalid_o\ndata_o\ntag_o',
            ha='center', va='center', color=C_OUT, fontsize=8, fontweight='bold')

    # occupancy counter
    box(70, 6.5, 20, 4.6, C_REG, 'occupancy counter',
        'count_o (0..K) · full_o', fc='#f0fdfa', fs=9)
    arrow(63, 8.8, 70, 8.8, color=C_ENC, lw=1.1)
    arrow(80, 6.5, 80, 4.0, color=C_OUT, lw=1.1)
    ax.text(80, 3.2, 'count_o · full_o', ha='center', color=C_OUT, fontsize=7.8)

    # control fan to slots/counter
    ax.plot([9.5, 9.5], [8, 33], color=C_CTRL, lw=1.4, zorder=1)
    ax.plot([9.5, 70], [8, 8], color=C_CTRL, lw=1.4, zorder=1)
    ax.text(30, 8.6, 'clk / rst / flush', color=C_CTRL, fontsize=7.6)

    plt.tight_layout()
    plt.savefig('topk_stream_engine_circuit.png', dpi=140,
                bbox_inches='tight', facecolor='white')
    print('wrote topk_stream_engine_circuit.png')

if __name__ == '__main__':
    main()
