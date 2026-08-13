#!/usr/bin/env python3
"""
render_waveform.py -- render the REAL captured VCD from the Icarus run of
tb_gpu_coalescer into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../gpu_coalescer.vcd gpu_coalescer_waveform.png

The trace is parsed from the VCD produced by the ACTUAL simulation
(`make icarus`), so it is a genuine captured waveform, not a hand-drawn mock-up.
The window covers the opening directed sequence: synchronous reset, then the
"same-seg" warp (all 8 lanes in ONE 32-byte segment -> a single coalesced
transaction with lane_mask = 1111_1111), immediately followed by the
"all-distinct" warp (each lane in its own segment -> 8 back-to-back
transactions, lane_mask walking 0000_0001, 0000_0010, ...).
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
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../gpu_coalescer.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'gpu_coalescer_waveform.png'

    id2name, changes, widths = parse_vcd(vcd)

    names = ['clk','rst_n','in_valid','in_ready','busy','req_mask',
             'txn_valid','txn_index','txn_lane_mask','txn_base',
             'txn_last','num_txn']
    ids = {nm: name2id(id2name, nm) for nm in names}

    clk_id = ids['clk']
    edges = sorted(tc for (tc, val) in changes.get(clk_id, []) if val == '1')

    # window: reset spans the first ~4 edges; show reset + the first two warps.
    win = edges[3:24]
    ncyc = len(win)

    before = [t - 2 for t in win]   # applied stimulus (settled before edge)
    after  = [t + 2 for t in win]   # registered outputs (settled after edge)

    def dbin(nm, when, width):
        out = []
        for t in when:
            raw = sample(changes, ids[nm], t)
            if raw is None or (set(raw) & set('xzXZ')):
                out.append(None)
            else:
                out.append(raw.rjust(width, '0'))
        return out

    def dhex(nm, when, width):
        out = []
        for t in when:
            v = to_int(sample(changes, ids[nm], t), width)
            out.append(None if v is None else ('0x%X' % v))
        return out

    def dlvl(nm, when):
        return [sample(changes, ids[nm], t) for t in when]

    rst_v   = dlvl('rst_n',    before)
    inv_v   = dlvl('in_valid', before)
    rdy_v   = dlvl('in_ready', after)
    busy_v  = dlvl('busy',     after)
    tv_v    = dlvl('txn_valid',after)
    last_v  = dlvl('txn_last', after)

    reqm    = dbin('req_mask',      before, widths.get('req_mask', 8))
    tmask   = dbin('txn_lane_mask', after,  widths.get('txn_lane_mask', 8))
    tidx    = [to_int(sample(changes, ids['txn_index'], t), widths.get('txn_index',4)) for t in after]
    ntxn    = [to_int(sample(changes, ids['num_txn'],   t), widths.get('num_txn',4))   for t in after]
    tbase   = dhex('txn_base', after, widths.get('txn_base', 32))

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle

    plt.rcParams.update({'font.family': 'DejaVu Sans Mono', 'font.size': 9})
    rows = ['clk','rst_n','in_valid','in_ready','busy',
            'req_mask','txn_valid','txn_index','txn_lane_mask','txn_base',
            'txn_last','num_txn']
    nrow = len(rows)
    fig, ax = plt.subplots(figsize=(14.5, 0.52*nrow + 1.4))
    ax.set_xlim(-0.2, ncyc); ax.set_ylim(-nrow + 0.3, 1.4); ax.axis('off')

    col_lbl = '#1f2a44'; col_clk = '#2563eb'; col_sig = '#334155'
    col_bus = '#0e7490'; col_hi  = '#7c3aed'; col_txn = '#b91c1c'

    def y_of(r): return -r
    for c in range(ncyc + 1):
        ax.plot([c, c], [-nrow + 0.4, 1.1], color='#e5e7eb', lw=0.6, zorder=0)
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
            ax.plot([c, c+1], [y+lvl, y+lvl], color=color, lw=1.7)
            if prev is not None and prev != lvl:
                ax.plot([c, c], [y+prev, y+lvl], color=color, lw=1.7)
            prev = lvl

    def draw_bus(r, vals, color, hi_when=None):
        y = y_of(r)
        for c in range(ncyc):
            v = vals[c]
            txt = '--' if v is None else str(v)
            good = (v is not None) and (hi_when is None or hi_when[c])
            fc = '#ecfeff' if good else '#f3f4f6'
            ec = color if good else '#cbd5e1'
            ax.add_patch(Rectangle((c+0.06, y-0.3), 0.88, 0.6,
                         facecolor=fc, edgecolor=ec, lw=1.1))
            ax.text(c+0.5, y, txt, ha='center', va='center',
                    color=(color if good else '#94a3b8'),
                    fontsize=7.6, fontweight='bold')

    r = 0
    draw_clk(r); r += 1
    draw_dig(r, rst_v,  col_sig); r += 1
    draw_dig(r, inv_v,  col_sig); r += 1
    draw_dig(r, rdy_v,  col_sig); r += 1
    draw_dig(r, busy_v, col_sig); r += 1
    draw_bus(r, [ (m if inv_v[c]=='1' else None) for c,m in enumerate(reqm)], col_bus); r += 1
    draw_dig(r, tv_v,   col_txn); r += 1
    draw_bus(r, [ (str(v) if tv_v[c]=='1' and v is not None else None) for c,v in enumerate(tidx)],  col_hi, hi_when=[tv_v[c]=='1' for c in range(ncyc)]); r += 1
    draw_bus(r, [ (m if tv_v[c]=='1' else None) for c,m in enumerate(tmask)], col_hi, hi_when=[tv_v[c]=='1' for c in range(ncyc)]); r += 1
    draw_bus(r, [ (b if tv_v[c]=='1' else None) for c,b in enumerate(tbase)], col_hi, hi_when=[tv_v[c]=='1' for c in range(ncyc)]); r += 1
    draw_dig(r, last_v, col_txn); r += 1
    draw_bus(r, [ (str(v) if v is not None else None) for v in ntxn], col_bus); r += 1

    for c in range(ncyc):
        ax.text(c+0.5, 1.0, f'{c}', ha='center', va='center',
                color='#9ca3af', fontsize=8)

    ax.set_title(
        'gpu_coalescer  --  captured VCD (Icarus Verilog)\n'
        'reset  ->  "same-seg" warp: 8 lanes in one 32B segment coalesce to a SINGLE txn (lane_mask=11111111, num_txn=1)  '
        '->  "all-distinct" warp: 8 lanes in 8 segments emit 8 txns (lane_mask walks 00000001,00000010,...)',
        fontsize=10, color=col_lbl, pad=12)

    plt.tight_layout()
    plt.savefig(out, dpi=140, bbox_inches='tight', facecolor='white')
    print('wrote', out)

if __name__ == '__main__':
    main()
