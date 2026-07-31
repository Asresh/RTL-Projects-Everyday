#!/usr/bin/env python3
"""
render_waveform.py -- render the REAL captured VCD from the Icarus run of
tb_priority_queue into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../priority_queue.vcd priority_queue_waveform.png

The trace is parsed from the VCD produced by the ACTUAL simulation
(`make icarus`), so it is a genuine captured waveform, not a hand-drawn mock-up.
We zoom in on the opening directed sequence: synchronous reset, then the
fill-to-full enqueue burst (keys 50,20,80,20,5,95,35,60) followed by the first
extract-min pops. Because the array is kept sorted ascending, `min_key` always
shows the current minimum and `count` climbs 0->N then holds at full.
For every cycle the applied request is sampled just before the posedge and the
resulting sorted view just after it.
"""
import sys, re

def parse_vcd(path):
    id2name, changes, widths = {}, {}, {}
    cur_t = 0
    in_defs = True
    with open(path) as f:
        for line in f:
            s = line.strip()
            if not s:
                continue
            if in_defs and s.startswith('$var'):
                m = re.match(r'\$var\s+\w+\s+(\d+)\s+(\S+)\s+([^\s\[]+)', s)
                if m:
                    id2name.setdefault(m.group(2), m.group(3))
                    widths[m.group(3)] = int(m.group(1))
                continue
            if s.startswith('$enddefinitions'):
                in_defs = False
                continue
            if in_defs:
                continue
            if s.startswith('#'):
                cur_t = int(s[1:]); continue
            c0 = s[0]
            if c0 in '01xzXZ' and len(s) >= 2 and s[1] != ' ':
                changes.setdefault(s[1:], []).append((cur_t, s[0]))
            elif c0 in 'bB':
                p = s.split()
                if len(p) == 2:
                    changes.setdefault(p[1], []).append((cur_t, p[0][1:]))
    return id2name, changes, widths

def name2id(id2name, want):
    for ident, nm in id2name.items():
        if nm == want:
            return ident
    return None

def sample(changes, ident, t):
    v = 'x'
    for (tc, val) in changes.get(ident, []):
        if tc <= t:
            v = val
        else:
            break
    return v

def to_int(bits, width, signed=False):
    if bits == 'x' or set(bits) & set('xzXZ'):
        return None
    v = int(bits, 2)
    if signed and width and (v >> (width - 1)) & 1:
        v -= (1 << width)
    return v

def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../priority_queue.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'priority_queue_waveform.png'

    id2name, changes, widths = parse_vcd(vcd)

    KW, DW, N = 12, 8, 8
    NSLOT = 4  # how many of the low slots to draw
    def wid(nm): return widths.get(nm, 1)

    ids = {nm: name2id(id2name, nm) for nm in
           ['clk','rst','enq','deq','enq_key','deq_dummy',
            'count_o','full_o','empty_o','min_key_o','slot_valid_o','slot_key_o']}

    clk_id = ids['clk']
    edges = [tc for (tc, val) in changes.get(clk_id, []) if val == '1']
    edges.sort()
    win = edges[:16]

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    ncyc = len(win)
    after  = [t + 2 for t in win]
    before = [t - 2 for t in win]

    def dig_before(nm): return [sample(changes, ids[nm], t) for t in before]
    def dig_after(nm):  return [sample(changes, ids[nm], t) for t in after]

    rst_v   = dig_before('rst')
    enq_v   = dig_before('enq')
    deq_v   = dig_before('deq')
    full_v  = dig_after('full_o')
    empty_v = dig_after('empty_o')

    enqk  = [to_int(sample(changes, ids['enq_key'], t), KW) for t in before]
    enqvld= [sample(changes, ids['enq'], t) for t in before]
    cnt   = [to_int(sample(changes, ids['count_o'], t), wid('count_o')) for t in after]
    mink  = [to_int(sample(changes, ids['min_key_o'], t), KW) for t in after]
    minvld= [sample(changes, ids['empty_o'], t) for t in after]  # empty=1 -> no min

    slot_key = [[None]*ncyc for _ in range(NSLOT)]
    slot_val = [[0]*ncyc for _ in range(NSLOT)]
    def pad(word, width):
        if word is None or (set(word) & set('xzXZ')):
            return None
        return word.rjust(width, '0')
    for ci, t in enumerate(after):
        kword = pad(sample(changes, ids['slot_key_o'], t), N*KW)
        vword = pad(sample(changes, ids['slot_valid_o'], t), N)
        for s in range(NSLOT):
            if kword is not None:
                seg = kword[::-1][s*KW:(s+1)*KW][::-1]
                slot_key[s][ci] = to_int(seg, KW)
            if vword is not None:
                slot_val[s][ci] = int(vword[::-1][s]) if s < len(vword) else 0

    # ------------------------------------------------------------------ plot
    plt.rcParams.update({'font.family': 'DejaVu Sans Mono', 'font.size': 9})
    rows = ['clk', 'rst', 'enq', 'deq', 'enq_key', 'count', 'min_key',
            'full', 'empty', 'slot0', 'slot1', 'slot2', 'slot3']
    nrow = len(rows)
    fig_h = 0.52 * nrow + 1.2
    fig, ax = plt.subplots(figsize=(13.5, fig_h))
    ax.set_xlim(-0.2, ncyc)
    ax.set_ylim(-nrow + 0.3, 1.2)
    ax.axis('off')

    col_lbl = '#1f2a44'
    col_clk = '#2563eb'
    col_sig = '#334155'
    col_bus = '#0e7490'
    col_hi  = '#7c3aed'

    def y_of(r): return -r

    for c in range(ncyc + 1):
        ax.plot([c, c], [-nrow + 0.4, 1.0], color='#e5e7eb', lw=0.6, zorder=0)

    for r, nm in enumerate(rows):
        ax.text(-0.35, y_of(r), nm, ha='right', va='center',
                color=col_lbl, fontsize=9, fontweight='bold')

    def draw_clk(r):
        y = y_of(r)
        xs, ys = [], []
        for c in range(ncyc):
            xs += [c, c, c+0.5, c+0.5, c+1]
            ys += [y-0.28, y+0.28, y+0.28, y-0.28, y-0.28]
        ax.plot(xs, ys, color=col_clk, lw=1.4)

    def draw_dig(r, vals, color):
        y = y_of(r)
        prev = None
        for c in range(ncyc):
            hi = (vals[c] == '1')
            lvl = 0.28 if hi else -0.28
            ax.plot([c, c+1], [y+lvl, y+lvl], color=color, lw=1.6)
            if prev is not None and prev != lvl:
                ax.plot([c, c], [y+prev, y+lvl], color=color, lw=1.6)
            prev = lvl

    def draw_bus(r, vals, color, valids=None):
        y = y_of(r)
        for c in range(ncyc):
            v = vals[c]
            txt = '--' if v is None else str(v)
            good = v is not None and (valids is None or valids[c])
            fc = '#ecfeff' if good else '#f3f4f6'
            ec = color if good else '#cbd5e1'
            ax.add_patch(Rectangle((c+0.06, y-0.3), 0.88, 0.6,
                         facecolor=fc, edgecolor=ec, lw=1.1))
            ax.text(c+0.5, y, txt, ha='center', va='center',
                    color=(color if good else '#94a3b8'),
                    fontsize=8.2, fontweight='bold')

    r = 0
    draw_clk(r); r += 1
    draw_dig(r, rst_v, col_sig); r += 1
    draw_dig(r, enq_v, col_sig); r += 1
    draw_dig(r, deq_v, col_sig); r += 1
    draw_bus(r, [ (k if enqvld[c]=='1' else None) for c,k in enumerate(enqk)], col_bus); r += 1
    draw_bus(r, cnt, col_bus); r += 1
    draw_bus(r, mink, col_bus, valids=[ (mv=='0') for mv in minvld]); r += 1
    draw_dig(r, full_v, col_sig); r += 1
    draw_dig(r, empty_v, col_sig); r += 1
    for s in range(NSLOT):
        draw_bus(r, slot_key[s], col_hi, valids=slot_val[s]); r += 1

    for c in range(ncyc):
        ax.text(c+0.5, 0.85, f'{c}', ha='center', va='center',
                color='#9ca3af', fontsize=8)

    ax.set_title('priority_queue — captured VCD (Icarus): synchronous reset, then fill-to-full '
                 'enqueue burst keys=50,20,80,20,5,95,35,60\n'
                 'array stays sorted ascending so slot0/min_key track the running minimum; '
                 'count climbs 0→N then holds at full (extract-min pops the head)',
                 fontsize=10.5, color=col_lbl, pad=12)

    plt.tight_layout()
    plt.savefig(out, dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote', out)

if __name__ == '__main__':
    main()
