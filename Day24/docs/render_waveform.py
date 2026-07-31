#!/usr/bin/env python3
"""
render_waveform.py -- render the REAL captured VCD from the Icarus run of
tb_tcam into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../tcam.vcd tcam_waveform.png

The trace is parsed from the VCD produced by the ACTUAL simulation
(`make icarus`), so it is a genuine captured waveform, not a hand-drawn mock-up.
We zoom in on the opening directed sequence: synchronous reset, then three
empty-table searches that MISS, then three exact-match entry writes
(idx 3/7/12), then exact searches that HIT the correct index with a fixed
1-cycle latency. For every cycle the applied write/search stimulus is sampled
just before the posedge and the registered result just after it.
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
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../tcam.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'tcam_waveform.png'

    id2name, changes, widths = parse_vcd(vcd)
    KW, DEPTH = 32, 16

    ids = {nm: name2id(id2name, nm) for nm in
           ['clk','rst','we','waddr','wvalid','search','skey',
            'match_valid_o','match_o','match_index_o','match_key_o','hit_map_o']}

    edges = sorted(tc for (tc, val) in changes.get(ids['clk'], []) if val == '1')
    win = edges[:16]
    ncyc = len(win)
    after  = [t + 2 for t in win]
    before = [t - 2 for t in win]

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    def dig_before(nm): return [sample(changes, ids[nm], t) for t in before]
    def dig_after(nm):  return [sample(changes, ids[nm], t) for t in after]

    rst_v    = dig_before('rst')
    we_v     = dig_before('we')
    search_v = dig_before('search')
    mv_v     = dig_after('match_valid_o')
    m_v      = dig_after('match_o')

    waddr = [to_int(sample(changes, ids['waddr'], t), widths.get('waddr',4)) for t in before]
    skey  = [to_int(sample(changes, ids['skey'],  t), KW) for t in before]
    midx  = [to_int(sample(changes, ids['match_index_o'], t), widths.get('match_index_o',4)) for t in after]
    mkey  = [to_int(sample(changes, ids['match_key_o'], t), KW) for t in after]
    hmap  = [to_int(sample(changes, ids['hit_map_o'], t), DEPTH) for t in after]

    def hx(v, nib):
        return None if v is None else f'{v:0{nib}X}'

    plt.rcParams.update({'font.family': 'DejaVu Sans Mono', 'font.size': 9})
    rows = ['clk','rst','we','waddr','search','skey',
            'match_valid','match','m_index','m_key','hit_map']
    nrow = len(rows)
    fig_h = 0.52 * nrow + 1.2
    fig, ax = plt.subplots(figsize=(14.0, fig_h))
    ax.set_xlim(-0.2, ncyc)
    ax.set_ylim(-nrow + 0.3, 1.2)
    ax.axis('off')

    col_lbl = '#1f2a44'; col_clk = '#2563eb'; col_sig = '#334155'
    col_bus = '#0e7490'; col_hi = '#7c3aed'

    def y_of(r): return -r
    for c in range(ncyc + 1):
        ax.plot([c, c], [-nrow + 0.4, 1.0], color='#e5e7eb', lw=0.6, zorder=0)
    for r, nm in enumerate(rows):
        ax.text(-0.35, y_of(r), nm, ha='right', va='center',
                color=col_lbl, fontsize=9, fontweight='bold')

    def draw_clk(r):
        y = y_of(r); xs, ys = [], []
        for c in range(ncyc):
            xs += [c, c, c+0.5, c+0.5, c+1]
            ys += [y-0.28, y+0.28, y+0.28, y-0.28, y-0.28]
        ax.plot(xs, ys, color=col_clk, lw=1.4)

    def draw_dig(r, vals, color):
        y = y_of(r); prev = None
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
            good = v is not None and (valids is None or valids[c])
            txt = '--' if (v is None or not good) else str(v)
            fc = '#ecfeff' if good else '#f3f4f6'
            ec = color if good else '#cbd5e1'
            ax.add_patch(Rectangle((c+0.06, y-0.3), 0.88, 0.6,
                         facecolor=fc, edgecolor=ec, lw=1.1))
            ax.text(c+0.5, y, txt, ha='center', va='center',
                    color=(color if good else '#94a3b8'),
                    fontsize=7.6, fontweight='bold')

    we_ok  = [v == '1' for v in we_v]
    sr_ok  = [v == '1' for v in search_v]
    mv_ok  = [v == '1' for v in mv_v]

    r = 0
    draw_clk(r); r += 1
    draw_dig(r, rst_v, col_sig); r += 1
    draw_dig(r, we_v, col_sig); r += 1
    draw_bus(r, [hx(v,1) for v in waddr], col_bus, valids=we_ok); r += 1
    draw_dig(r, search_v, col_sig); r += 1
    draw_bus(r, [hx(v,8) for v in skey], col_bus, valids=sr_ok); r += 1
    draw_dig(r, mv_v, col_sig); r += 1
    draw_dig(r, m_v, col_sig); r += 1
    draw_bus(r, [ (v if v is not None else None) for v in midx], col_hi,
             valids=[mv_ok[c] and (m_v[c]=='1') for c in range(ncyc)]); r += 1
    draw_bus(r, [hx(v,8) for v in mkey], col_hi,
             valids=[mv_ok[c] and (m_v[c]=='1') for c in range(ncyc)]); r += 1
    draw_bus(r, [hx(v,4) for v in hmap], col_hi, valids=mv_ok); r += 1

    for c in range(ncyc):
        ax.text(c+0.5, 0.85, f'{c}', ha='center', va='center',
                color='#9ca3af', fontsize=8)

    ax.set_title('tcam — captured VCD (Icarus): synchronous reset, three empty-table searches MISS '
                 '(match=0),\nthen exact entries written to idx 3/7/12 and searched back — each HITs the '
                 'correct m_index with fixed 1-cycle latency;\nhit_map shows the full parallel match bitmap, '
                 'match_valid marks a valid result cycle',
                 fontsize=10.0, color=col_lbl, pad=12)

    plt.tight_layout()
    plt.savefig(out, dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote', out)

if __name__ == '__main__':
    main()
