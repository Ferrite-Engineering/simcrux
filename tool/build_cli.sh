#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Build the headless `simcrux` CI binary.
#
# Why `dart build cli` and not `dart compile exe`:
#   `dart compile` refuses to run when any package in the resolution
#   declares a native build hook. Flutter plugins the *desktop app*
#   needs (and the CLI never touches) do, but resolution is
#   per-package, not per-entrypoint. `dart build cli` is the supported
#   replacement. It emits `<out>/bundle/bin/simcrux` plus a `lib/`
#   directory of native assets; the executable does not load any of
#   them for this entrypoint, so `bundle/bin/simcrux` ships standalone.
#
# This script is also the proof that `SimcruxCli`'s import closure is
# Flutter-free — a `package:flutter/...` import anywhere in it fails
# the build here, long before CI. Mirrors lintcrux/tool/build_cli.sh.
#
# Usage:
#   tool/build_cli.sh [output-dir]        # default: build/cli
#
# The resulting single-file binary is at:
#   <output-dir>/bundle/bin/simcrux
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-build/cli}"

echo "==> dart build cli -t bin/simcrux.dart -o ${OUT_DIR}"
dart build cli -t bin/simcrux.dart -o "${OUT_DIR}"

BIN="${OUT_DIR}/bundle/bin/simcrux"
if [[ ! -x "${BIN}" ]]; then
  echo "error: expected executable at ${BIN}" >&2
  exit 1
fi

echo "==> smoke test"
"${BIN}" --help > /dev/null

echo "==> built ${BIN}"
