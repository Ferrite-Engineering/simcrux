#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Re-measure functional gate-level simulation and netlist equivalence on real
LibreLane runs, and write what the tools reported to one JSON file.

Usage:
  regen_gate_level.py --suite <oss-cad-suite dir> --out <dir>
      [--run path_adder=<LibreLane run dir>] [--run picorv32=<run dir>]
      [--run picorv32_cg=<run dir>] [--pdk-root <dir>] [--case <name>]...

--suite is an OSS CAD Suite install (its bin/ holds iverilog, vvp, verilator,
yosys and eqy). Each --run names a LibreLane run directory (the one holding
resolved.json and final/); path_adder defaults to the committed trimmed run
verification/fixtures/flow/librelane/3.0.16/sky130A_met/run. The mac case
needs no run: it is the Yosys-synthesised research netlist committed under
verification/fixtures/flow/gate_level/mac/.

Captures only. It never writes an expectation; the hand-written outcomes are
gate_level/gls.expected.json and formal/eqy_flow/recipe.expected.json, and
test/static/flow_gate_level_live_test.dart compares the two.

Cell models and the Liberty file come from the run's own resolved.json:
CELL_VERILOG_MODELS, and LIB at the entry whose pattern matches
DEFAULT_CORNER. Paths are used as recorded when they exist. A run copied from
another machine records that machine's PDK_ROOT; its paths are then rebased
onto <pdk-root>/ciel/<family>/versions/<the recorded version>, where
<pdk-root> is --pdk-root, else $PDK_ROOT, else ~/.ciel (ciel's layout). The
JSON says which happened.

Per case and simulator: the RTL run and the gate run of the same testbench,
each with an extra top (Icarus) or a bind (Verilator) that dumps the DUT's
ports, so the testbench is never edited; the testbench's own verdict ("TEST
PASSED", exit 0); and tool/flow/gate_level/gls_compare.py over the two VCDs.
For PicoRV32 also the power-aware netlist (final/pnl) under Icarus, with the
supply ports floating and tied from outside. Then EQY with the recipe in
verification/fixtures/formal/eqy_flow/flow_netlist.eqy.in on final/nl, its
physical-only cells being the run's FILL_CELLS, DECAP_CELLS, WELLTAP_CELL and
ENDCAP_CELL, and on sky130 on a one-gate mutant of it (the first and2 cell
turned into an or2), which is also simulated.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..', '..'))
FIX = os.path.join(REPO, 'verification', 'fixtures')
GL = os.path.join(FIX, 'flow', 'gate_level')
EQY_FLOW = os.path.join(FIX, 'formal', 'eqy_flow')
DESIGNS = os.path.join(FIX, 'flow', 'librelane', 'designs')
DEFAULT_SMALL_RUN = os.path.join(FIX, 'flow', 'librelane', '3.0.16', 'sky130A_met', 'run')

sys.path.insert(0, HERE)
import eqy_summary  # noqa: E402
import gls_compare  # noqa: E402

CASES = {
    'path_adder': {
        'top': 'path_adder',
        'rtl': os.path.join(DESIGNS, 'path_adder', 'path_adder.v'),
        'tb': os.path.join(GL, 'path_adder', 'tb_path_adder.v'),
        'dump': os.path.join(GL, 'path_adder', 'gls_portdump.v'),
        'pnl': False,
    },
    'picorv32': {
        'top': 'picorv32',
        'rtl': os.path.join(DESIGNS, 'picorv32', 'picorv32.v'),
        'tb': os.path.join(GL, 'picorv32', 'tb_picorv32.v'),
        'dump': os.path.join(GL, 'picorv32', 'gls_portdump.v'),
        'pnl': True,
    },
    'picorv32_cg': {
        'top': 'picorv32',
        'rtl': os.path.join(DESIGNS, 'picorv32', 'picorv32.v'),
        'tb': os.path.join(GL, 'picorv32', 'tb_picorv32.v'),
        'dump': os.path.join(GL, 'picorv32', 'gls_portdump.v'),
        'pnl': False,
    },
    'path_adder_gf180mcuD': {
        'top': 'path_adder',
        'rtl': os.path.join(DESIGNS, 'path_adder', 'path_adder.v'),
        'tb': os.path.join(GL, 'path_adder', 'tb_path_adder.v'),
        'dump': os.path.join(GL, 'path_adder', 'gls_portdump.v'),
        'pnl': False,
    },
    'path_adder_ihp-sg13g2': {
        'top': 'path_adder',
        'rtl': os.path.join(DESIGNS, 'path_adder', 'path_adder.v'),
        'tb': os.path.join(GL, 'path_adder', 'tb_path_adder.v'),
        'dump': os.path.join(GL, 'path_adder', 'gls_portdump.v'),
        'pnl': False,
    },
}

# Committed trimmed runs a case uses unless --run names another.
DEFAULT_RUNS = {
    'path_adder': DEFAULT_SMALL_RUN,
    'path_adder_gf180mcuD': os.path.join(
        FIX, 'flow', 'librelane', '3.0.16', 'gf180mcuD_met', 'run'),
    'path_adder_ihp-sg13g2': os.path.join(
        FIX, 'flow', 'librelane', '3.0.16', 'ihp-sg13g2_met', 'run'),
}

# Mutants only where the cell names are known (an and2 turned into an or2).
MUTANT_CELLS = {'sky130A': ('sky130_fd_sc_hd__and2_2', 'sky130_fd_sc_hd__or2_2')}

BIND = os.path.join(GL, 'harness', 'gls_bind.v')
POWER = os.path.join(GL, 'harness', 'gls_power.v')
TEMPLATE = os.path.join(EQY_FLOW, 'flow_netlist.eqy.in')
EQY_TIMEOUT_S = 600


def run(cmd, cwd=None, timeout=3600, big_stack=False):
    if big_stack:
        # eqy_partition recurses once per cell along a cone; the default 8 MB
        # stack overflows on PicoRV32. Raise the soft limit to the hard one
        # (65,520 KB on macOS) in a shell that then execs the tool; Python's
        # setrlimit in a forked child is refused on macOS.
        cmd = ['bash', '-c', 'ulimit -s "$(ulimit -Hs)" || true; exec "$@"', 'eqy'] + cmd
    started = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        rc, out = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        rc, out = 'timeout', (e.stdout or '') if isinstance(e.stdout, str) else ''
    return rc, out, round(time.time() - started, 1)


def family_of(pdk):
    for fam in ('sky130', 'gf180mcu', 'ihp-sg13g2'):
        if pdk.startswith(fam):
            return fam
    return pdk


def resolve_models(run_dir, pdk_root_arg):
    """Cell models and Liberty from the run's resolved.json."""
    rj = json.load(open(os.path.join(run_dir, 'resolved.json')))
    recorded_root = rj['PDK_ROOT']
    corner = rj['DEFAULT_CORNER']
    lib = None
    for pattern, files in rj['LIB'].items():
        rx = '^' + re.escape(pattern).replace(r'\*', '.*') + '$'
        if re.match(rx, corner):
            lib = files[0]
            break
    wanted = list(rj['CELL_VERILOG_MODELS']) + [lib]
    home = os.path.expanduser('~')
    recorded = recorded_root.replace('<home>', home).rstrip('/')
    local_root = pdk_root_arg or os.environ.get('PDK_ROOT') or os.path.join(home, '.ciel')
    version = os.path.basename(recorded)
    rebased_root = os.path.join(local_root, 'ciel', family_of(rj['PDK']), 'versions', version)
    how = 'as recorded'
    paths = []
    for p in wanted:
        q = p.replace('<home>', home)
        if not os.path.exists(q) and q.startswith(recorded):
            q = rebased_root + q[len(recorded):]
            how = 'rebased onto ' + rebased_root.replace(home, '<home>')
        paths.append(q)
    missing = [p for p in paths if not os.path.exists(p)]
    # Physical-only cells, as the run's own configuration names them.
    physical = list(rj.get('FILL_CELLS') or []) + list(rj.get('DECAP_CELLS') or [])
    for key in ('WELLTAP_CELL', 'ENDCAP_CELL'):
        if rj.get(key):
            physical.append(rj[key])
    return {
        'fields': {'PDK_ROOT': '<recorded>', 'PDK': rj['PDK'],
                   'STD_CELL_LIBRARY': rj['STD_CELL_LIBRARY'],
                   'DEFAULT_CORNER': corner},
        'physical': sorted(set(physical)),
        'models': paths[:-1],
        'liberty': paths[-1],
        'how': how,
        'missing': [m.replace(os.path.expanduser('~'), '<home>') for m in missing],
    }


def tb_passed(rc, out):
    return rc == 0 and 'TEST PASSED' in out


def icarus(suite, work, label, files, defines, tops, vcd):
    vvp = os.path.join(work, label + '.vvp')
    cmd = [os.path.join(suite, 'bin', 'iverilog'), '-g2012', '-o', vvp]
    for t in tops:
        cmd += ['-s', t]
    for d in defines + [f'GLS_VCD="{vcd}"']:
        cmd.append('-D' + d)
    rc, out, secs = run(cmd + files)
    if rc != 0:
        return {'compiled': False, 'compile_exit': rc, 'compile_log': out[-2000:]}
    rc, out, secs = run([os.path.join(suite, 'bin', 'vvp'), '-n', vvp])
    return {'compiled': True, 'exit': rc, 'passed': tb_passed(rc, out),
            'seconds': secs, 'tail': out[-600:]}


def verilator(suite, work, label, files, defines, vcd):
    mdir = os.path.join(work, 'obj_' + label)
    cmd = [os.path.join(suite, 'bin', 'verilator'), '--binary', '--timing', '--trace',
           '-j', '0', '--quiet', '-Wno-fatal', '-Wno-lint', '-Wno-style',
           '-Wno-BLKANDNBLK', '-Wno-MULTIDRIVEN', '-Wno-SPECIFYIGN',
           '--top-module', 'tb', '--Mdir', mdir, '-o', 'sim']
    for d in defines + [f'GLS_VCD="{vcd}"']:
        cmd.append('-D' + d)
    rc, out, secs = run(cmd + files + [BIND])
    if rc != 0:
        return {'compiled': False, 'compile_exit': rc, 'compile_log': out[-2000:]}
    rc, out, secs2 = run([os.path.join(mdir, 'sim')])
    return {'compiled': True, 'exit': rc, 'passed': tb_passed(rc, out),
            'seconds': secs2, 'build_seconds': secs, 'tail': out[-600:]}


def gls_case(suite, work, case, spec, netlist, pnl, models):
    os.makedirs(work, exist_ok=True)
    ports = set(gls_compare.netlist_ports(netlist))
    result = {}
    rtl_files = [spec['tb'], spec['dump'], spec['rtl']]
    gate_files = [spec['tb'], spec['dump']] + models + [netlist]
    gate_defs = ['FUNCTIONAL', 'UNIT_DELAY=#1']
    for sim in ('icarus', 'verilator'):
        vr = os.path.join(work, f'{sim}_rtl.vcd')
        vg = os.path.join(work, f'{sim}_gate.vcd')
        if sim == 'icarus':
            r = icarus(suite, work, 'rtl', rtl_files, [], ['tb', 'gls_portdump'], vr)
            g = icarus(suite, work, 'gate', gate_files, gate_defs, ['tb', 'gls_portdump'], vg)
        else:
            r = verilator(suite, work, 'rtl', rtl_files, [], vr)
            g = verilator(suite, work, 'gate', gate_files, gate_defs, vg)
        entry = {'rtl': r, 'gate': g}
        if r.get('compiled') and g.get('compiled') and os.path.exists(vr) and os.path.exists(vg):
            entry['compare'] = gls_compare.compare(vr, vg, ports)
        result[sim] = entry
    if spec['pnl'] and pnl:
        defs = gate_defs + ['USE_POWER_PINS']
        files = [spec['tb'], spec['dump']] + models + [pnl]
        floating = icarus(suite, work, 'pnl_floating', files, defs, ['tb', 'gls_portdump'],
                          os.path.join(work, 'pnl_floating.vcd'))
        vt = os.path.join(work, 'pnl_tied.vcd')
        tied = icarus(suite, work, 'pnl_tied', files + [POWER], defs,
                      ['tb', 'gls_portdump', 'gls_power'], vt)
        nopp = icarus(suite, work, 'pnl_no_define', files, gate_defs, ['tb', 'gls_portdump'],
                      os.path.join(work, 'pnl_no_define.vcd'))
        entry = {'without_USE_POWER_PINS': {'compiled': nopp.get('compiled')},
                 'floating': floating, 'tied': tied}
        vr = os.path.join(work, 'icarus_rtl.vcd')
        if tied.get('compiled') and os.path.exists(vr):
            entry['tied']['compare'] = gls_compare.compare(vr, vt, ports)
        result['icarus_pnl'] = entry
    return result


def delete_list(physical):
    return ' '.join('t:' + p for p in physical)


def blackboxes(suite, work, top, liberty, netlist, physical):
    """Cell types the Liberty read leaves without a model, with instance counts.

    Every Liberty cell is first read as a blackbox, then the ones with a
    function overwrite it; after the physical-only cells are deleted and the
    unused library purged, the blackboxes left are the instantiated cells
    without a function.
    """
    ys = os.path.join(work, 'blackboxes.ys')
    stat = os.path.join(work, 'blackboxes.stat.json')
    listed = os.path.join(work, 'blackboxes.txt')
    with open(ys, 'w') as f:
        f.write(f'read_liberty -lib {liberty}\n')
        f.write(f'read_liberty -overwrite -ignore_miss_func {liberty}\n')
        f.write(f'read_verilog {netlist}\n')
        f.write(f'hierarchy -top {top}\n')
        f.write(f'delete {delete_list(physical)}\n')
        f.write(f'hierarchy -check -top {top} -purge_lib\n')
        f.write(f'tee -q -o {listed} select -list =A:blackbox\n')
        f.write(f'tee -q -o {stat} stat -json\n')
    rc, out, _ = run([os.path.join(suite, 'bin', 'yosys'), '-q', '-s', ys])
    if rc != 0:
        return {'error': out[-1000:]}
    names = [l.strip() for l in open(listed) if l.strip() and '/' not in l]
    doc = json.load(open(stat))
    cells = doc['modules'].get('\\' + top, doc['modules'].get(top, {})).get('num_cells_by_type', {})
    return {n: cells.get(n, cells.get('\\' + n, 0)) for n in names}


def eqy(suite, work, top, rtl, liberty, netlist, physical):
    eqy_file = work + '.eqy'
    text = open(TEMPLATE).read().format(rtl=rtl, top=top, liberty=liberty,
                                        netlist=netlist, physical=delete_list(physical),
                                        timeout=EQY_TIMEOUT_S)
    with open(eqy_file, 'w') as f:
        f.write(text)
    if os.path.exists(work):
        shutil.rmtree(work)
    rc, out, secs = run([os.path.join(suite, 'bin', 'eqy'), '-d', work, eqy_file],
                        timeout=3 * 3600, big_stack=True)
    summary = eqy_summary.summarise(work)
    summary['exit'] = rc
    summary['wall_seconds'] = secs
    summary['internal_errors'] = sorted(set(
        re.findall(r'(Segmentation fault[^\n]*|This should not happen[^\n]*|ERROR: [^\n]*)', out)))
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--suite', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--run', action='append', default=[])
    ap.add_argument('--pdk-root')
    ap.add_argument('--case', action='append', default=[])
    a = ap.parse_args()
    runs = dict(DEFAULT_RUNS)
    for item in a.run:
        name, _, path = item.partition('=')
        runs[name] = os.path.abspath(path)
    wanted = a.case or ['mac'] + [c for c in CASES if c in runs]
    unknown = [c for c in wanted if c != 'mac' and c not in runs]
    if unknown:
        sys.stderr.write(f'no run for: {", ".join(unknown)}\n')
        return 64
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    results = {'suite': {}, 'cases': {}}
    for tool in ('yosys', 'eqy', 'verilator'):
        rc, txt, _ = run([os.path.join(a.suite, 'bin', tool), '--version' if tool != 'yosys' else '-V'])
        results['suite'][tool] = txt.strip().splitlines()[0] if txt.strip() else ''

    for case in wanted:
        work = os.path.join(out, case)
        if case == 'mac':
            sky = resolve_models(runs['path_adder'], a.pdk_root)
            spec = {'top': 'dut', 'rtl': os.path.join(GL, 'mac', 'dut.v'),
                    'tb': os.path.join(GL, 'mac', 'tb.v'),
                    'dump': os.path.join(GL, 'mac', 'gls_portdump.v'), 'pnl': False}
            os.makedirs(work, exist_ok=True)
            res = {'models': sky}
            for label, extra in (('plain', []), ('xprobe', ['XPROBE'])):
                sub = os.path.join(work, label)
                os.makedirs(sub, exist_ok=True)
                defs = [f'OUT="{os.path.join(sub, "out.txt")}"'] + extra
                vr, vg = os.path.join(sub, 'rtl.vcd'), os.path.join(sub, 'gate.vcd')
                r = icarus(a.suite, sub, 'rtl', [spec['tb'], spec['dump'], spec['rtl']], defs,
                           ['tb', 'gls_portdump'], vr)
                g = icarus(a.suite, sub, 'gate', [spec['tb'], spec['dump']] + sky['models'] +
                           [os.path.join(GL, 'mac', 'net.v')],
                           defs + ['FUNCTIONAL', 'UNIT_DELAY=#1'], ['tb', 'gls_portdump'], vg)
                entry = {'rtl': r, 'gate': g}
                if r.get('compiled') and g.get('compiled'):
                    entry['compare'] = gls_compare.compare(
                        vr, vg, set(gls_compare.netlist_ports(os.path.join(GL, 'mac', 'net.v'))))
                res[label] = entry
            split = icarus(a.suite, work, 'split_ports',
                           [spec['tb']] + sky['models'] + [os.path.join(GL, 'mac', 'net_splitports.v')],
                           [f'OUT="{os.path.join(work, "split.txt")}"', 'FUNCTIONAL', 'UNIT_DELAY=#1'],
                           ['tb'], os.path.join(work, 'split.vcd'))
            res['split_ports'] = {'compiled': split.get('compiled'),
                                  'compile_exit': split.get('compile_exit')}
            results['cases'][case] = res
            continue
        spec = CASES[case]
        run_dir = runs[case]
        top = spec['top']
        netlist = os.path.join(run_dir, 'final', 'nl', f'{top}.nl.v')
        pnl = os.path.join(run_dir, 'final', 'pnl', f'{top}.pnl.v')
        models = resolve_models(run_dir, a.pdk_root)
        res = {'models': models}
        res['gls'] = gls_case(a.suite, os.path.join(work, 'gls'), case, spec, netlist,
                              pnl if os.path.exists(pnl) else None, models['models'])
        physical = models['physical']
        res['blackboxes'] = blackboxes(a.suite, os.path.join(work, 'gls'), top,
                                       models['liberty'], netlist, physical)
        res['eqy'] = eqy(a.suite, os.path.join(work, 'eqy_nl'), top, spec['rtl'],
                         models['liberty'], netlist, physical)
        cells = MUTANT_CELLS.get(models['fields']['PDK'])
        if case != 'picorv32_cg' and cells:
            mutant = os.path.join(work, 'mutant.nl.v')
            text = open(netlist).read()
            m = re.search(r'^\s*' + re.escape(cells[0]) + r'\s+(\S+)\s*\(', text, re.M)
            rc, msg, _ = run([sys.executable, '-I', os.path.join(HERE, 'netlist_mutant.py'),
                              netlist, mutant, m.group(1), cells[0], cells[1]])
            res['mutation'] = msg.strip()
            res['eqy_mutant'] = eqy(a.suite, os.path.join(work, 'eqy_mutant'), top, spec['rtl'],
                                    models['liberty'], mutant, physical)
            res['gls_mutant'] = gls_case(
                a.suite, os.path.join(work, 'gls_mutant'), case,
                dict(spec, pnl=False), mutant, None, models['models'])
        results['cases'][case] = res

    text = json.dumps(results, indent=2, sort_keys=True)
    text = text.replace(os.path.expanduser('~'), '<home>').replace(out, '<out>').replace(REPO, '<repo>')
    with open(os.path.join(out, 'gate_level.json'), 'w') as f:
        f.write(text + '\n')
    print(os.path.join(out, 'gate_level.json'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
