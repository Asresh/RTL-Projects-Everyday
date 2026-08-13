#!/usr/bin/env python3
"""
render_waveform.py  --  render the REAL captured VCD from the Icarus run of
tb_warp_scheduler into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../warp_scheduler.vcd warp_scheduler_waveform.png

The trace is parsed from the VCD produced by the actual simulation
(`make icarus`), so it is a genuine captured waveform, not a mock-up.  We zoom
in on the directed prefix so the scheduler behaviour is visible: warp 0 fires a
3-long RAW chain and keeps stalling on its own in-flight writes, so its
ready-bit drops; meanwhile the Greedy-Then-Oldest policy keeps the pipe busy by
sticking with an independent warp (greedy) and falling back to the lowest-index
ready warp (oldest) whenever the greedy warp goes not-ready.
"""
import sys, re

def parse_vcd(path):
    id2name, changes = {}, {}
    cur_t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs and line.startswith('$var'):
                m = re.match(r'\$var\s+\w+\s+\d+\s+(\S+)\s+(\S+)', line)
                if m:
                    id2name.setdefault(m.group(1), m.group(2))
                continue
            if line.startswith('$enddefinitions'):
                in_defs = False
                continue
            if line.startswith('#'):
                cur_t = int(line[1:]); continue
            if in_defs:
                continue
            if line[0] in '01xzXZ' and len(line) >= 2 and line[1] != ' ':
                changes.setdefault(line[1:], []).append((cur_t, line[0]))
            elif line[0] in 'bB':
                parts = line.split()
                if len(parts) == 2:
                    changes.setdefault(parts[1], []).append((cur_t, parts[0][1:]))
    return id2name, changes

def name2id(id2name, want):
    for ident, nm in id2name.items():
        if nm == want:
            return ident
    return None

def sample(changes, ident, t):
    if ident not in changes:
        return 'x'
    v = 'x'
    for (tc, val) in changes[ident]:
        if tc <= t:
            v = val
        else:
            break
    return v

def bin2int(s, width):
    s = s.strip()
    if any(c in 'xzXZ' for c in s):
        return None
    return int(s.zfill(width)[-width:], 2)

def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../warp_scheduler.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'warp_scheduler_waveform.png'

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    id2name, changes = parse_vcd(vcd)
    NW = 8
    names = ['clk', 'rst_n', 'ib_valid', 'ready_mask',
             'issue_valid', 'issue_warp', 'issue_onehot']
    ids = {nm: name2id(id2name, nm) for nm in names}

    PERIOD = 10000                       # 10 ns in ps
    iv = changes.get(ids['issue_valid'], [])
    first_iss = next((t for (t, v) in iv if v == '1'), 40000)
    t0 = first_iss - 2 * PERIOD
    NCYC = 22
    edges = [t0 + i * PERIOD for i in range(NCYC)]

    rows = []

    def bit_row(label, sig):
        vals = []
        for e in edges:
            s = sample(changes, ids[sig], e + 200)
            vals.append(1 if s == '1' else (0 if s == '0' else None))
        rows.append((label, 'bit', vals))

    def busbin_row(label, sig, width):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + 200), width)
            vals.append(format(iv, '0{}b'.format(width)) if iv is not None else None)
        rows.append((label, 'bus', vals))

    def warpint_row(label, sig, width, gate):
        # show issue_warp as W# only when gate (issue_valid) is high, else '-'
        vals = []
        for e in edges:
            g = sample(changes, ids[gate], e + 200)
            iv = bin2int(sample(changes, ids[sig], e + 200), width)
            if g == '1' and iv is not None:
                vals.append('W%d' % iv)
            else:
                vals.append('-')
        rows.append((label, 'bus', vals))

    bit_row('clk', 'clk')
    bit_row('rst_n', 'rst_n')
    busbin_row('ib_valid', 'ib_valid', NW)
    busbin_row('ready_mask', 'ready_mask', NW)
    bit_row('issue_valid', 'issue_valid')
    warpint_row('issue_warp', 'issue_warp', 3, 'issue_valid')
    busbin_row('issue_onehot', 'issue_onehot', NW)

    ncyc = len(edges)
    fig, ax = plt.subplots(figsize=(15, 5.6))
    ax.set_xlim(-0.5, ncyc)
    ax.set_ylim(0, len(rows))

    C_BIT, C_BUS, C_GRID = '#2563eb', '#7c3aed', '#e5e7eb'
    for c in range(ncyc + 1):
        ax.axvline(c, color=C_GRID, lw=0.8, zorder=0)

    for r, (label, kind, vals) in enumerate(rows):
        y0, y1 = r + 0.15, r + 0.85
        ymid = (y0 + y1) / 2
        ax.text(-0.6, ymid, label, ha='right', va='center',
                fontsize=9, family='monospace')
        if kind == 'bit':
            if label == 'clk':
                xs, ys = [], []
                for c in range(ncyc):
                    xs += [c, c + 0.5, c + 0.5, c + 1]
                    ys += [y0, y0, y1, y1]
                ax.plot(xs, ys, color='#111827', lw=1.3)
                continue
            prev = None
            for c in range(ncyc):
                v = vals[c]
                y = y1 if v == 1 else y0
                ax.hlines(y, c, c + 1, color=C_BIT, lw=1.8)
                if prev is not None and v is not None and prev != v:
                    ax.vlines(c, y0, y1, color=C_BIT, lw=1.8)
                prev = v
        else:
            prev = None
            for c in range(ncyc):
                v = vals[c]
                ax.hlines(y0, c, c + 1, color=C_BUS, lw=1.4)
                ax.hlines(y1, c, c + 1, color=C_BUS, lw=1.4)
                if prev != v:
                    ax.vlines(c, y0, y1, color=C_BUS, lw=1.0)
                ax.text(c + 0.5, ymid, '' if v is None else str(v),
                        ha='center', va='center', fontsize=7,
                        family='monospace', color='#111827')
                prev = v

    ax.set_xticks([c + 0.5 for c in range(ncyc)])
    ax.set_xticklabels([f'{c}' for c in range(ncyc)], fontsize=8)
    ax.set_xlabel('clock cycle (sampled just after each posedge)', fontsize=10)
    ax.set_yticks([])
    for spine in ['top', 'right', 'left']:
        ax.spines[spine].set_visible(False)
    ax.set_title('warp_scheduler  (NW=8, NREG=8, WB_LATENCY=4)  --  real Icarus VCD capture\n'
                 'GTO issue: greedy warp held while ready; warp-0 RAW chain drops its '
                 'ready-bit and the oldest ready warp fills the bubble',
                 fontsize=11)
    plt.tight_layout()
    plt.savefig(out, dpi=130, bbox_inches='tight')
    print('wrote', out)

if __name__ == '__main__':
    main()
