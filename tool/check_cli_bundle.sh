#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Check that a `simcrux` CLI directory carries the native libraries the
# executable loads.
#
# `dart build cli` writes `bin/simcrux` and a `lib/` of native assets, and the
# executable loads each one from `../lib/<name>`, relative to its own
# location. SQLite is one of them: `simcrux --ci` reads a SymbiYosys task's
# `status.sqlite` through it. Ship `bin/simcrux` without `lib/` and every sby
# task reports its status database as unreadable.
#
# The check reads the library paths out of the executable itself, so it
# follows whatever `dart build cli` embeds rather than a list kept here, and
# insists on the SQLite library by name, since that is the one a run needs.
#
# Usage:
#   tool/check_cli_bundle.sh <dir>     # <dir> holds bin/simcrux[.exe] and lib/
set -euo pipefail

ROOT="${1:?usage: $0 <dir holding bin/simcrux and lib/>}"

BIN="${ROOT}/bin/simcrux"
[[ -f "${BIN}.exe" ]] && BIN="${BIN}.exe"
if [[ ! -f "${BIN}" ]]; then
  echo "error: no simcrux executable under ${ROOT}/bin" >&2
  exit 1
fi

# `|| true`: no match is reported below, with a message, not by grep's status.
refs="$(LC_ALL=C grep -a -o -E '\.\.[/\\]lib[/\\][A-Za-z0-9._+-]+' "${BIN}" \
  | sort -u || true)"
if [[ -z "${refs}" ]]; then
  echo "error: ${BIN} names no ../lib/ native library; the check cannot tell what it needs" >&2
  exit 1
fi
if ! grep -q 'sqlite3' <<<"${refs}"; then
  echo "error: ${BIN} names no SQLite library under ../lib/:" >&2
  echo "${refs}" >&2
  exit 1
fi

missing=0
while IFS= read -r ref; do
  name="${ref##*[/\\]}"
  if [[ -f "${ROOT}/lib/${name}" ]]; then
    echo "ok: lib/${name}"
  else
    echo "error: ${BIN} loads ../lib/${name}, which is not in ${ROOT}/lib" >&2
    missing=1
  fi
done <<<"${refs}"
exit "${missing}"
