#!/usr/bin/env python3
"""
render_waveform.py -- render the REAL captured VCD from the Icarus run of
tb_topk_stream_engine into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../topk_stream_engine.vcd topk_stream_engine_waveform.png

The trace is parsed from the VCD produced by the ACTUAL simulation
(`make icarus`), so it is a genuine captured waveform, not a hand-drawn mock-up.
We zoom in on the opening directed sequence: synchronous reset, then the
ascending fill/overflow stream in_data = 1,2,3,... . Each new value is the
current maximum, so it is inserted at slot 0 and the older entries shift down;
`count` climbs 0->K and then saturates while the array retains the K largest.
For every cycle the applied candidate is sampled just before the posedge and
the resulting sorted view just after it.
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
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../topk_stream_engine.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'topk_stream_engine_waveform.png'

    id2name, changes, widths = parse_vcd(vcd)

    DW, TW, K = 12, 8, 6
    def wid(nm): return widths.get(nm, 1)

    ids = {nm: name2id(id2name, nm) for nm in
           ['clk','rst','flush','in_valid','in_data','in_tag',
            'count_o','full_o','valid_o','data_o','tag_o']}

    # collect all clk rising edges
    clk_id = ids['clk']
    edges = [tc for (tc, val) in changes.get(clk_id, []) if val == '1']
    edges.sort()

    # window: skip nothing; take a slice covering reset + ascending fill.
    # The first posedges are during reset; grab 15 cycles from the start.
    win = edges[:16]

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    ncyc = len(win)
    # sample just-after-edge (state settled) and just-before-edge (applied input)
    after  = [t + 2 for t in win]
    before = [t - 2 for t in win]

    def dig_row(nm, when):
        return [sample(changes, ids[nm], t) for t in when]

    clk_vals  = ['1' if (i % 1 == 0) else '0' for i in range(ncyc)]  # placeholder
    rst_v     = dig_row('rst', before)
    inv_v     = dig_row('in_valid', before)
    full_v    = dig_row('full_o', after)

    indata = [to_int(sample(changes, ids['in_data'], t), DW, True) for t in before]
    invld  = [sample(changes, ids['in_valid'], t) for t in before]
    cnt    = [to_int(sample(changes, ids['count_o'], t), wid('count_o')) for t in after]

    # per-slot data (signed) and valid after the edge
    slot_data = [[None]*ncyc for _ in range(K)]
    slot_val  = [[0]*ncyc for _ in range(K)]
    def pad(word, width):
        # VCD strips leading zeros from vector values; restore full width.
        if word is None or (set(word) & set('xzXZ')):
            return None
        return word.rjust(width, '0')
    for ci, t in enumerate(after):
        dword = pad(sample(changes, ids['data_o'], t), K*DW)
        vword = pad(sample(changes, ids['valid_o'], t), K)
        for s in range(K):
            if dword is not None:
                seg = dword[::-1][s*DW:(s+1)*DW][::-1]
                slot_data[s][ci] = to_int(seg, DW, True)
            if vword is not None:
                slot_val[s][ci] = int(vword[::-1][s]) if s < len(vword) else 0

    # ------------------------------------------------------------------ plot
    plt.rcParams.update({'font.family': 'DejaVu Sans Mono', 'font.size': 9})
    rows = ['clk', 'rst', 'in_valid', 'in_data', 'count', 'full',
            'slot0', 'slot1', 'slot2', 'slot3', 'slot4', 'slot5']
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

    # gridlines per cycle
    for c in range(ncyc + 1):
        ax.plot([c, c], [-nrow + 0.4, 1.0], color='#e5e7eb', lw=0.6, zorder=0)

    # row labels
    for r, nm in enumerate(rows):
        ax.text(-0.35, y_of(r), nm, ha='right', va='center',
                color=col_lbl, fontsize=9, fontweight='bold')

    def draw_clk(r):
        y = y_of(r)
        xs, ys = [], []
        for c in range(ncyc):
            xs += [c, c+0.5, c+0.5, c+1.0]
            ys += [y-0.28, y-0.28, y+0.28, y+0.28]
        # build proper square wave low->high each cycle
        xs, ys = [], []
        for c in range(ncyc):
            xs += [c, c, c+0.5, c+0.5, c+1]
            ys += [y-0.28, y+0.28, y+0.28, y-0.28, y-0.28]
        ax.plot(xs, ys, color=col_clk, lw=1.4)

    def draw_dig(r, vals, color):
        y = y_of(r)
        prev = None
        for c in range(ncyc):
            v = vals[c]
            hi = (v == '1')
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
                    fontsize=8.5, fontweight='bold')

    r = 0
    draw_clk(r); r += 1
    draw_dig(r, rst_v, col_sig); r += 1
    draw_dig(r, invld, col_sig); r += 1
    draw_bus(r, [ (d if invld[c]=='1' else None) for c,d in enumerate(indata)], col_bus); r += 1
    draw_bus(r, cnt, col_bus); r += 1
    draw_dig(r, full_v, col_sig); r += 1
    for s in range(K):
        draw_bus(r, slot_data[s], col_hi, valids=slot_val[s]); r += 1

    # cycle numbers along the top
    for c in range(ncyc):
        ax.text(c+0.5, 0.85, f'{c}', ha='center', va='center',
                color='#9ca3af', fontsize=8)

    ax.set_title('topk_stream_engine — captured VCD (Icarus): synchronous reset, '
                 'then ascending fill/overflow in_data=1,2,3,…\n'
                 'each new max inserts at slot0, older entries shift down; count climbs 0→K then saturates '
                 '(slots show sorted-descending keys)',
                 fontsize=10.5, color=col_lbl, pad=12)

    plt.tight_layout()
    plt.savefig(out, dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote', out)

if __name__ == '__main__':
    main()
