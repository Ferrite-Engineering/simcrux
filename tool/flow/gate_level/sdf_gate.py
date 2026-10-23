#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Measure SDF delay annotation in Icarus on LibreLane runs (the SDF gate).

Usage:
  sdf_gate.py sweep --suite <oss-cad-suite> --run <picorv32 run dir> --out <dir>
      [--corner nom_tt_025C_1v80] [--period <ns>]... [--in-pct 20 | --at-edge]
  sdf_gate.py account <file.sdf> <vvp log>
  sdf_gate.py annotate --suite <oss-cad-suite> --run <adder run dir> --corner <c>
      --out <dir>
  sdf_gate.py mac --suite <oss-cad-suite> --pdk <sky130_fd_sc_hd/verilog dir>
      --out <dir> [--period <ns>]...

A measurement tool, independent of SimCrux's own code. `sweep` runs PicoRV32's
self-checking testbench (`../../../verification/fixtures/flow/gate_level/
picorv32/`) at RTL and against the run's `final/nl` netlist annotated from
`final/sdf/<corner>/<top>__<corner>.sdf` (`-gspecify -ginterconnect`, the cell
models' timing variants: no `FUNCTIONAL`, no `UNIT_DELAY`), one clock period
at a time, and compares the two port dumps with `gls_compare.py`. The inputs
the testbench drives change `--in-pct` percent of the period after the clock
edge (the run's own `IO_DELAY_CONSTRAINT` by default), or at the edge with
`--at-edge`. `account` matches every SDF message Icarus printed to the
construct on the SDF line it names. `annotate` only annotates a small run's
SDF (the path adder) and accounts for it.

Writes `<out>/sweep.json` or `<out>/annotate_<corner>.json` and the logs beside
them; never writes into the fixtures.
"""

import argparse
import collections
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, '..', '..', '..'))
FIXTURES = os.path.join(REPO, 'verification', 'fixtures', 'flow', 'gate_level')
sys.path.insert(0, HERE)
import gls_compare  # noqa: E402

CONSTRUCTS = ('INTERCONNECT', 'IOPATH', 'COND', 'SETUP', 'HOLD', 'SETUPHOLD',
              'WIDTH', 'RECOVERY', 'REMOVAL', 'RECREM', 'PERIOD')


def resolved(run):
    with open(os.path.join(run, 'resolved.json')) as f:
        return json.load(f)


def models_of(res, pdk_root):
    """The run's CELL_VERILOG_MODELS, rebased onto this machine's ciel root."""
    out = []
    for m in res['CELL_VERILOG_MODELS']:
        m = m.replace('<home>', os.path.expanduser('~'))
        if not os.path.exists(m) and pdk_root:
            tail = m.split('/ciel/', 1)[-1]
            m = os.path.join(pdk_root, 'ciel', tail)
        out.append(m)
    return out


def account(sdf_path, log_lines):
    """Every SDF message Icarus printed, matched to the construct it names."""
    lines = open(sdf_path).read().split('\n')
    kind_of_line = {}
    totals = collections.Counter()
    celltype = None
    for i, raw in enumerate(lines, 1):
        s = raw.strip()
        m = re.match(r'\(CELLTYPE "([^"]+)"\)', s)
        if m:
            celltype = m.group(1)
        prev = lines[i - 2].strip() if i >= 2 else ''
        for k in CONSTRUCTS:
            if re.match(r'\(' + k + r'\b', s):
                name = 'IOPATH under COND' if k == 'IOPATH' and prev.startswith('(COND') else k
                totals[name] += 1
                kind_of_line[i] = (name, celltype, s)
        if '\\' in s:
            totals['lines with an escaped name'] += 1
    messages = collections.Counter()
    by_construct = collections.defaultdict(collections.Counter)
    examples = collections.defaultdict(list)
    other = []
    pat = re.compile(r'^SDF (ERROR|WARNING|INFO): [^:]*:(\d+): (.*)$')
    for raw in log_lines:
        if not raw.startswith('SDF'):
            continue
        m = pat.match(raw)
        if not m:
            other.append(re.sub(r'^SDF (\w+): .*?\.sdf: ', r'SDF \1: <sdf>: ', raw))
            continue
        level, ln, text = m.group(1), int(m.group(2)), m.group(3)
        text = re.sub(r' in \S+$', ' in <instance>', text)
        text = re.sub(r'ModPath \S+ -> \S+', 'ModPath <in> -> <out>', text)
        key = '%s: %s' % (level, text)
        messages[key] += 1
        k = kind_of_line.get(ln)
        where = '(header)' if k is None else '%s in %s' % (k[0], k[1])
        by_construct[key][where] += 1
        if len(examples[key]) < 2:
            examples[key].append({'line': ln, 'text': (lines[ln - 1].strip() if ln <= len(lines) else '')[:120]})
    return {'sdf_totals': dict(totals), 'messages': dict(messages),
            'messages_by_construct': {k: dict(v) for k, v in by_construct.items()},
            'examples': dict(examples), 'other_lines': other[:5],
            'other_count': len(other)}


def split_differences(rtl_vcd, gate_vcd, netlist):
    """Real differences split into both-known and gate-X, with the first of each."""
    ports = set(gls_compare.netlist_ports(netlist))
    names, rtl = gls_compare.read_samples(rtl_vcd, 'clk', 'tb.uut', ports)
    _, gate = gls_compare.read_samples(gate_vcd, 'clk', 'tb.uut', ports)
    known = gate_x = 0
    first_known = first_x = None
    for k in range(min(len(rtl), len(gate))):
        for n in names:
            r, g = rtl[k][1][n], gate[k][1].get(n)
            if g is None or r == g:
                continue
            for br, bg in zip(r, g):
                if br in '01' and bg in '01' and br != bg:
                    known += 1
                    if first_known is None:
                        first_known = {'sample': k, 'time_ps': rtl[k][0], 'port': n}
                elif br in '01' and bg not in '01':
                    gate_x += 1
                    if first_x is None:
                        first_x = {'sample': k, 'time_ps': rtl[k][0], 'port': n}
    return {'real_both_known_bits': known, 'real_gate_x_bits': gate_x,
            'first_both_known': first_known, 'first_gate_x': first_x}


def simulate(a, tag, period, gate, sdf=None):
    """One RTL or gate-level run; returns the summary and the log lines."""
    out = a.out
    run = a.run
    res = resolved(run)
    design = res['DESIGN_NAME']
    vcd = os.path.join(out, tag + '.vcd')
    vvp = os.path.join(out, tag + '.vvp')
    tb = os.path.join(FIXTURES, 'picorv32', 'tb_picorv32.v')
    dump = os.path.join(FIXTURES, 'picorv32', 'gls_portdump.v')
    args = [os.path.join(a.suite, 'bin', 'iverilog'), '-g2012', '-s', 'tb', '-s',
            'gls_portdump', '-DGLS_VCD="%s"' % vcd, '-DHALF_PERIOD=%g' % (period / 2),
            '-o', vvp]
    if not a.at_edge:
        args.append('-DIN_DELAY=%g' % (period * a.in_pct / 100))
    if gate:
        args += ['-gspecify', '-ginterconnect', '-DGLS_SDF="%s"' % sdf]
        srcs = [tb, dump] + models_of(res, a.pdk_root) + [
            os.path.join(run, 'final', 'nl', design + '.nl.v')]
    else:
        srcs = [tb, dump, a.rtl]
    t0 = time.time()
    c = subprocess.run(args + srcs, capture_output=True, text=True)
    r = subprocess.run([os.path.join(a.suite, 'bin', 'vvp'), '-n', vvp],
                       capture_output=True, text=True)
    log = (r.stdout + r.stderr).splitlines()
    with open(os.path.join(out, tag + '.log'), 'w') as f:
        f.write('\n'.join(log) + '\n')
    os.remove(vvp) if os.path.exists(vvp) else None
    passed = 'TEST PASSED' in r.stdout
    tb_line = next((l for l in r.stdout.splitlines() if l.startswith('cycles=')), None)
    return {'tag': tag, 'compile_exit': c.returncode, 'vvp_exit': r.returncode,
            'testbench': 'passed' if passed else 'failed', 'testbench_line': tb_line,
            'seconds': round(time.time() - t0, 1)}, log


def sweep(a):
    os.makedirs(a.out, exist_ok=True)
    res = resolved(a.run)
    design = res['DESIGN_NAME']
    sdf = os.path.join(a.run, 'final', 'sdf', a.corner, '%s__%s.sdf' % (design, a.corner))
    netlist = os.path.join(a.run, 'final', 'nl', design + '.nl.v')
    if a.rtl is None:
        sources = res.get('VERILOG_FILES') or []
        a.rtl = sources[0].replace('dir::', '')
    rows = []
    annotation = None
    for period in a.period or [25.0, 20.0, 15.0, 12.0, 10.0, 8.0, 7.0, 6.0, 5.0, 4.0]:
        suffix = 'p%g' % period
        rtl, _ = simulate(a, 'rtl_' + suffix, period, gate=False)
        gate, log = simulate(a, 'sdf_' + suffix, period, gate=True, sdf=sdf)
        if annotation is None:
            annotation = account(sdf, log)
        row = {'period_ns': period, 'rtl': rtl, 'gate': gate}
        rtl_vcd = os.path.join(a.out, rtl['tag'] + '.vcd')
        gate_vcd = os.path.join(a.out, gate['tag'] + '.vcd')
        if os.path.exists(rtl_vcd) and os.path.exists(gate_vcd):
            cmp = gls_compare.compare(rtl_vcd, gate_vcd, set(gls_compare.netlist_ports(netlist)))
            row['comparison'] = {k: cmp[k] for k in (
                'samples_compared', 'real_bits', 'samples_with_real_difference',
                'x_asymmetry_bits', 'samples_with_x_asymmetry')}
            row['split'] = split_differences(rtl_vcd, gate_vcd, netlist)
        row['timing_messages'] = [l for l in log if re.search(r'(?i)violation|setup|hold', l)]
        rows.append(row)
        print(json.dumps({'period_ns': period, 'testbench': gate['testbench'],
                          'real': row.get('comparison', {}).get('samples_with_real_difference')}))
        sys.stdout.flush()
    doc = {'design': design, 'corner': a.corner,
           'input_delay': 'at the edge' if a.at_edge else '%g%% of the period' % a.in_pct,
           'annotation': annotation, 'periods': rows}
    with open(os.path.join(a.out, 'sweep.json'), 'w') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')


def mac(a):
    """The research MAC with the synthetic uniform-delay SDF, period by period."""
    os.makedirs(a.out, exist_ok=True)
    base = os.path.join(FIXTURES, 'mac')
    sdf = os.path.join(FIXTURES, 'sdf', 'mac_0p5ns.sdf')
    pdk = a.pdk
    models = [os.path.join(pdk, 'primitives.v'), os.path.join(pdk, 'sky130_fd_sc_hd.v')]
    netlist = os.path.join(base, 'net.v')
    rows = []
    for period in a.period or [40.0, 20.0, 16.0, 12.0, 8.0]:
        runs = {}
        for kind in ('rtl', 'sdf'):
            tag = '%s_mac_p%g' % (kind, period)
            vcd = os.path.join(a.out, tag + '.vcd')
            vvp = os.path.join(a.out, tag + '.vvp')
            dump = os.path.join(a.out, tag + '_dump.v')
            with open(dump, 'w') as f:
                f.write('module gls_portdump;\n  initial begin\n')
                if kind == 'sdf':
                    f.write('    $sdf_annotate("%s", tb.uut);\n' % sdf)
                f.write('    $dumpfile("%s");\n    $dumpvars(0, tb.uut.clk, tb.uut.rst_n, '
                        'tb.uut.en, tb.uut.a, tb.uut.b, tb.uut.acc, tb.uut.cnt, '
                        'tb.uut.parity);\n  end\nendmodule\n' % vcd)
            args = [os.path.join(a.suite, 'bin', 'iverilog'), '-g2012', '-s', 'tb', '-s',
                    'gls_portdump', '-DOUT="%s"' % os.path.join(a.out, tag + '.txt'),
                    '-DPERIOD=%g' % period, '-o', vvp]
            srcs = [os.path.join(base, 'tb.v'), dump]
            if kind == 'sdf':
                args += ['-gspecify', '-ginterconnect']
                srcs += models + [netlist]
            else:
                srcs.append(os.path.join(base, 'dut.v'))
            c = subprocess.run(args + srcs, capture_output=True, text=True)
            r = subprocess.run([os.path.join(a.suite, 'bin', 'vvp'), '-n', vvp],
                               capture_output=True, text=True)
            runs[kind] = {'compile_exit': c.returncode, 'vvp_exit': r.returncode,
                          'vcd': vcd, 'log': (r.stdout + r.stderr).splitlines()}
        cmp = gls_compare.compare(runs['rtl']['vcd'], runs['sdf']['vcd'],
                                  set(gls_compare.netlist_ports(netlist)))
        split = split_differences(runs['rtl']['vcd'], runs['sdf']['vcd'], netlist)
        rows.append({'period_ns': period,
                     'samples_with_real_difference': cmp['samples_with_real_difference'],
                     'real_bits': cmp['real_bits'], 'split': split,
                     'timing_messages': [l for l in runs['sdf']['log']
                                         if re.search(r'(?i)violation|setup|hold', l)]})
        print(json.dumps(rows[-1]))
        sys.stdout.flush()
    with open(os.path.join(a.out, 'mac_sweep.json'), 'w') as f:
        json.dump({'design': 'research MAC', 'sdf': 'mac_0p5ns.sdf', 'periods': rows}, f,
                  indent=1, sort_keys=True)
        f.write('\n')


def annotate(a):
    os.makedirs(a.out, exist_ok=True)
    res = resolved(a.run)
    design = res['DESIGN_NAME']
    sdf = os.path.join(a.run, 'final', 'sdf', a.corner, '%s__%s.sdf' % (design, a.corner))
    vvp = os.path.join(a.out, 'annotate.vvp')
    dump = os.path.join(a.out, 'annotate_dump.v')
    with open(dump, 'w') as f:
        f.write('module gls_portdump;\n  initial $sdf_annotate("%s", tb.uut);\nendmodule\n' % sdf)
    tb = os.path.join(FIXTURES, 'path_adder', 'tb_path_adder.v')
    args = [os.path.join(a.suite, 'bin', 'iverilog'), '-g2012', '-gspecify', '-ginterconnect',
            '-s', 'tb', '-s', 'gls_portdump', '-o', vvp, tb, dump] + models_of(res, a.pdk_root) + [
        os.path.join(a.run, 'final', 'nl', design + '.nl.v')]
    c = subprocess.run(args, capture_output=True, text=True)
    r = subprocess.run([os.path.join(a.suite, 'bin', 'vvp'), '-n', vvp], capture_output=True, text=True)
    doc = {'run': os.path.basename(os.path.dirname(os.path.abspath(a.run))), 'corner': a.corner,
           'compile_exit': c.returncode, 'vvp_exit': r.returncode,
           'annotation': account(sdf, (r.stdout + r.stderr).splitlines())}
    with open(os.path.join(a.out, 'annotate_%s.json' % a.corner), 'w') as f:
        json.dump(doc, f, indent=1, sort_keys=True)
        f.write('\n')
    print(json.dumps(doc['annotation']['messages']))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('sweep')
    s.add_argument('--suite', required=True)
    s.add_argument('--run', required=True)
    s.add_argument('--rtl')
    s.add_argument('--out', required=True)
    s.add_argument('--corner', default='nom_tt_025C_1v80')
    s.add_argument('--period', type=float, action='append')
    s.add_argument('--in-pct', type=float, default=20.0)
    s.add_argument('--at-edge', action='store_true')
    s.add_argument('--pdk-root', default=os.environ.get('PDK_ROOT', os.path.expanduser('~/.ciel')))
    c = sub.add_parser('account')
    c.add_argument('sdf')
    c.add_argument('log')
    n = sub.add_parser('annotate')
    n.add_argument('--suite', required=True)
    n.add_argument('--run', required=True)
    n.add_argument('--corner', required=True)
    n.add_argument('--out', required=True)
    n.add_argument('--pdk-root', default=os.environ.get('PDK_ROOT', os.path.expanduser('~/.ciel')))
    m = sub.add_parser('mac')
    m.add_argument('--suite', required=True)
    m.add_argument('--pdk', required=True,
                   help='the sky130_fd_sc_hd verilog directory')
    m.add_argument('--out', required=True)
    m.add_argument('--period', type=float, action='append')
    a = ap.parse_args()
    if a.cmd == 'sweep':
        sweep(a)
    elif a.cmd == 'mac':
        mac(a)
    elif a.cmd == 'annotate':
        annotate(a)
    else:
        with open(a.log, errors='replace') as f:
            print(json.dumps(account(a.sdf, f.read().splitlines()), indent=1, sort_keys=True))
    return 0


if __name__ == '__main__':
    sys.exit(main())
