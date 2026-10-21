#!/bin/bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Re-capture the FuseSoC/Edalize servant run under verification/fixtures/flow/fusesoc/.
#
# Usage: tool/flow/regen_fusesoc_fixture.sh [--suite <oss-cad-suite dir>] [--yosys-dir <dir>] [--out <dir>]
#
# Runs `fusesoc run --target=icebreaker award-winning:serv:servant` (Edalize
# icestorm flow: Yosys, nextpnr-ice40, icepack) without nextpnr's --report, so
# the only timing evidence is the nextpnr log. Captures only; the hand-written
# expectation file beside the captures is never touched here.
#
# Needs network for git clone and pip.
set -euo pipefail

serv_rev="f200eb2ed7b69ac1c6b8eddd47654522aeee5ce8"
cores_rev="def274ab01abd2f074d8e3c6891cba0181010095"
fusesoc_version="2.4.7"
edalize_version="0.6.8"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
out="$repo/verification/fixtures/flow/fusesoc"
suite=""
yosys_dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --suite) suite="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --yosys-dir) yosys_dir="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ -n "$suite" ]; then
  PATH="$suite/bin:$PATH"
  export PATH
fi
# Edalize drives Yosys through a Tcl script, so Yosys must be built with Tcl.
# Some OSS CAD Suite builds (darwin-arm64 2026-10-21) are not; --yosys-dir
# names a directory whose yosys is, and it wins over the suite for this run.
if [ -n "$yosys_dir" ]; then
  PATH="$yosys_dir:$PATH"
  export PATH
fi

for tool in yosys nextpnr-ice40 icepack icepll git python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing tool: $tool" >&2
    exit 1
  fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
work_real="$(cd "$work" && pwd -P)"
export XDG_DATA_HOME="$work/xdg"
export XDG_CONFIG_HOME="$work/xdg-config"
export XDG_CACHE_HOME="$work/xdg-cache"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$out"

python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet --disable-pip-version-check "fusesoc==$fusesoc_version" "edalize==$edalize_version"

PATH="$work/venv/bin:$PATH"
export PATH

git clone --quiet https://github.com/olofk/serv "$work/serv"
git -C "$work/serv" checkout --quiet --detach "$serv_rev"
git clone --quiet https://github.com/fusesoc/fusesoc-cores "$work/fusesoc-cores"
git -C "$work/fusesoc-cores" checkout --quiet --detach "$cores_rev"

mkdir -p "$work/build"
( cd "$work/build"
  "$work/venv/bin/fusesoc" --cores-root "$work/serv" --cores-root "$work/fusesoc-cores" \
    run --target=icebreaker award-winning:serv:servant > fusesoc_stdout.log 2>&1 \
    || { tail -n 40 fusesoc_stdout.log >&2; exit 1; }
)

build="$(find "$work/build" -type d -name 'icebreaker-icestorm' | head -n 1)"
if [ -z "$build" ]; then
  echo "no icebreaker-icestorm build directory under $work/build" >&2
  exit 1
fi

scrub() {
  sed -E \
    -e "s|$work_real|<work>|g" \
    -e "s|$work|<work>|g" \
    -e "s|$HOME|<home>|g" \
    -e 's|[^ ":=]*/share/yosys/|<yosys-share>/|g' \
    -e 's|[^ ":=]*/libexec/\.\./|<suite>/|g' \
    "$1" > "$1.scrubbed"
  mv "$1.scrubbed" "$1"
}

mkdir -p "$out/build"
for f in "$build"/*.log "$build"/*.json "$build"/Makefile "$build"/*.eda.yml; do
  if [ -f "$f" ]; then
    cp "$f" "$out/build/$(basename "$f")"
    scrub "$out/build/$(basename "$f")"
  fi
done
{
  echo "serv: $serv_rev"
  echo "fusesoc-cores: $cores_rev"
  echo "fusesoc: $fusesoc_version"
  echo "edalize: $edalize_version"
  echo "yosys: $(yosys -V)"
  echo "nextpnr-ice40: $(nextpnr-ice40 --version 2>&1 | tail -n 1)"
} > "$out/versions.txt"

if grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out" \
     --exclude='PROVENANCE.md' >/dev/null 2>&1; then
  echo "unscrubbed machine path in captures under $out" >&2
  grep -rIlE '/Users/|/home/|/private/|/var/folders|/runner/' "$out" \
    --exclude='PROVENANCE.md' >&2 || true
  exit 1
fi
