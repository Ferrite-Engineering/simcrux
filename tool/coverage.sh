#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Runs the test suite with coverage, strips generated code so the figure
# reflects hand-written code, reports the line %, and (when MIN_COVERAGE is set)
# fails if coverage fell below the floor.
#
# Generated code excluded — matches the project's coverage baseline:
#   • build_runner / Riverpod outputs   (**/*.g.dart)
#   • generated localizations           (lib/l10n/generated/**)
#
# Usage:
#   tool/coverage.sh                         # report only (no gate)
#   MIN_COVERAGE=78 tool/coverage.sh         # fail if below 78%
#   tool/coverage.sh test/services           # restrict to a subtree
#
# SimCrux has no native library, so unlike WaveCrux's copy this needs no
# LD_LIBRARY_PATH / DYLD_LIBRARY_PATH set by the caller.
set -uo pipefail

MIN_COVERAGE="${MIN_COVERAGE:-0}"
LCOV_RAW="coverage/lcov.info"
LCOV_FILTERED="coverage/lcov.filtered.info"

flutter test --coverage "$@"
test_rc=$?
if [[ $test_rc -ne 0 ]]; then
  echo "::error::flutter test failed (exit $test_rc)"
  exit "$test_rc"
fi

if [[ ! -f "$LCOV_RAW" ]]; then
  echo "::error::no $LCOV_RAW produced"
  exit 1
fi

# Two things here are load-bearing; both were bugs in the original WaveCrux
# copy this was ported from, found 2026-08-17 while porting it.
#
# 1. The l10n pattern must be `*/l10n/generated/*`, not `lib/l10n/generated/*`.
#    lcov 2.x matches these against the full path with leading-glob semantics,
#    so the `lib/`-anchored form silently matched nothing while `*.g.dart`
#    worked — leaving five generated localization files (the largest and least
#    covered code in the repo) in the denominator.
#
# 2. `--ignore-errors empty` is required. lcov 2.5 exits non-zero on
#    "function coverage enabled but no corresponding coverpoints found", which
#    is a benign condition for Dart line-coverage output. The original had
#    `2>/dev/null || cp "$LCOV_RAW" "$LCOV_FILTERED"`, so that exit SILENTLY
#    replaced the filtered file with the unfiltered one and the gate measured
#    raw coverage while reporting it as filtered.
#
# The fallback is deliberately gone. A filter that cannot run is a broken gate,
# and a broken gate must fail loudly rather than quietly measure the wrong
# thing.
if ! lcov --remove "$LCOV_RAW" \
  '*.g.dart' \
  '*/l10n/generated/*' \
  --output-file "$LCOV_FILTERED" \
  --ignore-errors unused,empty; then
  echo "::error::lcov --remove failed; refusing to gate on an unfiltered report"
  exit 1
fi

# Prove the filter actually applied rather than trusting lcov's exit code.
if grep -qE '\.g\.dart|/l10n/generated/' "$LCOV_FILTERED"; then
  echo "::error::generated code survived the filter — check the --remove patterns"
  grep -oE 'SF:.*(\.g\.dart|/l10n/generated/.*)' "$LCOV_FILTERED" | head -5
  exit 1
fi

# Pull the line-coverage percentage out of the lcov summary (format is stable
# across lcov 1.x/2.x: "  lines......: NN.N% (X of Y lines)").
SUMMARY="$(lcov --summary "$LCOV_FILTERED" --ignore-errors empty 2>/dev/null)"
PCT="$(printf '%s\n' "$SUMMARY" | grep -iE 'lines' | grep -oE '[0-9]+(\.[0-9]+)?%' | head -1 | tr -d '%')"

if [[ -z "$PCT" ]]; then
  echo "::error::could not parse coverage percentage from lcov summary"
  printf '%s\n' "$SUMMARY"
  exit 1
fi

echo "──────────────────────────────────────────────"
echo "Filtered line coverage: ${PCT}%   (floor: ${MIN_COVERAGE}%)"
echo "──────────────────────────────────────────────"
# GitHub job-summary line (no-op locally).
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "**Line coverage (generated code excluded): ${PCT}%** — floor ${MIN_COVERAGE}%" >> "$GITHUB_STEP_SUMMARY"
fi

# Gate: fail if PCT < MIN_COVERAGE (float-aware compare via awk).
if ! awk -v p="$PCT" -v m="$MIN_COVERAGE" 'BEGIN { exit !((p + 0) >= (m + 0)) }'; then
  echo "::error::coverage ${PCT}% is below the floor ${MIN_COVERAGE}%"
  exit 1
fi
