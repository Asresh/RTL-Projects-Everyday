#!/usr/bin/env python3
"""
render_waveform.py  --  render a REAL captured VCD into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../prefix_scan.vcd prefix_scan_waveform.png

The waveform is parsed from the VCD produced by the actual Icarus simulation of
tb_prefix_scan (make icarus), so it is a genuine captured trace, not a mock-up.
We show the reset release and the first directed stimulus vectors:
  - all-zeros, the 1..8 ramp (plain inclusive scan) and the two-segment vector.
Signals: clk, rst_n, in_valid, in_data lanes 0/1/7, in_seg, out_valid,
         out_data lanes 0/1/7 and out_seg, over the opening cycles.
"""
import sys, re

def parse_vcd(path):
    """Return (timescale_ps, id2name, changes) where changes[id] = [(t,val)]."""
    id2name = {}
    changes = {}
    cur_t = 0
    with open(path) as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if not line:
                continue
            if in_defs and line.startswith('$var'):
                # $var wire 1 ! out_valid $end   OR  ... 8 " out_seg [7:0] $end
                m = re.match(r'\$var\s+\w+\s+\d+\s+(\S+)\s+(\S+)', line)
                if m:
                    ident, name = m.group(1), m.group(2)
                    id2name.setdefault(ident, name)
                continue
            if line.startswith('$enddefinitions'):
                in_defs = False
                continue
            if line.startswith('#'):
                cur_t = int(line[1:])
                continue
            if in_defs:
                continue
            if line[0] in '01xzXZ' and len(line) >= 2 and line[1] not in ' ':
                # scalar change e.g. 1! or 0*
                val, ident = line[0], line[1:]
                changes.setdefault(ident, []).append((cur_t, val))
            elif line[0] in 'bB':
                # vector change e.g. b1010 #
                parts = line.split()
                if len(parts) == 2:
                    val, ident = parts[0][1:], parts[1]
                    changes.setdefault(ident, []).append((cur_t, val))
    return id2name, changes

def name2id(id2name, want):
    for ident, nm in id2name.items():
        if nm == want:
            return ident
    return None

def sample(changes, ident, t):
    """Value of signal `ident` at time t (last change <= t)."""
    if ident not in changes:
        return 'x'
    v = 'x'
    for (tc, val) in changes[ident]:
        if tc <= t:
            v = val
        else:
            break
    return v

def bin2int(s, width, signed):
    s = s.strip()
    if any(c in 'xzXZ' for c in s):
        return None
    s = s.zfill(width)[-width:]
    val = int(s, 2)
    if signed and s[0] == '1':
        val -= (1 << width)
    return val

def main():
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../prefix_scan.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'prefix_scan_waveform.png'

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    id2name, changes = parse_vcd(vcd)

    N, W, WACC = 8, 12, 15
    ids = {nm: name2id(id2name, nm) for nm in
           ['clk', 'rst_n', 'in_valid', 'in_data', 'in_seg',
            'out_valid', 'out_data', 'out_seg']}

    # clock period from the TB is 10 ns = 10000 ps; sample just after each
    # posedge so registered outputs have settled.
    PERIOD = 10000
    # first posedge is at t=5000; show the opening 15 cycles.
    edges = [5000 + i * PERIOD for i in range(15)]

    def lane(vec_id, idx, width, signed):
        raw = sample(changes, vec_id, 0)
        return None

    # Build per-cycle sampled values.
    rows = []  # (label, kind, values)   kind: 'bit' or 'bus'
    def bit_row(label, sig):
        vals = []
        for e in edges:
            v = sample(changes, ids[sig], e + 200)
            vals.append(1 if v == '1' else (0 if v == '0' else None))
        rows.append((label, 'bit', vals))

    def buslane_row(label, sig, idx, width, signed):
        vals = []
        for e in edges:
            raw = sample(changes, ids[sig], e + 200)
            iv = bin2int(raw, N * width, False)
            if iv is None:
                vals.append(None)
            else:
                lane_bits = (iv >> (idx * width)) & ((1 << width) - 1)
                if signed and (lane_bits >> (width - 1)) & 1:
                    lane_bits -= (1 << width)
                vals.append(lane_bits)
        rows.append((label, 'bus', vals))

    def flags_row(label, sig):
        vals = []
        for e in edges:
            raw = sample(changes, ids[sig], e + 200)
            iv = bin2int(raw, N, False)
            vals.append(format(iv, '08b') if iv is not None else None)
        rows.append((label, 'bus', vals))

    bit_row('clk', 'clk')
    bit_row('rst_n', 'rst_n')
    bit_row('in_valid', 'in_valid')
    buslane_row('in_data[0]', 'in_data', 0, W, True)
    buslane_row('in_data[1]', 'in_data', 1, W, True)
    buslane_row('in_data[7]', 'in_data', 7, W, True)
    flags_row('in_seg[7:0]', 'in_seg')
    bit_row('out_valid', 'out_valid')
    buslane_row('out_data[0]', 'out_data', 0, WACC, True)
    buslane_row('out_data[1]', 'out_data', 1, WACC, True)
    buslane_row('out_data[7]', 'out_data', 7, WACC, True)
    flags_row('out_seg[7:0]', 'out_seg')

    # ---- draw --------------------------------------------------------------
    ncyc = len(edges)
    fig, ax = plt.subplots(figsize=(14, 7.5))
    ax.set_xlim(-0.5, ncyc)
    ax.set_ylim(0, len(rows))

    C_BIT = '#2563eb'
    C_BUS = '#7c3aed'
    C_GRID = '#e5e7eb'

    for c in range(ncyc + 1):
        ax.axvline(c, color=C_GRID, lw=0.8, zorder=0)

    for r, (label, kind, vals) in enumerate(rows):
        y0 = r + 0.15
        y1 = r + 0.85
        ymid = (y0 + y1) / 2
        ax.text(-0.6, ymid, label, ha='right', va='center',
                fontsize=9, family='monospace')
        if kind == 'bit':
            if label == 'clk':
                # draw a real clock: two transitions per cycle
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
                if prev is not None and prev != v and v is not None and prev is not None:
                    ax.vlines(c, y0, y1, color=C_BIT, lw=1.8)
                prev = v
        else:
            prev = None
            for c in range(ncyc):
                v = vals[c]
                # bus lane: box with value; transition edges drawn as crosses
                ax.hlines(y0, c, c + 1, color=C_BUS, lw=1.4)
                ax.hlines(y1, c, c + 1, color=C_BUS, lw=1.4)
                if prev != v:
                    ax.vlines(c, y0, y1, color=C_BUS, lw=1.0)
                txt = '' if v is None else str(v)
                ax.text(c + 0.5, ymid, txt, ha='center', va='center',
                        fontsize=7.5, family='monospace', color='#111827')
                prev = v

    ax.set_xticks([c + 0.5 for c in range(ncyc)])
    ax.set_xticklabels([f'{c}' for c in range(ncyc)], fontsize=8)
    ax.set_xlabel('clock cycle (sampled just after each posedge)', fontsize=10)
    ax.set_yticks([])
    for spine in ['top', 'right', 'left']:
        ax.spines[spine].set_visible(False)
    ax.set_title('prefix_scan  (N=8, W=12, SIGNED)  —  real Icarus VCD capture\n'
                 'reset release, all-zero vector, 1..8 ramp (plain inclusive scan), '
                 'then a two-segment vector', fontsize=11)

    plt.tight_layout()
    plt.savefig(out, dpi=130, bbox_inches='tight')
    print('wrote', out)

if __name__ == '__main__':
    main()
