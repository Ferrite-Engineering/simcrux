#!/bin/bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Re-capture the nextpnr fixture set under verification/fixtures/flow/nextpnr/.
#
# Usage: tool/flow/regen_nextpnr_fixtures.sh [--suite <oss-cad-suite dir>] [--out <dir>] [--case <name>]
#
# Captures only. The hand-written expectation files beside the captures come
# from the RTL or from the log line the tool itself printed, and this script
# never creates, edits or deletes one. The verdict line is extracted with grep from
# nextpnr's own "Max frequency" log line into max_frequency.txt.
#
# With --suite the suite's bin/ is put first on PATH for this process only.
# Without it the tools on PATH are used. Needs: yosys, nextpnr-ice40,
# nextpnr-ecp5 and nextpnr-himbaechel.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
fixtures="$repo/verification/fixtures/flow/nextpnr"
out="$fixtures"
suite=""
only=""

while [ $# -gt 0 ]; do
  case "$1" in
    --suite) suite="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --case) only="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -n "$suite" ]; then
  PATH="$suite/bin:$PATH"
  export PATH
fi

if [ ! -d "$fixtures/rtl" ]; then
  echo "missing fixture directory: $fixtures/rtl" >&2
  exit 1
fi

for tool in yosys nextpnr-ice40 nextpnr-ecp5 nextpnr-himbaechel; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing tool: $tool" >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
work_real="$(cd "$work" && pwd -P)"
export XDG_DATA_HOME="$work/xdg"
mkdir -p "$XDG_DATA_HOME" "$out"

# Rewrite machine-specific paths. The yosys share directory (arith_map.v and
# friends) is install-relative, so it is matched by shape, not by location.
# The match must not cross ':' or '|': Yosys joins the spans of one src
# attribute with '|' ("user.v:13.3-17.6|<lib>/ff_map.v:2.51-2.90"), and a match
# that began before the bar would swallow the user span in front of it.
scrub() {
  sed -E \
    -e "s|$work_real|<work>|g" \
    -e "s|$work|<work>|g" \
    -e "s|$HOME|<home>|g" \
    -e 's#[^ ":|]*/share/yosys/#<yosys-share>/#g' \
    -e 's#[^ ":|]*/libexec/\.\./#<suite>/#g' \
    "$1" > "$1.scrubbed"
  mv "$1.scrubbed" "$1"
}

# run_case <name> <family> <rtl file> <top> <freq MHz> [synth flag]
run_case() {
  local name="$1" family="$2" rtl="$3" top="$4" freq="$5" flag="${6:-}"
  if [ -n "$only" ] && [ "$only" != "$name" ]; then
    return 0
  fi
  local dir="$work/$name"
  local dest="$out/$name"
  mkdir -p "$dir" "$dest"
  cp "$fixtures/rtl/$rtl" "$dir/$rtl"
  cp "$fixtures/rtl/path_adder_gowin.cst" "$dir/path_adder_gowin.cst"
  ( cd "$dir"
    local synth pnr=()
    case "$family" in
      ice40)
        synth="synth_ice40 -top $top $flag"
        pnr=(nextpnr-ice40 --up5k --package sg48) ;;
      ecp5)
        synth="synth_ecp5 -top $top $flag"
        pnr=(nextpnr-ecp5 --25k --package CABGA256) ;;
      gowin)
        synth="synth_gowin -top $top $flag"
        pnr=(nextpnr-himbaechel --device GW1NR-LV9QN88PC6/I5
             --vopt family=GW1N-9 --vopt cst=path_adder_gowin.cst) ;;
      gatemate)
        synth="synth_gatemate -top $top -luttree $flag"
        pnr=(nextpnr-himbaechel --device CCGM1A1 --vopt allow-unconstrained) ;;
      *) echo "unknown family: $family" >&2; exit 64 ;;
    esac
    yosys -q -p "read_verilog $rtl; $synth -json netlist.json"
    set +e
    "${pnr[@]}" --json netlist.json --freq "$freq" \
      --report report.json --detailed-timing-report --log pnr.log \
      > /dev/null 2>&1
    echo $? > exit_code.txt
    set -e
    grep 'Max frequency' pnr.log > max_frequency.txt || true
  )
  # The _violated variants share their _met sibling's synthesized netlist, so
  # only the _met case keeps a copy.
  local files="report.json pnr.log exit_code.txt max_frequency.txt"
  case "$name" in
    *_violated) ;;
    *) files="netlist.json $files" ;;
  esac
  for f in $files; do
    scrub "$dir/$f"
    cp "$dir/$f" "$dest/$f"
  done
}

run_case rescreen_ice40 ice40 top.v top 100
run_case rescreen_ice40_dsp ice40 top.v top 100 -dsp
run_case rescreen_ecp5 ecp5 top.v top 100

run_case path_ice40_met ice40 path_adder.v path_adder 12
run_case path_ice40_violated ice40 path_adder.v path_adder 1000
run_case path_ecp5_met ecp5 path_adder.v path_adder 12
run_case path_ecp5_violated ecp5 path_adder.v path_adder 1000
run_case path_gowin_met gowin path_adder.v path_adder 12
run_case path_gowin_violated gowin path_adder.v path_adder 1000
run_case path_gatemate_met gatemate path_adder.v path_adder 12
run_case path_gatemate_violated gatemate path_adder.v path_adder 1000

if [ -z "$only" ]; then
  {
    echo "yosys: $(yosys -V)"
    echo "nextpnr-ice40: $(nextpnr-ice40 --version 2>&1 | tail -n 1)"
    echo "nextpnr-ecp5: $(nextpnr-ecp5 --version 2>&1 | tail -n 1)"
    echo "nextpnr-himbaechel: $(nextpnr-himbaechel --version 2>&1 | tail -n 1)"
  } > "$out/versions.txt"
fi

# A capture that still names a machine path is a defect, not a fixture.
if grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out" \
     --exclude='PROVENANCE.md' >/dev/null 2>&1; then
  echo "unscrubbed machine path in captures under $out" >&2
  grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out" \
    --exclude='PROVENANCE.md' >&2 || true
  exit 1
fi
