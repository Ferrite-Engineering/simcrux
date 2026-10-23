#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Write a uniform-delay SDF for a Yosys sky130 netlist (a synthetic fixture).

Usage: gen_sdf.py <net.v> <out.sdf> <delay ns> [<interconnect ns>]

Every combinational cell's IOPATH is <delay>, every flip-flop's CLK to Q is
<delay> (and RESET_B to Q where it has one), each flip-flop carries a
SETUPHOLD that Icarus ignores, and with <interconnect ns> one INTERCONNECT is
added. Not a timing analysis: it gives every path the same delay, so the clock
period where behaviour first differs is a property of logic depth alone. This
is how `verification/fixtures/flow/gate_level/sdf/mac_0p5ns.sdf` was written
(`gen_sdf.py mac/net.v sdf/mac_0p5ns.sdf 0.5 0.7`).
"""

import re
import sys


def main():
    src = open(sys.argv[1]).read()
    delay = float(sys.argv[3])
    ic = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    outputs = {'X', 'Y', 'Q', 'Q_N', 'HI', 'LO'}
    cells = re.findall(r'^\s*(sky130_fd_sc_hd__\w+)\s+(\\?\S+)\s*\((.*?)\);', src, re.M | re.S)
    o = ['(DELAYFILE', ' (SDFVERSION "3.0")', ' (DESIGN "dut")', ' (TIMESCALE 1ns)']
    first_comb = None
    d = delay
    for typ, inst, body in cells:
        pins = re.findall(r'\.(\w+)\(([^)]*)\)', body)
        ins = [p for p, _ in pins if p not in outputs]
        outs = [p for p, _ in pins if p in outputs]
        inst = inst.lstrip('\\')
        o.append(f' (CELL (CELLTYPE "{typ}") (INSTANCE {inst})')
        if 'df' in typ:
            o.append('  (DELAY (ABSOLUTE')
            o.append(f'   (IOPATH (posedge CLK) Q ({d}:{d}:{d}) ({d}:{d}:{d}))')
            if 'RESET_B' in ins:
                o.append(f'   (IOPATH (negedge RESET_B) Q ({d}:{d}:{d}) ({d}:{d}:{d}))')
            o.append('  ))')
            o.append('  (TIMINGCHECK')
            o.append('   (SETUPHOLD (posedge D) (posedge CLK) (0.3:0.3:0.3) (0.05:0.05:0.05))')
            o.append('   (SETUPHOLD (negedge D) (posedge CLK) (0.3:0.3:0.3) (0.05:0.05:0.05))')
            o.append('  )')
        elif outs and ins:
            if first_comb is None:
                first_comb = (inst, ins[0])
            o.append('  (DELAY (ABSOLUTE')
            for i in ins:
                for q in outs:
                    o.append(f'   (IOPATH {i} {q} ({d}:{d}:{d}) ({d}:{d}:{d}))')
            o.append('  ))')
        else:
            o.append('  (DELAY (ABSOLUTE ))')
        o.append(' )')
    if ic and first_comb:
        o.append(' (CELL (CELLTYPE "dut") (INSTANCE)')
        o.append(f'  (DELAY (ABSOLUTE (INTERCONNECT a[0] _785_.D ({ic}:{ic}:{ic}))))')
        o.append(' )')
    o.append(')')
    with open(sys.argv[2], 'w') as f:
        f.write('\n'.join(o) + '\n')
    print(f'{len(cells)} cells written')
    return 0


if __name__ == '__main__':
    sys.exit(main())
