#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Write a one-gate mutant of a structural netlist: one instance changes type.

Usage: netlist_mutant.py <in.v> <out.v> <instance> <old cell> <new cell>

The instance must appear exactly once as `<old cell> <instance> (`; anything
else is an error, so a mutant can never be a silent copy. The two cells must
share pin names (an and2 into an or2 of the same library, for example).
"""

import re
import sys


def main():
    if len(sys.argv) != 6:
        sys.stderr.write(__doc__)
        return 64
    src, dst, inst, old, new = sys.argv[1:6]
    text = open(src).read()
    pattern = re.compile(
        r'(^\s*)' + re.escape(old) + r'(\s+' + re.escape(inst) + r'\s*\()', re.M)
    hits = pattern.findall(text)
    if len(hits) != 1:
        sys.stderr.write(f'expected exactly one "{old} {inst} (", found {len(hits)}\n')
        return 1
    text = pattern.sub(lambda m: m.group(1) + new + m.group(2), text)
    with open(dst, 'w') as f:
        f.write(text)
    print(f'{inst}: {old} -> {new}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
