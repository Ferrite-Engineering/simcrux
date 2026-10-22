#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Summarise an EQY work directory from EQY's and SymbiYosys's own records.

Usage: eqy_summary.py <eqy work dir> [--json <out file>]

A measurement tool, independent of SimCrux's EQY reader. Per partition: the
first word of strategies/<partition>/sby/status (PASS, FAIL, UNKNOWN,
TIMEOUT, ERROR; MISSING when sby never ran) and the last "Elapsed clock time"
of its sby log, in whole seconds as sby prints it. Overall: the last
"DONE (<word>, rc=<n>)" line of EQY's own logfile.txt.
"""

import argparse
import json
import os
import re
import sys

_ELAPSED = re.compile(r'summary: Elapsed clock time \[H:MM:SS \(secs\)\]: \S+ \((\d+)\)')
_DONE = re.compile(r'DONE \((\w+), rc=(\d+)\)')


def summarise(work):
    rows = []
    strategies = os.path.join(work, 'strategies')
    if os.path.isdir(strategies):
        for part in sorted(os.listdir(strategies)):
            sby = os.path.join(strategies, part, 'sby')
            status_path = os.path.join(sby, 'status')
            status = 'MISSING'
            if os.path.exists(status_path):
                words = open(status_path).read().split()
                status = words[0] if words else 'MISSING'
            seconds = None
            log = os.path.join(sby, part, 'logfile.txt')
            if os.path.exists(log):
                found = _ELAPSED.findall(open(log).read())
                if found:
                    seconds = int(found[-1])
            rows.append({'partition': part, 'status': status, 'seconds': seconds})
    overall = rc = total = None
    logfile = os.path.join(work, 'logfile.txt')
    if os.path.exists(logfile):
        text = open(logfile).read()
        done = _DONE.findall(text)
        if done:
            overall, rc = done[-1][0], int(done[-1][1])
        elapsed = _ELAPSED.findall(text)
        if elapsed:
            total = int(elapsed[-1])
    counts = {}
    for row in rows:
        counts[row['status']] = counts.get(row['status'], 0) + 1
    timed = [r['seconds'] for r in rows if r['seconds'] is not None]
    return {
        'overall': overall,
        'rc': rc,
        'total_seconds': total,
        'partitions': len(rows),
        'status_counts': counts,
        'max_partition_seconds': max(timed) if timed else None,
        'not_passed': [r for r in rows if r['status'] != 'PASS'],
        'rows': rows,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('work')
    ap.add_argument('--json')
    a = ap.parse_args()
    doc = summarise(a.work)
    text = json.dumps(doc, indent=2, sort_keys=True)
    if a.json:
        with open(a.json, 'w') as f:
            f.write(text + '\n')
    print(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
