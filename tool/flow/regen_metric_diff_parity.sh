#!/bin/bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Re-capture upstream LibreLane's `metrics compare` output, the oracle the
# crux_flow MetricDiff parity test holds its Markdown table to, byte for byte.
#
# Usage: tool/flow/regen_metric_diff_parity.sh [--python <interpreter>] [--out <dir>]
#
#   --python  a Python that imports librelane: a virtual environment with a
#             LibreLane release installed from its tag (no Nix and no PDK are
#             needed). Default: python3.
#   --out     the parity fixture directory, holding handbuilt/gold.metrics.json
#             and handbuilt/new.metrics.json and VERSION. Default: crux_flow's,
#             in this repository's crux-shared submodule.
#
# Captures only. It writes compare_py.<verbosity>.md for each verbosity
# (critical, worse, changed, all) under <out>/handbuilt/ (filter `*`) and
# <out>/handbuilt_default/ (filter DEFAULT, upstream's default set), and
# nothing else: never a metrics pair, never VERSION, never an expectation of
# the product. It refuses to run when the installed LibreLane is not the
# release VERSION names, so a capture always matches its recorded release.
#
# The pairs are hand-built from the metric names of LibreLane's own
# library.py; no run data from the upstream librelane-metrics repository (it
# has no licence) goes into them.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
py="python3"
out="$repo/crux-shared/packages/crux_flow/test/fixtures/metric_diff"

while [ $# -gt 0 ]; do
  case "$1" in
    --python) py="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    -h|--help) sed -n '5,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

gold="$out/handbuilt/gold.metrics.json"
new="$out/handbuilt/new.metrics.json"
for f in "$gold" "$new" "$out/VERSION"; do
  if [ ! -f "$f" ]; then
    echo "missing $f" >&2
    exit 66
  fi
done

installed="$("$py" -c 'import librelane; print(librelane.__version__)')"
recorded="$(tr -d '[:space:]' < "$out/VERSION")"
if [ "$installed" != "$recorded" ]; then
  echo "the installed LibreLane is $installed but VERSION records $recorded;" \
    "install $recorded, or update VERSION and the provenance by hand first" >&2
  exit 1
fi

capture() {
  local name="$1" filter="$2" verbosity lower
  mkdir -p "$out/$name"
  for verbosity in CRITICAL WORSE CHANGED ALL; do
    lower="$(printf '%s' "$verbosity" | tr '[:upper:]' '[:lower:]')"
    "$py" -m librelane.common.metrics compare \
      --table-verbosity "$verbosity" -f "$filter" "$gold" "$new" \
      > "$out/$name/compare_py.$lower.md"
    echo "wrote $out/$name/compare_py.$lower.md"
  done
}

capture handbuilt '*'
capture handbuilt_default DEFAULT
