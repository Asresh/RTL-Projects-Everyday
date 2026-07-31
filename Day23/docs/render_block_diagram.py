#!/usr/bin/env python3
"""
render_block_diagram.py -- schematic of the priority_queue datapath.

Hand-drawn structural block diagram of the built RTL (matplotlib). Shows the
per-cycle pipeline of the systolic register-array priority queue:
  (1) an optional extract-min shift-down mux forms `base[]`,
  (2) N parallel comparators compute the monotone gt[] = (base_key > enq_key),
  (3) a priority encoder turns gt[] into the insertion position `pos`,
  (4) a conditional shift/insert network writes the N sorted register slots,
plus the occupancy counter and head/status outputs.
This is a schematic of the circuit, not a simulator capture.
"""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch

def main():
    N = 8
    fig, ax = plt.subplots(figsize=(13.8, 8.6))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 64)
    ax.axis('off')

    C_IN   = '#0e7490'
    C_MUX  = '#7c3aed'
    C_CMP  = '#2563eb'
    C_ENC  = '#b45309'
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
            ax.text(x+w/2, y+h/2 - 1.7, sub, ha='center', va='center',
                    color='#64748b', fontsize=7.6, zorder=4)

    def arrow(x1, y1, x2, y2, color=C_LINE, lw=1.6, style='-|>'):
        ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2),
                     arrowstyle=style, mutation_scale=12,
                     linewidth=lw, color=color, zorder=2))

    ax.text(50, 61.5, 'priority_queue — Systolic Register-Array Hardware Priority Queue (min-queue)',
            ha='center', va='center', fontsize=13.5, fontweight='bold', color=C_OUT)
    ax.text(50, 58.6, 'one enqueue / extract-min per clock · array kept sorted ascending · slot 0 = current minimum · deterministic latency',
            ha='center', va='center', fontsize=9.5, color='#64748b')

    # ---- inputs -----------------------------------------------------------
    box(2, 47, 17, 7, C_IN, 'request in',
        'enq · deq · enq_key[KW] · enq_data[DW]', fc='#ecfeff')
    box(2, 37.5, 17, 5.5, C_CTRL, 'control', 'clk · rst · flush', fc='#fff1f2')

    # ---- (1) extract-min shift-down mux ----------------------------------
    box(24, 45, 20, 9, C_MUX, 'extract-min shift',
        'deq ? base[i]=slot[i+1] : slot[i]\n(tail slot -> empty)', fc='#f5f3ff')
    arrow(19, 50.5, 24, 50.5, C_IN, 2.0)     # request -> shift stage (deq)
    ax.text(21.3, 51.4, 'deq', color=C_CTRL, fontsize=7.5)

    # base[] bus down to comparators + insert net
    ax.plot([44, 49], [49.5, 49.5], color=C_MUX, lw=2.0)
    ax.plot([49, 49], [12, 49.5], color=C_MUX, lw=1.6, zorder=1)
    ax.text(50.1, 33, 'base[] (sorted asc.)', color=C_MUX, fontsize=7.5, rotation=90, va='center')

    # ---- (2) parallel comparators ----------------------------------------
    box(52, 46.5, 20, 8, C_CMP, 'N parallel comparators',
        'gt[i] = ( base_key[i] > enq_key )\nempty slot key = +inf', fc='#eff6ff')
    # enq_key broadcast into comparators
    ax.plot([19, 50.5], [51.8, 51.8], color=C_IN, lw=1.4, ls=(0,(4,2)))
    arrow(50.5, 51.8, 52, 50.5, C_IN, 1.4)
    ax.text(33, 52.6, 'enq_key broadcast', color=C_IN, fontsize=7.5)

    # ---- (3) priority encoder --------------------------------------------
    box(76, 46.5, 20, 8, C_ENC, 'priority encoder',
        'monotone gt[] -> pos\n(pos=N => append at tail)', fc='#fffbeb')
    arrow(72, 50.5, 76, 50.5, C_CMP, 1.8)
    ax.text(72.6, 51.6, 'gt[]', color=C_CMP, fontsize=7.5)

    # pos down to insert network
    ax.plot([86, 86], [30, 46.5], color=C_ENC, lw=1.8, zorder=1)
    arrow(86, 30, 86, 27.5, C_ENC, 1.8)
    ax.text(86.6, 40, 'pos', color=C_ENC, fontsize=8, rotation=90, va='bottom')

    # ---- (4) conditional shift/insert network ----------------------------
    box(24, 20, 62, 7.5, C_MUX, 'conditional shift / insert network',
        'i<pos: hold base[i]   ·   i==pos: {enq_key,enq_data,1}   ·   i>pos: base[i-1]',
        fc='#f5f3ff', fs=10)
    arrow(49, 20, 49, 27.5-7.5+7.5, C_MUX, 0.1, style='-')  # (invisible spacer)
    arrow(49, 27.6, 49, 27.5, C_MUX, 1.6)

    # ---- register slots ---------------------------------------------------
    sw = 7.0; gap = 0.7; x0 = 24; yreg = 9.5
    for i in range(N):
        x = x0 + i*(sw+gap)
        tag = 'min' if i == 0 else ('max' if i == N-1 else '')
        fc = '#ccfbf1' if i == 0 else '#ffffff'
        box(x, yreg, sw, 6.0, C_REG, f'slot{i}',
            (tag if tag else 'key|data|v'), fc=fc, fs=9)
        arrow(x+sw/2, 20, x+sw/2, yreg+6.0, C_MUX, 1.2)  # insert-net -> slot
        if i < N-1:
            ax.text(x+sw+gap/2, yreg+3.0, '↔', ha='center', va='center',
                    color='#94a3b8', fontsize=11)

    # ---- occupancy counter ------------------------------------------------
    box(2, 20, 17, 7.5, C_ENC, 'occupancy counter',
        'count += do_enq − do_deq\nfull / empty', fc='#fffbeb')
    arrow(19, 47, 10.5, 27.5, C_CTRL, 1.2, style='-')     # enq/deq into counter
    ax.text(11.5, 34, 'enq/deq', color=C_CTRL, fontsize=7, rotation=90)

    # ---- outputs ----------------------------------------------------------
    ax.add_patch(FancyBboxPatch((88, 9.5), 10.5, 18,
                 boxstyle='round,pad=0.25,rounding_size=1.2',
                 linewidth=1.8, edgecolor=C_OUT, facecolor='#f8fafc', zorder=3))
    ax.text(93.25, 25.3, 'outputs', ha='center', va='center',
            color=C_OUT, fontsize=9.5, fontweight='bold', zorder=4)
    ax.text(93.25, 17.5, 'valid_o\nmin_key_o\nmin_data_o\ncount_o\nfull/empty\novf/udf',
            ha='center', va='center', color='#64748b', fontsize=8.2, zorder=4)
    arrow(x0+sw/2, yreg, x0+sw/2, 6.0, C_REG, 1.2)        # slot0 -> head out
    ax.plot([x0+sw/2, x0+sw/2], [4.0, yreg], color=C_REG, lw=1.4)
    ax.plot([x0+sw/2, 88], [4.0, 4.0], color=C_REG, lw=1.4)
    arrow(88, 4.0, 88, 9.5, C_REG, 1.4)
    ax.text(40, 3.0, 'slot 0 (minimum) driven combinationally as the head-of-queue view',
            color='#64748b', fontsize=7.8)

    # stage numbering badges
    for (bx, by, txt) in [(24,54.4,'1'),(52,54.9,'2'),(76,54.9,'3'),(24,27.9,'4')]:
        ax.add_patch(plt.Circle((bx+0.6, by-0.4), 1.0, color='#111827', zorder=6))
        ax.text(bx+0.6, by-0.4, txt, ha='center', va='center',
                color='white', fontsize=8.5, fontweight='bold', zorder=7)

    plt.tight_layout()
    plt.savefig('priority_queue_circuit.png', dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote priority_queue_circuit.png')

if __name__ == '__main__':
    main()
