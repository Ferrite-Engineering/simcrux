#!/usr/bin/env python3
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
"""Copy a LibreLane run directory into a committable fixture.

Usage:
  trim_run_fixture.py <run dir> <out dir> [--scrub FROM=TO]... [--max-bytes N]
      [--keep-corner GLOB]... [--no-final-views]

Reads <run dir> and writes a trimmed copy to <out dir>, which must not exist
yet. Nothing under <run dir> is changed or deleted.

What is kept, byte for byte apart from path scrubbing:
  - every JSON file (resolved.json, config.json, state_in.json, state_out.json,
    metrics.json, or_metrics_out.json, the synthesis sidecar <D>.nl.v.json),
  - every log (flow.log, warning.log, error.log, step logs, sta.log),
  - every report (reports/, *.rpt, *.lyrdb, *.csv, *.txt, COMMANDS, runtime),
    except the STA listings named below,
  - the metrics (final/metrics.json, final/metrics.csv),
  - the synthesis step's netlist <D>.nl.v (the sidecar's names join to it),
  - the text views under final/: nl, pnl, sdf, sdc, vh, json_h, lib.

What is replaced by a zero-byte placeholder of the same name: every other
design view (GDS, ODB, DEF, SPEF, Magic and KLayout layouts, extraction
files, renders, per-step copies of netlists, SDF and Liberty), any file that
is not text, the tool environment scripts (_env*.tcl, rebuilt from the
step's config.json), and the path listings and logs (max.rpt, min.rpt,
*.log) of the pre-PnR and mid-PnR STA steps, which repeat the post-PnR
step's report shapes on earlier netlists; their summary reports and JSON
stay. With --keep-corner, the post-PnR STA step keeps the path listings and
logs only of the corners matching one of the patterns; the other corners
keep their summary reports. --no-final-views also turns the text views under
final/ into placeholders. The run root's tmp/ is dropped. Each placeholder
and each dropped file is listed in TRIMMED.json at the root of <out dir> with
its original size and SHA-256.

Scrubbing rewrites each FROM prefix to TO in every kept text file, longest
FROM first; the home directory is always rewritten to <home>. After the copy
the tool fails if any kept file is larger than --max-bytes (default 5 MiB) or
if a kept file still names a machine path.

Exit status: 0 on success, 1 when a check fails, 64 on bad usage.
"""

import fnmatch
import hashlib
import json
import os
import re
import sys

MAX_BYTES_DEFAULT = 5 * 1024 * 1024

KEEP_SUFFIXES = {
    ".json", ".log", ".rpt", ".lyrdb", ".csv", ".txt", ".tcl", ".yaml",
    ".yml", ".cfg", ".sdc", ".abc", ".xml",
}
KEEP_NAMES = {"COMMANDS", "runtime.txt"}
VIEW_SUFFIXES = {
    ".gds", ".odb", ".def", ".spef", ".mag", ".ext", ".png", ".guide", ".v",
    ".spice", ".sdf", ".lib", ".lef", ".vh", ".sim", ".nodes", ".oas",
    ".gz", ".klayout",
}
FINAL_TEXT_VIEWS = {"nl", "pnl", "sdf", "sdc", "vh", "json_h", "lib"}
# Pre-PnR and mid-PnR STA steps repeat the post-PnR step's report shapes on
# earlier netlists. Their path listings and logs are the bulk of a run, so
# they become placeholders; their summary reports and JSON stay.
INTERMEDIATE_STA_STEP = re.compile(
    r"^\d+-openroad-sta(?:prepnr|midpnr)(?:-\d+)?$"
)
INTERMEDIATE_STA_BULK = re.compile(r"^(?:max\.rpt|min\.rpt|sta\.log|.*\.log)$")
POST_PNR_STA_STEP = re.compile(r"^\d+-openroad-stapostpnr$")
CORNER_BULK = re.compile(r"^(?:max\.rpt|min\.rpt|.*\.log)$")
MACHINE_PATH = re.compile(rb"/Users/|/home/|/private/|/var/folders|/runner/")


def usage(message):
    sys.stderr.write(f"{message}\n{__doc__}")
    sys.exit(64)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def is_text(path):
    with open(path, "rb") as handle:
        head = handle.read(8192)
    if b"\0" in head:
        return False
    try:
        head.decode("utf-8")
    except UnicodeDecodeError as error:
        # A multi-byte character cut at the 8 KiB boundary is still text.
        return error.start >= len(head) - 3
    return True


def classify(rel, keep_corners=None, final_views=True):
    """Return 'keep', 'view', 'sta', 'corner' or 'drop' for a path relative to
    the run root. keep_corners is None (keep every corner) or a list of
    fnmatch patterns naming the post-PnR STA corners whose listings stay.
    final_views False turns the text views under final/ into placeholders."""
    parts = rel.split("/")
    name = parts[-1]
    suffix = os.path.splitext(name)[1].lower()
    if parts[0] == "tmp":
        return "drop"
    if (not final_views and parts[0] == "final" and len(parts) >= 3
            and parts[1] in FINAL_TEXT_VIEWS):
        return "view"
    if INTERMEDIATE_STA_STEP.match(parts[0]) and INTERMEDIATE_STA_BULK.match(name):
        return "sta"
    if name.startswith("_env") and suffix == ".tcl":
        return "view"
    if (keep_corners is not None and len(parts) == 3
            and POST_PNR_STA_STEP.match(parts[0]) and CORNER_BULK.match(name)
            and not any(fnmatch.fnmatchcase(parts[1], p) for p in keep_corners)):
        return "corner"
    if parts[0] == "final" and len(parts) >= 3 and parts[1] in FINAL_TEXT_VIEWS:
        return "keep"
    if parts[0] == "final" and len(parts) == 2:
        return "keep" if suffix in {".json", ".csv"} else "view"
    if len(parts) == 2 and parts[0].endswith("-yosys-synthesis"):
        if name.endswith(".nl.v") or name.endswith(".nl.v.json"):
            return "keep"
    if name in KEEP_NAMES or suffix in KEEP_SUFFIXES:
        return "keep"
    if "reports" in parts[:-1] and suffix not in VIEW_SUFFIXES:
        return "keep"
    if suffix in VIEW_SUFFIXES or suffix == "":
        return "view" if suffix else "keep"
    return "keep"


def scrub(data, rules):
    for source, target in rules:
        data = data.replace(source, target)
    return data


def main(argv):
    args = list(argv)
    rules = []
    max_bytes = MAX_BYTES_DEFAULT
    keep_corners = None
    final_views = True
    positional = []
    while args:
        arg = args.pop(0)
        if arg == "--no-final-views":
            final_views = False
        elif arg == "--keep-corner":
            if not args:
                usage("--keep-corner needs a pattern")
            keep_corners = (keep_corners or []) + [args.pop(0)]
        elif arg == "--scrub":
            if not args or "=" not in args[0]:
                usage("--scrub needs FROM=TO")
            source, target = args.pop(0).split("=", 1)
            if not source:
                usage("--scrub FROM must not be empty")
            rules.append((source, target))
        elif arg == "--max-bytes":
            if not args:
                usage("--max-bytes needs a number")
            max_bytes = int(args.pop(0))
        elif arg.startswith("-"):
            usage(f"unknown option: {arg}")
        else:
            positional.append(arg)
    if len(positional) != 2:
        usage("expected <run dir> and <out dir>")
    run_dir, out_dir = (os.path.abspath(p) for p in positional)
    if not os.path.isdir(run_dir):
        usage(f"not a directory: {run_dir}")
    if os.path.exists(out_dir):
        usage(f"refusing to write into an existing path: {out_dir}")
    if os.path.commonpath([run_dir, out_dir]) == run_dir:
        usage("the output must not be inside the run directory")

    home = os.path.expanduser("~")
    real_run = os.path.realpath(run_dir)
    all_rules = list(rules)
    for path in {run_dir, real_run}:
        if not any(source == path for source, _ in all_rules):
            all_rules.append((path, "<run>"))
    all_rules.append((home, "<home>"))
    byte_rules = sorted(
        ((s.encode(), t.encode()) for s, t in all_rules),
        key=lambda rule: len(rule[0]),
        reverse=True,
    )

    removed = []
    kept_bytes = 0
    oversize = []
    unscrubbed = []
    for root, dirs, files in os.walk(run_dir):
        dirs.sort()
        rel_root = os.path.relpath(root, run_dir)
        for name in sorted(files):
            source = os.path.join(root, name)
            rel = name if rel_root == "." else f"{rel_root}/{name}"
            rel = rel.replace(os.sep, "/")
            if os.path.islink(source):
                removed.append({"path": rel, "action": "dropped",
                                "reason": "symbolic link"})
                continue
            action = classify(rel, keep_corners, final_views)
            if action == "keep" and not is_text(source):
                action = "view"
            size = os.path.getsize(source)
            if action == "drop":
                removed.append({"path": rel, "action": "dropped",
                                "reason": "run scratch (tmp/)",
                                "bytes": size, "sha256": sha256(source)})
                continue
            dest = os.path.join(out_dir, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            if action in ("view", "sta", "corner"):
                reason = {
                    "view": "design view or binary",
                    "sta": "intermediate STA path listing or log",
                    "corner": "post-PnR STA path listing of a corner not kept",
                }[action]
                removed.append({"path": rel, "action": "placeholder",
                                "reason": reason,
                                "bytes": size, "sha256": sha256(source)})
                open(dest, "wb").close()
                continue
            with open(source, "rb") as handle:
                data = scrub(handle.read(), byte_rules)
            with open(dest, "wb") as handle:
                handle.write(data)
            kept_bytes += len(data)
            if len(data) > max_bytes:
                oversize.append(f"{rel} ({len(data)} bytes)")
            if MACHINE_PATH.search(data):
                unscrubbed.append(rel)

    manifest = {
        "tool": "tool/flow/trim_run_fixture.py",
        "max_file_bytes": max_bytes,
        "keep_corners": keep_corners if keep_corners is not None else "all",
        "final_views": final_views,
        "kept_bytes": kept_bytes,
        "removed": removed,
    }
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "TRIMMED.json"), "w") as handle:
        json.dump(manifest, handle, indent=1, sort_keys=True)
        handle.write("\n")

    status = 0
    if oversize:
        sys.stderr.write("files over the size limit:\n  " +
                         "\n  ".join(oversize) + "\n")
        status = 1
    if unscrubbed:
        sys.stderr.write("files still naming a machine path:\n  " +
                         "\n  ".join(unscrubbed) + "\n")
        status = 1
    print(f"kept {kept_bytes} bytes; {len(removed)} files replaced or dropped")
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
