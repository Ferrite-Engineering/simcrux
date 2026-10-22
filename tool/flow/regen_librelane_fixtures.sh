#!/bin/bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Re-capture the LibreLane fixture set under verification/fixtures/flow/librelane/.
#
# Usage: tool/flow/regen_librelane_fixtures.sh [--out <dir>] [--work <dir>] [--case <name>]...
#
# Run it where `librelane` is on PATH, for example inside LibreLane's Nix shell:
#   nix-shell <librelane checkout>/shell.nix --run "tool/flow/regen_librelane_fixtures.sh --case sky130A_met"
# PDKs come from LibreLane's own default PDK root (ciel, ~/.ciel) unless
# PDK_ROOT is set. The version directory is the one `librelane --version` prints.
#
# Captures only. The hand-written expectation files beside the captures come
# from the RTL and from jq over LibreLane's own records, and this script never
# creates, edits or deletes one. Per case it writes, under <out>/<version>/<case>/:
#   run/             the run directory, trimmed by tool/flow/trim_run_fixture.py
#   exit_code.txt    the exit status of the librelane command
#   console.tail.txt the last 60 lines LibreLane printed (the deferred-error
#                    summary appears only there)
#
# The g1 case runs the mapping-gate design and writes g1.json with
# tool/flow/measure_g1_mapping.py; its run directory is never trimmed into the
# fixtures (it is too large) and stays under --work when --work is given.
#
# Runs happen in a scratch copy of each design directory, never in the repo.
# Without --work the scratch directory is removed on exit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
fixtures="$repo/verification/fixtures/flow/librelane"
out="$fixtures"
work=""
cases=()
retrim=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --case) cases+=("$2"); shift 2 ;;
    --retrim) retrim=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ ! -d "$fixtures/designs" ]; then
  echo "missing fixture directory: $fixtures/designs" >&2
  exit 1
fi
for tool in librelane python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing tool: $tool" >&2
    exit 1
  fi
done

version="$(librelane --version 2>/dev/null | sed -n 's/^LibreLane v\([0-9][0-9.]*\).*/\1/p' | head -n 1)"
if [ -z "$version" ]; then
  echo "could not read the LibreLane version" >&2
  exit 1
fi

if [ "$retrim" = 1 ] && [ -z "$work" ]; then
  echo "--retrim needs the --work directory of an earlier capture" >&2
  exit 64
fi
if [ -z "$work" ]; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work" "$out"
work="$(cd "$work" && pwd -P)"

# All cases, in order. <name> <design> <config> <pdk>
all_cases=(
  "sky130A_met path_adder config.yaml sky130A"
  "gf180mcuD_met path_adder config.yaml gf180mcuD"
  "ihp-sg13g2_met path_adder config.yaml ihp-sg13g2"
  "sky130A_stopped path_adder config_stopped.yaml sky130A"
  "sky130A_timing path_adder config_timing.yaml sky130A"
  "sky130A_drc path_adder config_drc.yaml sky130A"
  "sky130A_antenna path_adder config_antenna.yaml sky130A"
  "g1 picorv32 config.yaml sky130A"
)

wanted() {
  # The ${x+...} form keeps an empty array safe under set -u in bash 3.2.
  [ -z "${cases[*]+set}" ] && return 0
  local c
  for c in ${cases[@]+"${cases[@]}"}; do
    [ "$c" = "$1" ] && return 0
  done
  return 1
}

run_case() {
  local name="$1" design="$2" config="$3" pdk="$4"
  local dir="$work/$version/$name"
  local dest="$out/$version/$name"
  if [ "$retrim" = 1 ]; then
    if [ ! -d "$dir/design/runs/$name" ]; then
      echo "no earlier run to retrim: $dir/design/runs/$name" >&2
      exit 1
    fi
  else
    if [ -e "$dir" ]; then
      echo "scratch case directory already exists: $dir" >&2
      exit 1
    fi
    mkdir -p "$dir"
    cp -R "$fixtures/designs/$design" "$dir/design"
    set +e
    # A wide console keeps LibreLane from wrapping paths across lines, so the
    # scrub below sees each path whole.
    ( cd "$dir/design" && COLUMNS=1000 librelane --pdk "$pdk" --run-tag "$name" "$config" ) \
      > "$dir/console.txt" 2>&1
    local status=$?
    set -e
    echo "$status" > "$dir/exit_code.txt"
    echo "$name: librelane exited $status"
  fi

  if [ "$name" = "g1" ]; then
    mkdir -p "$out/$version"
    python3 -I "$here/measure_g1_mapping.py" "$dir/design/runs/$name" \
      --rtl "$dir/design/picorv32.v" --top picorv32 \
      --json "$out/$version/g1.json"
    return 0
  fi

  # Replace the previous capture; the case directory's other files stay.
  rm -rf "$dest/run"
  mkdir -p "$dest"
  # Every corner keeps its summary reports; only the nominal typical corner
  # (nom_tt_* on sky130 and gf180, nom_typ_* on IHP) keeps its full path
  # listings, which are most of a run's size. The completed reference runs
  # (*_met) keep final/nl, pnl and sdf for gate-level work; the failure
  # classes do not need them.
  local views=()
  case "$name" in
    *_met) ;;
    *) views=(--no-final-views) ;;
  esac
  python3 -I "$here/trim_run_fixture.py" "$dir/design/runs/$name" "$dest/run" \
    --scrub "$dir/design=<design>" --keep-corner 'nom_t*' ${views[@]+"${views[@]}"}
  cp "$dir/exit_code.txt" "$dest/exit_code.txt"
  tail -n 60 "$dir/console.txt" \
    | sed -e "s|$dir/design|<design>|g" -e "s|$HOME|<home>|g" \
    > "$dest/console.tail.txt"
}

for entry in "${all_cases[@]}"; do
  # shellcheck disable=SC2086
  set -- $entry
  if wanted "$1"; then
    run_case "$1" "$2" "$3" "$4"
  fi
done

# A capture that still names a machine path is a defect, not a fixture.
if grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out/$version" \
     --exclude='PROVENANCE.md' --exclude='MAPPING-GATE.md' >/dev/null 2>&1; then
  echo "unscrubbed machine path in captures under $out/$version" >&2
  grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out/$version" \
    --exclude='PROVENANCE.md' --exclude='MAPPING-GATE.md' >&2 || true
  exit 1
fi
