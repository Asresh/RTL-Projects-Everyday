#!/usr/bin/env python3
"""
render_waveform.py -- render the REAL captured VCD from the Icarus run of
tb_simt_stack into a timing-diagram PNG.

Usage:  python3 render_waveform.py ../simt_stack.vcd simt_stack_waveform.png

The trace is parsed from the VCD produced by the actual simulation
(`make icarus`), so it is a genuine captured waveform, not a mock-up.  We zoom
in on the directed showcase: the whole-warp base push, two uniform branches
(no divergence), one genuine divergence that splits lanes[3:0] from lanes[7:4]
(sp 1->3, active drops from 8 to 4), and the two reconvergence pops that restore
the full 0xFF mask.  For each cycle the *applied command* is sampled just before
the posedge and the *resulting* top-of-stack view just after it.
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
    vcd = sys.argv[1] if len(sys.argv) > 1 else '../simt_stack.vcd'
    out = sys.argv[2] if len(sys.argv) > 2 else 'simt_stack_waveform.png'

    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt

    id2name, changes = parse_vcd(vcd)
    names = ['clk', 'rst_n', 'cmd_valid', 'cmd', 'taken_mask',
             'sp', 'tos_pc', 'tos_rpc', 'tos_mask', 'active_lanes', 'reconverge']
    ids = {nm: name2id(id2name, nm) for nm in names}

    PERIOD = 10000                       # 10 ns in ps
    T0     = 35000                       # first posedge shown (empty stack)
    NCYC   = 12
    edges  = [T0 + i * PERIOD for i in range(NCYC)]

    CMD_TXT = {0: 'NOP', 1: 'DIVERGE', 2: 'SETPC', 3: 'POP'}

    rows = []

    def clk_row():
        rows.append(('clk', 'clk', None))

    def bit_row(label, sig, off):
        vals = []
        for e in edges:
            s = sample(changes, ids[sig], e + off)
            vals.append(1 if s == '1' else (0 if s == '0' else None))
        rows.append((label, 'bit', vals))

    def cmd_row():
        # applied command: sampled just before the posedge, blank if not valid
        vals = []
        for e in edges:
            cv = sample(changes, ids['cmd_valid'], e - 2000)
            cc = bin2int(sample(changes, ids['cmd'], e - 2000), 2)
            vals.append(CMD_TXT.get(cc, '?') if cv == '1' and cc is not None else '.')
        rows.append(('cmd', 'bus', vals))

    def hexmask_row(label, sig, width, off):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + off), width)
            vals.append(('%0*X' % ((width + 3) // 4, iv)) if iv is not None else None)
        rows.append((label, 'bus', vals))

    def int_row(label, sig, width, off):
        vals = []
        for e in edges:
            iv = bin2int(sample(changes, ids[sig], e + off), width)
            vals.append(str(iv) if iv is not None else None)
        rows.append((label, 'bus', vals))

    clk_row()
    bit_row('rst_n', 'rst_n', 2000)
    cmd_row()                                        # applied command (pre-edge)
    hexmask_row('taken_mask', 'taken_mask', 8, -2000)
    int_row('sp', 'sp', 3, 2000)                     # results (post-edge)
    hexmask_row('tos_pc', 'tos_pc', 16, 2000)
    hexmask_row('tos_rpc', 'tos_rpc', 16, 2000)
    hexmask_row('tos_mask', 'tos_mask', 8, 2000)
    int_row('active', 'active_lanes', 4, 2000)
    bit_row('reconverge', 'reconverge', 2000)

    ncyc = len(edges)
    fig, ax = plt.subplots(figsize=(15, 6.4))
    ax.set_xlim(-0.5, ncyc)
    ax.set_ylim(0, len(rows))

    C_BIT, C_BUS, C_GRID = '#2563eb', '#7c3aed', '#e5e7eb'
    for c in range(ncyc + 1):
        ax.axvline(c, color=C_GRID, lw=0.8, zorder=0)

    for r, (label, kind, vals) in enumerate(rows):
        rr = len(rows) - 1 - r                        # draw top-down
        y0, y1 = rr + 0.15, rr + 0.85
        ymid = (y0 + y1) / 2
        ax.text(-0.6, ymid, label, ha='right', va='center',
                fontsize=9, family='monospace')
        if kind == 'clk':
            xs, ys = [], []
            for c in range(ncyc):
                xs += [c, c + 0.5, c + 0.5, c + 1]
                ys += [y0, y0, y1, y1]
            ax.plot(xs, ys, color='#111827', lw=1.3)
            continue
        if kind == 'bit':
            prev = None
            for c in range(ncyc):
                v = vals[c]
                y = y1 if v == 1 else y0
                col = '#dc2626' if (label == 'reconverge' and v == 1) else C_BIT
                ax.hlines(y, c, c + 1, color=col, lw=1.9)
                if prev is not None and v is not None and prev != v:
                    ax.vlines(c, y0, y1, color=C_BIT, lw=1.6)
                prev = v
        else:
            prev = None
            for c in range(ncyc):
                v = vals[c]
                ax.hlines(y0, c, c + 1, color=C_BUS, lw=1.4)
                ax.hlines(y1, c, c + 1, color=C_BUS, lw=1.4)
                if prev != v:
                    ax.vlines(c, y0, y1, color=C_BUS, lw=1.0)
                txt = '' if v is None else str(v)
                ax.text(c + 0.5, ymid, txt, ha='center', va='center', fontsize=7.5,
                        family='monospace', color='#111827')
                prev = v

    ax.set_xticks([c + 0.5 for c in range(ncyc)])
    ax.set_xticklabels([f'{c}' for c in range(ncyc)], fontsize=8)
    ax.set_xlabel('clock cycle  (command sampled pre-edge, top-of-stack sampled post-edge)',
                  fontsize=10)
    ax.set_yticks([])
    for spine in ['top', 'right', 'left']:
        ax.spines[spine].set_visible(False)
    ax.set_title('simt_stack  (NLANES=8, PCW=16, DEPTH=6)  --  real Icarus VCD capture\n'
                 'base push -> 2 uniform branches -> genuine divergence (sp 1->3, active 8->4) '
                 '-> 2 reconvergence pops restore the full 0xFF mask',
                 fontsize=11)
    plt.tight_layout()
    plt.savefig(out, dpi=130, bbox_inches='tight')
    print('wrote', out)

if __name__ == '__main__':
    main()
