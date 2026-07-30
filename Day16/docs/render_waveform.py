#!/usr/bin/env python3
"""
render_waveform.py  --  render a REAL captured VCD into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../smem_xbar.vcd smem_xbar_waveform.png

The trace is parsed from the VCD produced by the actual Icarus simulation of
tb_smem_xbar (`make icarus`), so it is a genuine captured waveform, not a
mock-up.  We zoom in on the opening directed vectors so the serialization is
visible:  a conflict-free gather (busy 1 cycle, phases=1), then a full
8-way bank conflict (busy stretches 8 cycles, phases=8), then a full broadcast
(phases=1) and a mixed broadcast+conflict warp (phases=2).

Signals: clk, rst_n, req_valid, req_mask, busy, resp_valid, resp_phases,
         resp_mask and gathered lanes resp_data[0]/[1].
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
                cur_t = int(line[1:])
                continue
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
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../smem_xbar.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'smem_xbar_waveform.png'

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    id2name, changes = parse_vcd(vcd)
    LANES, DATA_W = 8, 16
    names = ['clk', 'rst_n', 'req_valid', 'req_mask', 'busy',
             'resp_valid', 'resp_phases', 'resp_mask', 'resp_data']
    ids = {nm: name2id(id2name, nm) for nm in names}

    PERIOD = 10000                       # 10 ns in ps
    # first rising edge of req_valid -> anchor the window two cycles before it
    rv = changes.get(ids['req_valid'], [])
    first_req = next((t for (t, v) in rv if v == '1'), 50000)
    t0 = first_req - 2 * PERIOD
    NCYC = 26
    edges = [t0 + i * PERIOD for i in range(NCYC)]

    rows = []                            # (label, kind, values)

    def bit_row(label, sig):
        vals = [1 if sample(changes, ids[sig], e + 200) == '1'
                else (0 if sample(changes, ids[sig], e + 200) == '0' else None)
                for e in edges]
        rows.append((label, 'bit', vals))

    def busbin_row(label, sig, width):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + 200), width)
            vals.append(format(iv, '0{}b'.format(width)) if iv is not None else None)
        rows.append((label, 'bus', vals))

    def busint_row(label, sig, width):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + 200), width)
            vals.append(str(iv) if iv is not None else None)
        rows.append((label, 'bus', vals))

    def lane_row(label, sig, idx, width):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + 200), LANES * width)
            if iv is None:
                vals.append(None)
            else:
                vals.append('{:04X}'.format((iv >> (idx * width)) & ((1 << width) - 1)))
        rows.append((label, 'bus', vals))

    bit_row('clk', 'clk')
    bit_row('rst_n', 'rst_n')
    bit_row('req_valid', 'req_valid')
    busbin_row('req_mask', 'req_mask', LANES)
    bit_row('busy', 'busy')
    bit_row('resp_valid', 'resp_valid')
    busint_row('resp_phases', 'resp_phases', 4)
    busbin_row('resp_mask', 'resp_mask', LANES)
    lane_row('resp_data[0]', 'resp_data', 0, DATA_W)
    lane_row('resp_data[1]', 'resp_data', 1, DATA_W)

    ncyc = len(edges)
    fig, ax = plt.subplots(figsize=(15, 6.8))
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
    ax.set_title('smem_xbar  (LANES=8, BANKS=8)  —  real Icarus VCD capture\n'
                 'conflict-free (phases=1), then full 8-way bank conflict '
                 '(busy stretches 8 cycles, phases=8), broadcast (1), mixed (2)',
                 fontsize=11)
    plt.tight_layout()
    plt.savefig(out, dpi=130, bbox_inches='tight')
    print('wrote', out)

if __name__ == '__main__':
    main()
