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
#   directory of native assets, which the executable loads from
#   `../lib/` relative to itself. SQLite is one of them (an sby task's
#   `status.sqlite` is read through it), so the CLI ships as the whole
#   `bundle/` directory, `bin/` and `lib/` together, never the bare
#   executable. tool/check_cli_bundle.sh checks that pairing.
#
# This script is also the proof that `SimcruxCli`'s import closure is
# Flutter-free — a `package:flutter/...` import anywhere in it fails
# the build here, long before CI. Mirrors lintcrux/tool/build_cli.sh.
#
# Usage:
#   tool/build_cli.sh [output-dir]        # default: build/cli
#
# The result is <output-dir>/bundle/: bin/simcrux and the lib/ it loads.
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

echo "==> native libraries"
tool/check_cli_bundle.sh "${OUT_DIR}/bundle"

echo "==> smoke test"
"${BIN}" --help > /dev/null
# A binary that cannot print its own version is not worth signing; this is
# also the line the Homebrew formula's test block runs.
"${BIN}" --version

echo "==> built ${BIN}"
