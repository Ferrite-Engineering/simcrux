#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Compare a design's top-level ports between an RTL run and a gate-level run.

Usage:
  gls_compare.py <rtl.vcd> <gate.vcd> --ports-from <netlist.v>
      [--clock clk] [--scope tb.uut] [--json <out file>]

A measurement tool, independent of SimCrux's own comparator. Each VCD is read
as a stream. Only variables in the DUT instance's scope whose names are ports
of the netlist (its `input`/`output`/`inout` declarations) are kept, so a
simulator that dumps every internal net (Verilator) and one that dumps only the
listed ports (Icarus) are read the same way.

Every kept variable is sampled immediately before each rising edge of the
clock: the value it held before that timestamp's changes, never the value at
the edge, where the RTL has updated and unit-delay gates have not. Sample k of
one file is compared with sample k of the other, and each differing bit is
classified:

  x_asymmetry  the RTL bit is x or z and the gate bit is 0 or 1
  real         both are known and unequal, or the gate bit is x or z where the
               RTL bit is known

Bits unknown on both sides are not counted. The two files must come from the
same simulator; comparing across simulators is meaningless and is not checked
here.
"""

import argparse
import json
import re
import sys


def netlist_ports(path):
    """Port names from a structural netlist's direction declarations."""
    text = open(path).read()
    names = []
    pattern = re.compile(
        r'^\s*(input|output|inout)\s+(?:wire\s+|reg\s+)?(\[[^\]]+\]\s*)?([^;]+);',
        re.M,
    )
    for m in pattern.finditer(text):
        for name in m.group(3).split(','):
            names.append(name.strip())
    return names


def read_samples(path, clock, scope, ports):
    """Return (port names, [(time, {name: bits})]) for one VCD."""
    ids = {}
    order = []
    state = {}
    pending = {}
    samples = []
    clock_code = None
    stack = []
    in_header = True
    time = 0

    def flush(t):
        if clock_code is not None and clock_code in pending:
            if state.get(clock_code, 'x') == '0' and pending[clock_code] == '1':
                samples.append(
                    (t, {ids[c][0]: state.get(c, 'x' * ids[c][1]) for c in order}))
        state.update(pending)
        pending.clear()

    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue
            if in_header:
                if line.startswith('$scope'):
                    stack.append(line.split()[2])
                elif line.startswith('$upscope'):
                    stack.pop()
                elif line.startswith('$var'):
                    parts = line.split()
                    width, code, name = int(parts[2]), parts[3], parts[4]
                    if '.'.join(stack) != scope or name not in ports:
                        continue
                    if code not in ids:
                        ids[code] = (name, width)
                        order.append(code)
                    if name == clock:
                        clock_code = code
                elif line.startswith('$enddefinitions'):
                    in_header = False
                continue
            head = line[0]
            if head == '#':
                flush(time)
                time = int(line[1:])
            elif head in 'bB':
                value, code = line[1:].split()
                if code not in ids:
                    continue
                width = ids[code][1]
                value = value.lower()
                if len(value) < width:
                    pad = value[0] if value[0] in 'xz' else '0'
                    value = pad * (width - len(value)) + value
                pending[code] = value
            elif head in '01xzXZ':
                if line[1:] in ids:
                    pending[line[1:]] = head.lower()
        flush(time)
    return [ids[c][0] for c in order], samples


def compare(rtl_path, gate_path, ports, clock='clk', scope='tb.uut'):
    rtl_names, rtl = read_samples(rtl_path, clock, scope, ports)
    gate_names, gate = read_samples(gate_path, clock, scope, ports)
    n = min(len(rtl), len(gate))
    x_bits = real_bits = x_samples = real_samples = time_mismatch = 0
    per_port = {}
    first = []
    for k in range(n):
        t_rtl, v_rtl = rtl[k]
        t_gate, v_gate = gate[k]
        if t_rtl != t_gate:
            time_mismatch += 1
        has_x = has_real = False
        for name in rtl_names:
            if name not in v_gate:
                continue
            r, g = v_rtl[name], v_gate[name]
            if r == g:
                continue
            for br, bg in zip(r, g):
                if br == bg:
                    continue
                r_known, g_known = br in '01', bg in '01'
                if not r_known and not g_known:
                    continue
                counts = per_port.setdefault(name, {'x_asymmetry': 0, 'real': 0})
                if not r_known:
                    x_bits += 1
                    has_x = True
                    counts['x_asymmetry'] += 1
                else:
                    real_bits += 1
                    has_real = True
                    counts['real'] += 1
            if len(first) < 10:
                first.append({'sample': k, 'time': t_rtl, 'port': name,
                              'rtl': r, 'gate': g})
        x_samples += has_x
        real_samples += has_real
    return {
        'ports_rtl': sorted(rtl_names),
        'ports_gate': sorted(gate_names),
        'ports_not_dumped_rtl': sorted(set(ports) - set(rtl_names)),
        'ports_not_dumped_gate': sorted(set(ports) - set(gate_names)),
        'samples_rtl': len(rtl),
        'samples_gate': len(gate),
        'samples_compared': n,
        'sample_time_mismatches': time_mismatch,
        'x_asymmetry_bits': x_bits,
        'real_bits': real_bits,
        'samples_with_x_asymmetry': x_samples,
        'samples_with_real_difference': real_samples,
        'per_port': per_port,
        'first_differences': first,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('rtl')
    ap.add_argument('gate')
    ap.add_argument('--ports-from', required=True)
    ap.add_argument('--clock', default='clk')
    ap.add_argument('--scope', default='tb.uut')
    ap.add_argument('--json')
    a = ap.parse_args()
    result = compare(a.rtl, a.gate, set(netlist_ports(a.ports_from)), a.clock, a.scope)
    text = json.dumps(result, indent=2, sort_keys=True)
    if a.json:
        with open(a.json, 'w') as f:
            f.write(text + '\n')
    print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
