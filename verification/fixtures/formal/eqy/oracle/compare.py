#!/usr/bin/env python3
"""Compare two exhaustive simulation dumps; report how many vectors differ in y and in z."""
import sys


def load(path):
    rows = {}
    for line in open(path):
        parts = line.split()
        if len(parts) == 3:
            rows[parts[0]] = (parts[1], parts[2])
    return rows


gold = load(sys.argv[1])
gate = load(sys.argv[2])
assert gold.keys() == gate.keys(), "vector sets differ"
dy = sum(1 for k in gold if gold[k][0] != gate[k][0])
dz = sum(1 for k in gold if gold[k][1] != gate[k][1])
ops = sorted({int(k, 16) >> 16 for k in gold if gold[k] != gate[k]})
print(f"vectors={len(gold)} y_differs={dy} z_differs={dz} ops_with_difference={ops}")
