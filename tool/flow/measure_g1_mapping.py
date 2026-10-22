#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Measure how many of a LibreLane run's worst setup endpoints map to a user
RTL register through the synthesis step's netlist JSON sidecar.

Usage:
  measure_g1_mapping.py <run dir> --rtl <file.v> --top <module>
      [--corner <name>] [--count N] [--yosys <path>] [--json <out file>]

The measurement reads only LibreLane's own records and an independent Yosys
elaboration of the RTL. It shares no code with the product's readers.

1. Worst endpoints: the post-PnR STA step's <corner>/max.rpt, written by
   OpenSTA's report_checks -sort_by_slack -group_path_count 1000, lists one
   path per endpoint. The first N distinct endpoints in slack order are the
   worst N (default 100, corner nom_tt_025C_1v80).
2. The join: the synthesis step writes <D>.nl.v (write_verilog -noattr) and
   <D>.nl.v.json (write_json) from the same design. write_verilog renames
   every '$'-named wire, then cell, in sorted order to _NNN_; rebuilding that
   map turns an instance name in the report into the sidecar's cell. The map
   is checked against the instance names <D>.nl.v actually contains.
3. The register: the public sidecar nets on the flip-flop's Q pins name the
   register. The endpoint maps when that name is a register of the RTL, which
   is every flip-flop output and memory of `yosys read_verilog; hierarchy;
   proc; flatten; memory -nomap` on the RTL alone.

An endpoint that is an output port, a cell the sidecar does not hold (created
in place and route), or a flip-flop whose Q nets name no RTL register does not
map. The share is mapped endpoints over the endpoints counted.
"""

import glob
import json
import os
import re
import subprocess
import sys
import tempfile

FF_TYPES = {
    "$dff", "$dffe", "$adff", "$adffe", "$sdff", "$sdffe", "$sdffce",
    "$dffsr", "$dffsre", "$aldff", "$aldffe",
}
MEM_TYPES = {"$mem", "$mem_v2"}
Q_PINS = {"Q", "Q_N", "QN"}
CLOCK_PINS = {"CLK", "CK", "CLK_N", "CLKN"}


def die(message, code=1):
    sys.stderr.write(message + "\n")
    sys.exit(code)


def only(pattern):
    hits = sorted(glob.glob(pattern))
    if len(hits) != 1:
        die(f"expected one match for {pattern}, found {len(hits)}")
    return hits[0]


def rtl_registers(rtl, top, yosys):
    """Register names of the RTL alone, from an independent Yosys run."""
    with tempfile.TemporaryDirectory() as work:
        out = os.path.join(work, "rtl.json")
        script = (f"read_verilog {rtl}; hierarchy -top {top}; proc; flatten; "
                  f"memory -nomap; opt_clean; write_json {out}")
        subprocess.run([yosys, "-q", "-p", script], check=True)
        design = json.load(open(out))
    module = design["modules"][top]
    bit_names = {}
    for name, net in module["netnames"].items():
        if net.get("hide_name"):
            continue
        base = re.sub(r"\[\d+\]$", "", name)
        for bit in net["bits"]:
            bit_names.setdefault(bit, set()).add(base)
    registers = set()
    widths = 0
    for cell in module["cells"].values():
        if cell["type"] in FF_TYPES:
            bits = cell["connections"]["Q"]
            widths += len(bits)
            for bit in bits:
                registers |= bit_names.get(bit, set())
        elif cell["type"] in MEM_TYPES:
            memid = cell["parameters"]["MEMID"]
            registers.add(memid.lstrip("\\"))
            widths += int(cell["parameters"]["WIDTH"], 2) * int(
                cell["parameters"]["SIZE"], 2)
    return registers, widths


def module_map(module):
    """write_verilog's auto-names: '$' wires, then '$' cells, sorted, to _NNN_."""
    wires = sorted(module["netnames"])
    cells = sorted(module["cells"])
    offset = 0
    for name in wires + cells:
        match = re.fullmatch(r"_(\d+)_?", name)
        if match:
            offset = max(offset, int(match.group(1)) + 1)
    ids = [n for n in wires if n.startswith("$")] + [
        n for n in cells if n.startswith("$")]
    total = offset + len(ids)
    digits, bound = 1, 10
    while bound < total:
        digits, bound = digits + 1, bound * 10
    return {"_%0*d_" % (digits, offset + k): name for k, name in enumerate(ids)}


def parse_max_report(path):
    """Paths of a report_checks text listing: rank, start, end, kind, slack."""
    text = open(path).read()
    paths = []
    for block in re.split(r"\n(?=Startpoint: )", text)[1:]:
        start = re.search(r"^Startpoint: (\S+) \((.*)\)$", block, re.M)
        end = re.search(r"^Endpoint: (\S+) \((.*)\)$", block, re.M)
        slack = re.search(r"^\s+(-?\d+\.\d+)\s+slack \((MET|VIOLATED)\)",
                          block, re.M)
        if not (start and end and slack):
            die(f"unparsed path block in {path}:\n{block[:400]}")
        paths.append({
            "rank": len(paths) + 1,
            "start": start.group(1),
            "end": end.group(1),
            "end_kind": end.group(2),
            "slack": float(slack.group(1)),
        })
    return paths


def main(argv):
    args = list(argv)
    run = None
    rtl = top = None
    corner = "nom_tt_025C_1v80"
    count = 100
    yosys = "yosys"
    out_json = None
    while args:
        arg = args.pop(0)
        if arg == "--rtl":
            rtl = args.pop(0)
        elif arg == "--top":
            top = args.pop(0)
        elif arg == "--corner":
            corner = args.pop(0)
        elif arg == "--count":
            count = int(args.pop(0))
        elif arg == "--yosys":
            yosys = args.pop(0)
        elif arg == "--json":
            out_json = args.pop(0)
        elif arg.startswith("-"):
            die(f"unknown option: {arg}", 64)
        else:
            run = arg
    if not (run and rtl and top):
        die(__doc__, 64)

    synth = only(os.path.join(run, "*-yosys-synthesis"))
    sidecar = json.load(open(only(os.path.join(synth, "*.nl.v.json"))))
    netlist_text = open(only(os.path.join(synth, "*.nl.v"))).read()
    sta = only(os.path.join(run, "*-openroad-stapostpnr"))
    report = os.path.join(sta, corner, "max.rpt")
    if not os.path.exists(report):
        die(f"missing {report}")

    modules = sidecar["modules"]
    top_name = [k for k, v in modules.items()
                if v.get("attributes", {}).get("top")]
    if top_name != [top]:
        die(f"sidecar top is {top_name}, expected {top}")
    module = modules[top]
    names = module_map(module)

    # Validate the rebuilt map against the netlist write_verilog produced.
    instances = set(re.findall(r"^\s*\S+\s+(\\?\S+)\s*\(", netlist_text, re.M))
    rebuilt_cells = {v: k for k, v in names.items() if v in module["cells"]}
    present = sum(1 for k in rebuilt_cells.values() if k in instances)

    # After splitnets a vector is one net per bit ("sum_q[24]"); before it,
    # one net with a bit list. Either way the register is the base name.
    bit_names = {}
    net_src = {}
    for name, net in module["netnames"].items():
        if net.get("hide_name") or name.startswith("$"):
            continue
        net_src[name] = net.get("attributes", {}).get("src")
        for index, bit in enumerate(net["bits"]):
            label = name if len(net["bits"]) == 1 else f"{name}[{index}]"
            bit_names.setdefault(bit, []).append(label)

    def register_of(label):
        """The RTL register a net label names: the label itself, or the label
        with trailing [N] selects removed one at a time (a vector bit, then a
        memory word). Returns (register, how) or None."""
        candidate = label
        stripped = 0
        while True:
            if candidate in registers:
                how = ("name" if stripped == 0 else
                       "vector bit" if stripped == 1 else "memory word bit")
                return candidate, how
            shorter = re.sub(r"\[\d+\]$", "", candidate)
            if shorter == candidate:
                return None
            candidate, stripped = shorter, stripped + 1

    registers, rtl_bits = rtl_registers(rtl, top, yosys)
    paths = parse_max_report(report)
    slacks = [p["slack"] for p in paths]
    sorted_by_slack = all(a <= b for a, b in zip(slacks, slacks[1:]))
    seen = set()
    worst = []
    for p in sorted(paths, key=lambda p: (p["slack"], p["rank"])):
        if p["end"] in seen:
            continue
        seen.add(p["end"])
        worst.append(p)
        if len(worst) == count:
            break

    rows = []
    for p in worst:
        row = {"rank": p["rank"], "endpoint": p["end"], "slack": p["slack"]}
        if "port" in p["end_kind"]:
            row["outcome"] = "port"
        else:
            cell_name = names.get(p["end"], p["end"])
            cell = module["cells"].get(cell_name) or module["cells"].get(
                cell_name.replace("\\", ""))
            if cell is None:
                row["outcome"] = "not_in_sidecar"
            else:
                row["cell_type"] = cell["type"]
                src = cell.get("attributes", {}).get("src")
                # Spans name the machine that ran synthesis; keep file names.
                row["src"] = None if src is None else "|".join(
                    os.path.basename(s) for s in src.split("|"))
                q_nets = sorted({
                    n for pin, bits in cell["connections"].items()
                    if pin in Q_PINS
                    for bit in bits for n in bit_names.get(bit, [])})
                row["q_nets"] = q_nets
                row["q_net_src"] = sorted({
                    "|".join(os.path.basename(s) for s in src.split("|"))
                    for n in q_nets
                    for src in [net_src.get(re.sub(r"\[\d+\]$", "", n))
                                or net_src.get(n)]
                    if src})
                hits = sorted(h for h in map(register_of, q_nets) if h)
                if hits:
                    row["outcome"] = "register"
                    row["register"], row["matched_by"] = hits[0]
                else:
                    row["outcome"] = "unmapped_register"
        rows.append(row)

    # Census: every flip-flop instance in the final netlist, whatever its slack.
    # A cell type is sequential when its sidecar cells have a clock pin; drive
    # strength suffixes are ignored because the resizer swaps them.
    def base_type(cell_type):
        return re.sub(r"_\d+$", "", cell_type)

    seq_types = {base_type(c["type"]) for c in module["cells"].values()
                 if CLOCK_PINS & set(c["connections"])}
    final_nl = only(os.path.join(run, "final", "nl", "*.nl.v"))
    census = {"flip_flops": 0, "in_sidecar": 0, "mapped": 0,
              "with_rtl_src_span": 0}
    census_registers = set()
    unmapped_examples = []
    for cell_type, inst in re.findall(r"^\s*(\S+)\s+(\\?\S+)\s*\(",
                                      open(final_nl).read(), re.M):
        if base_type(cell_type) not in seq_types:
            continue
        census["flip_flops"] += 1
        cell = module["cells"].get(names.get(inst, inst))
        if cell is None:
            if len(unmapped_examples) < 10:
                unmapped_examples.append(inst)
            continue
        census["in_sidecar"] += 1
        labels = {n for pin, bits in cell["connections"].items()
                  if pin in Q_PINS for bit in bits
                  for n in bit_names.get(bit, [])}
        hits = sorted(h for h in map(register_of, labels) if h)
        src = cell.get("attributes", {}).get("src") or ""
        if os.path.basename(rtl) + ":" in src:
            census["with_rtl_src_span"] += 1
        if hits:
            census["mapped"] += 1
            census_registers.add(hits[0][0])
        elif len(unmapped_examples) < 10:
            unmapped_examples.append(f"{inst} {sorted(labels)}")
    census["distinct_registers"] = len(census_registers)
    census["unmapped_examples"] = unmapped_examples

    mapped = sum(1 for r in rows if r["outcome"] == "register")
    outcomes = {}
    matched_by = {}
    for r in rows:
        outcomes[r["outcome"]] = outcomes.get(r["outcome"], 0) + 1
        if "matched_by" in r:
            matched_by[r["matched_by"]] = matched_by.get(r["matched_by"], 0) + 1
    metrics = json.load(open(os.path.join(run, "final", "metrics.json")))
    result = {
        "report": os.path.relpath(report, run),
        "corner": corner,
        "paths_in_report": len(paths),
        "report_sorted_by_slack": sorted_by_slack,
        "endpoints_counted": len(rows),
        "mapped_to_rtl_register": mapped,
        "share": round(mapped / len(rows), 4) if rows else None,
        "outcomes": outcomes,
        "matched_by": matched_by,
        "endpoints_with_rtl_src_span": sum(
            1 for r in rows
            if os.path.basename(rtl) + ":" in (r.get("src") or "")),
        "distinct_registers": len({r["register"] for r in rows
                                   if "register" in r}),
        "flip_flop_census": census,
        "sequential_cells": metrics.get(
            "design__instance__count__class:sequential_cell"),
        "rtl_register_names": len(registers),
        "rtl_register_bits": rtl_bits,
        "auto_name_map": {
            "rebuilt_cells": len(rebuilt_cells),
            "found_in_netlist": present,
        },
        "rows": rows,
    }
    text = json.dumps(result, indent=1, sort_keys=True)
    if out_json:
        with open(out_json, "w") as handle:
            handle.write(text + "\n")
    summary = {k: v for k, v in result.items() if k != "rows"}
    print(json.dumps(summary, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
