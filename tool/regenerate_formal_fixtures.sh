#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Regenerate the CAPTURED tool output of the formal fixture corpus,
# verification/fixtures/formal/.
#
# It runs the real sby, eqy and yosys (with the yosys-slang plugin) from one
# or more unpacked OSS CAD Suite builds, in a scratch directory, copies the
# captures back, scrubs machine paths out of them, and rewrites the generated
# block of verification/fixtures/formal/PROVENANCE.md.
#
# It NEVER writes, moves or deletes a *.expected.* file. Expectations are
# written by hand from each property's meaning (PROVENANCE.md says how). A
# regenerator that could touch them would let a tool bug become the expected
# answer.
#
# Usage:
#   tool/regenerate_formal_fixtures.sh --suite <oss-cad-suite> [--suite <oss-cad-suite> ...] [--out <scratch-dir>]
#
#   --suite  an unpacked OSS CAD Suite: the directory holding bin/ and VERSION.
#            Give the newest build first. The FIRST suite produces every
#            capture under sby/*/captured/, sva_matrix/captured/ and
#            eqy/captured/. EVERY suite produces schemas/<build>/: the status
#            stream, status.sqlite and EQY work-dir shapes the parsers are
#            written against, one directory per build.
#   --out    scratch directory for the tool runs (default:
#            ${TMPDIR:-/tmp}/simcrux-formal-regen). Wiped per build.
#
# Each tool is called by absolute path inside its suite, so nothing needs to
# be on PATH and builds never mix.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
FIX="$ROOT/verification/fixtures/formal"
OUT="${TMPDIR:-/tmp}/simcrux-formal-regen"
SUITES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --suite) SUITES+=("$(cd "$2" && pwd)"); shift 2 ;;
    --out) mkdir -p "$2"; OUT="$(cd "$2" && pwd)"; shift 2 ;;
    -h|--help) sed -n '5,30p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done
if [ ${#SUITES[@]} -eq 0 ]; then
  echo "at least one --suite <oss-cad-suite> is required" >&2
  exit 64
fi
for suite in "${SUITES[@]}"; do
  for tool in yosys sby eqy; do
    if [ ! -x "$suite/bin/$tool" ]; then
      echo "$suite/bin/$tool is missing: --suite takes the directory holding bin/ and VERSION" >&2
      exit 66
    fi
  done
done
command -v python3 >/dev/null || { echo "python3 is required (scrubbing, sqlite schema)" >&2; exit 69; }

# Remember every .expected.* file and its hash, so the run can prove at the
# end that it touched none of them.
expected_hashes() {
  find "$FIX" -name '*.expected.*' -type f -print0 | sort -z | xargs -0 shasum -a 256
}
EXPECTED_BEFORE="$(expected_hashes)"

build_of() { tr -d '[:space:]' < "$1/VERSION"; }

# Copy $1 to $2 when $1 exists. A bare `[ -f ] && cp` returns 1 when the file
# is absent, which ends a function (and the run) under `set -e`.
copy_if() { if [ -f "$1" ]; then cp "$1" "$2"; fi; }

# Record which verdict marker file (PASS, FAIL, ...) a work dir holds.
marker_of() {
  local dir="$1" out="$2" verdict
  for verdict in PASS FAIL UNKNOWN ERROR TIMEOUT; do
    if [ -f "$dir/$verdict" ]; then echo "$verdict" > "$out"; fi
  done
}

# Replace machine paths in every text file under $1: the scratch directory,
# the suite, the repository and the home directory. Binary files (a NUL byte)
# are left alone; status.sqlite holds only workdir-relative paths.
scrub() {
  python3 - "$1" "$OUT" "$2" "$ROOT" "$HOME" <<'PY'
import os, sys
root, work, suite, repo, home = sys.argv[1:6]
pairs = [(work, "<work>"), (suite, "<oss-cad-suite>"), (repo, "<repo>"), (home, "<home>")]
pairs = [(os.path.realpath(a), b) for a, b in pairs] + pairs
pairs.sort(key=lambda p: -len(p[0]))
for dirpath, _, files in os.walk(root):
    for name in files:
        path = os.path.join(dirpath, name)
        data = open(path, "rb").read()
        if b"\0" in data:
            continue
        text = data.decode("utf-8", errors="replace")
        new = text
        for old, rep in pairs:
            if old:
                new = new.replace(old, rep)
        if new != text:
            open(path, "w", encoding="utf-8").write(new)
PY
}

# Schema (no rows) of an sqlite file, read-only.
sqlite_schema() {
  python3 - "$1" <<'PY'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
for (kind, name, sql) in con.execute(
        "SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY type, name"):
    print(sql.strip() + ";")
print("-- PRAGMA user_version =", con.execute("PRAGMA user_version").fetchone()[0])
PY
}

# A self-contained copy of an sqlite file. sby keeps status.sqlite in WAL
# mode, so a plain cp can miss rows still in the -wal file; VACUUM INTO
# writes every committed row into one file with no sidecars.
sqlite_copy() {
  python3 - "$1" "$2" <<'PY'
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("VACUUM INTO ?", (sys.argv[2],))
con.close()
PY
}

# Sorted, workdir-relative listing of every file under $1 (the layout).
listing() { (cd "$1" && find . -type f | sed 's|^\./||' | LC_ALL=C sort); }

versions() {
  local suite="$1"
  echo "oss-cad-suite $(build_of "$suite")"
  echo "yosys $("$suite/bin/yosys" -V)"
  echo "sby $("$suite/bin/sby" --version 2>&1)"
  echo "eqy $("$suite/bin/eqy" --version 2>&1)"
  # The plugin has no version flag: name the slang library the suite ships
  # and fingerprint the plugin binary itself.
  local plugin="$suite/share/yosys/plugins/slang.so"
  if [ -f "$plugin" ]; then
    echo "yosys-slang plugin sha256 $(shasum -a 256 "$plugin" | cut -c1-16), $("$suite/bin/slang" --version 2>&1 | head -n1)"
  else
    echo "yosys-slang plugin absent"
  fi
  for solver in yices bitwuzla boolector; do
    if [ -x "$suite/bin/$solver" ]; then
      echo "$solver $("$suite/bin/$solver" --version 2>&1 | head -n1)"
    fi
  done
}

# Run every task of one .sby file in $2 with --live jsonl; capture into $3.
run_sby_case() {
  local suite="$1" work="$2" dest="$3" sby="$4" job rc
  job="${sby%.sby}"
  set +e
  (cd "$work" && "$suite/bin/sby" -f --live jsonl "$sby") > "$work/run.log" 2>&1
  rc=$?
  set -e
  mkdir -p "$dest"
  cp "$work/run.log" "$dest/run.log"
  echo "$rc" > "$dest/sby.exit"
  (cd "$work" && "$suite/bin/sby" --statusfmt jsonl "$sby") > "$dest/status.jsonl" 2>&1 || true
  (cd "$work" && "$suite/bin/sby" --statusfmt csv "$sby") > "$dest/status.csv" 2>&1 || true
  if [ -f "$work/$job/status.sqlite" ]; then
    sqlite_copy "$work/$job/status.sqlite" "$dest/status.sqlite"
  fi
  for taskdir in "$work/${job}"_*/; do
    [ -d "$taskdir" ] || continue
    local task="${taskdir%/}"
    task="${task##*/${job}_}"
    mkdir -p "$dest/$task"
    copy_if "$taskdir/logfile.txt" "$dest/$task/sby.log"
    copy_if "$taskdir/status" "$dest/$task/status"
    copy_if "$taskdir/${job}_${task}.xml" "$dest/$task/junit.xml"
    marker_of "$taskdir" "$dest/$task/verdict_marker"
    # A refused design: older sby builds keep the frontend's error only in
    # the Yosys log, not in the task log, so keep it for the refusal.
    if [ -f "$taskdir/ERROR" ]; then
      copy_if "$taskdir/model/design.log" "$dest/$task/design.log"
    elif [ -f "$taskdir/model/design.il" ]; then
      # The design sby elaborated, as Yosys JSON: the input the pre-trace
      # detector and the dropped-property guard read.
      (cd "$taskdir/model" && "$suite/bin/yosys" -q -p 'read_rtlil design.il; write_json elaborated.json') \
        && copy_if "$taskdir/model/elaborated.json" "$dest/$task/elaborated.json"
    fi
    (cd "$taskdir" && find . -path './engine_*' -name '*.vcd' -type f) | while read -r vcd; do
      mkdir -p "$dest/$task/$(dirname "${vcd#./}")"
      cp "$taskdir/$vcd" "$dest/$task/${vcd#./}"
    done
  done
}

run_sby_corpus() {
  local suite="$1" scratch="$2"
  for casedir in "$FIX"/sby/*/; do
    local case_name sby
    case_name="$(basename "$casedir")"
    sby="$case_name.sby"
    mkdir -p "$scratch/sby/$case_name"
    find "$casedir" -maxdepth 1 -type f \( -name '*.sv' -o -name '*.v' -o -name '*.sby' \) \
      -exec cp {} "$scratch/sby/$case_name/" \;
    rm -rf "$casedir/captured"
    echo "sby: $case_name"
    run_sby_case "$suite" "$scratch/sby/$case_name" "$casedir/captured" "$sby"
    scrub "$casedir/captured" "$suite"
  done
}

run_sva_matrix() {
  local suite="$1" dest="$FIX/sva_matrix/captured" probes="$FIX/sva_matrix/probes"
  local count='tee -o CELLS select -count t:$assert t:$assume t:$cover t:$check t:$live t:$fair'
  rm -rf "$dest"
  mkdir -p "$dest"
  printf 'probe\tfrontend\texit\tcells\n' > "$dest/results.tsv"
  (cd "$probes" && find . -name '*.sv' -type f | sed 's|^\./||' | LC_ALL=C sort) | while read -r probe; do
    local name="${probe%.sv}"
    mkdir -p "$dest/$(dirname "$name")"
    for fe in builtin slang; do
      local script cells="$OUT/cells.txt" rc
      rm -f "$cells"
      if [ "$fe" = builtin ]; then
        script="read_verilog -formal -sv $probes/$probe; prep -top m; ${count/CELLS/$cells}"
      else
        script="plugin -i slang; read_slang $probes/$probe --top m; prep -top m; ${count/CELLS/$cells}"
      fi
      set +e
      "$suite/bin/yosys" -Q -q -p "$script" > "$dest/$name.$fe.log" 2>&1
      rc=$?
      set -e
      local n=""
      if [ -f "$cells" ]; then n="$(grep -o '^[0-9]*' "$cells" | head -n1)"; fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$fe" "$rc" "$n" >> "$dest/results.tsv"
    done
  done
  scrub "$dest" "$suite"
}

run_eqy_case() {
  local suite="$1" work="$2" dest="$3" run="$4" rc
  set +e
  (cd "$work" && "$suite/bin/eqy" -f "$run.eqy") > "$work/$run.out" 2>&1
  rc=$?
  set -e
  mkdir -p "$dest"
  echo "$rc" > "$dest/eqy.exit"
  cp "$work/$run/logfile.txt" "$dest/eqy.log"
  listing "$work/$run" > "$dest/workdir.txt"
  for f in partition.list summary_targets.list matched.ids; do
    copy_if "$work/$run/$f" "$dest/$f"
  done
  marker_of "$work/$run" "$dest/verdict_marker"
  for sdir in "$work/$run"/strategies/*/*/; do
    [ -d "$sdir" ] || continue
    local rel="${sdir#"$work/$run/"}"
    rel="${rel%/}"
    local part="${rel#strategies/}"
    part="${part%%/*}"
    mkdir -p "$dest/$rel"
    copy_if "$sdir/status" "$dest/$rel/status"
    copy_if "$sdir/$part/logfile.txt" "$dest/$rel/sby.log"
    for vcd in trace.vcd trace_induct.vcd; do
      copy_if "$sdir/$part/engine_0/$vcd" "$dest/$rel/$vcd"
    done
  done
}

run_eqy_corpus() {
  local suite="$1" scratch="$2"
  rm -rf "$FIX/eqy/captured"
  mkdir -p "$scratch/eqy"
  cp "$FIX"/eqy/*.v "$FIX"/eqy/*.eqy "$scratch/eqy/"
  for eqy in "$FIX"/eqy/*.eqy; do
    local run
    run="$(basename "$eqy" .eqy)"
    echo "eqy: $run"
    run_eqy_case "$suite" "$scratch/eqy" "$FIX/eqy/captured/$run" "$run"
  done
  scrub "$FIX/eqy/captured" "$suite"
}

# The parsers' contracts: one schema directory per build.
run_schemas() {
  local suite="$1" scratch="$2" build dest
  build="$(build_of "$suite")"
  dest="$FIX/schemas/$build"
  rm -rf "$dest"
  mkdir -p "$dest"
  versions "$suite" > "$dest/versions.txt"
  "$suite/bin/sby" --help > "$dest/sby_help.txt" 2>&1 || true
  for case_name in handshake_imm fifo_slang; do
    local work="$scratch/schema/$case_name" out="$dest/sby/$case_name"
    mkdir -p "$work" "$out"
    find "$FIX/sby/$case_name" -maxdepth 1 -type f \( -name '*.sv' -o -name '*.sby' \) -exec cp {} "$work/" \;
    set +e
    (cd "$work" && "$suite/bin/sby" -f --live jsonl "$case_name.sby") > "$work/run.log" 2>&1
    set -e
    sed -n 's/^.*\] jsonl: //p' "$work/run.log" > "$out/live.jsonl"
    (cd "$work" && "$suite/bin/sby" --statusfmt jsonl "$case_name.sby") > "$out/status.jsonl" 2>&1 || true
    (cd "$work" && "$suite/bin/sby" --dumptaskinfo "$case_name.sby") > "$out/taskinfo.json" 2>&1 || true
    if [ -f "$work/$case_name/status.sqlite" ]; then
      sqlite_schema "$work/$case_name/status.sqlite" > "$out/status.sqlite.schema.sql"
    else
      echo "-- no $case_name/status.sqlite in this build" > "$out/status.sqlite.schema.sql"
    fi
    (cd "$work" && find . -type f ! -path './src/*' ! -name 'run.log' \
      ! -path '*/model/*' ! -path '*/src/*' | sed 's|^\./||' | LC_ALL=C sort) > "$out/workdir.txt"
  done
  # The refusal shapes the SVA classifier reads, per build: older sby builds
  # keep the frontend's message only in the Yosys log.
  local twork="$scratch/schema/handshake_temporal"
  mkdir -p "$twork"
  find "$FIX/sby/handshake_temporal" -maxdepth 1 -type f \( -name '*.sv' -o -name '*.sby' \) -exec cp {} "$twork/" \;
  set +e
  (cd "$twork" && "$suite/bin/sby" -f handshake_temporal.sby) > "$twork/run.log" 2>&1
  set -e
  for task in builtin slang; do
    mkdir -p "$dest/sby/handshake_temporal/$task"
    copy_if "$twork/handshake_temporal_$task/logfile.txt" "$dest/sby/handshake_temporal/$task/sby.log"
    copy_if "$twork/handshake_temporal_$task/model/design.log" "$dest/sby/handshake_temporal/$task/design.log"
  done
  local work="$scratch/schema/eqy" out="$dest/eqy/alu_fail2"
  mkdir -p "$work" "$out"
  cp "$FIX"/eqy/*.v "$FIX/eqy/alu_fail2.eqy" "$work/"
  set +e
  (cd "$work" && "$suite/bin/eqy" -f alu_fail2.eqy) > "$work/alu_fail2.out" 2>&1
  set -e
  listing "$work/alu_fail2" > "$out/workdir.txt"
  cp "$work/alu_fail2/logfile.txt" "$out/eqy.log"
  copy_if "$work/alu_fail2/partition.list" "$out/partition.list"
  scrub "$dest" "$suite"
}

write_provenance() {
  python3 - "$FIX/PROVENANCE.md" "$@" <<'PY'
import datetime, os, sys
path, primary_build = sys.argv[1], sys.argv[2]
builds = sys.argv[3:]
fix = os.path.dirname(path)
begin, end = "<!-- regenerated:begin -->", "<!-- regenerated:end -->"
lines = [begin, "", "## Captures (written by tool/regenerate_formal_fixtures.sh)", ""]
lines.append(f"Regenerated {datetime.datetime.now(datetime.timezone.utc).date().isoformat()} with:")
lines.append("")
args = " ".join(f"--suite <oss-cad-suite {b}>" for b in builds)
lines.append(f"    tool/regenerate_formal_fixtures.sh {args}")
lines.append("")
lines.append("### Builds")
lines.append("")
for b in builds:
    lines.append(f"- build {b}:")
    for v in open(os.path.join(fix, "schemas", b, "versions.txt")):
        v = v.strip()
        if v and not v.startswith("oss-cad-suite"):
            lines.append(f"  - {v}")
lines.append("")
lines.append("### Capture directories and the build each came from")
lines.append("")
capdirs = []
for d in sorted(os.listdir(os.path.join(fix, "sby"))):
    if os.path.isdir(os.path.join(fix, "sby", d, "captured")):
        capdirs.append(f"sby/{d}/captured/")
for d in ("sva_matrix/captured/", "eqy/captured/"):
    if os.path.isdir(os.path.join(fix, d)):
        capdirs.append(d)
for d in capdirs:
    lines.append(f"- `{d}` build {primary_build}")
for b in builds:
    lines.append(f"- `schemas/{b}/` build {b}")
lines += ["", end]
block = "\n".join(lines)
text = open(path).read() if os.path.exists(path) else ""
if begin in text and end in text:
    head, rest = text.split(begin, 1)
    tail = rest.split(end, 1)[1]
    text = head + block + tail
else:
    text = text.rstrip("\n") + "\n\n" + block + "\n"
open(path, "w").write(text)
PY
}

PRIMARY="${SUITES[0]}"
BUILDS=()
for suite in "${SUITES[@]}"; do
  build="$(build_of "$suite")"
  BUILDS+=("$build")
  scratch="$OUT/$build"
  rm -rf "$scratch"
  mkdir -p "$scratch"
  echo "== build $build: schemas"
  run_schemas "$suite" "$scratch"
  if [ "$suite" = "$PRIMARY" ]; then
    echo "== build $build: captures"
    run_sby_corpus "$suite" "$scratch"
    run_sva_matrix "$suite"
    run_eqy_corpus "$suite" "$scratch"
  fi
done
write_provenance "$(build_of "$PRIMARY")" "${BUILDS[@]}"

if [ "$(expected_hashes)" != "$EXPECTED_BEFORE" ]; then
  echo "BUG: a *.expected.* file changed during regeneration; restore it from git" >&2
  exit 70
fi
echo "done: captures regenerated; no *.expected.* file was touched"
