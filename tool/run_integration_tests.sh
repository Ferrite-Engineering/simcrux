#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0

# Run integration tests one file at a time.
#
# Why this script exists:
#
# `flutter test integration_test/<dir>/` on desktop (macOS, Linux, Windows)
# does not reliably run more than one integration_test file per invocation.
# After the first file completes, subsequent files fail with:
#
#   "Error waiting for a debug connection: The log reader stopped
#   unexpectedly, or never started."
#
# `flutter_tools` does not cleanly tear down the observatory connection
# between integration_test files inside a single `flutter test`
# invocation. This script works around that by invoking `flutter test`
# once per file, accumulating pass/fail counts, and printing a final
# summary.
#
# SimCrux-specific: the macOS app-relaunch race.
#
# `integration_test/PENDING.md` documents it — running the whole directory in
# one invocation relaunches the app per file and macOS frequently fails the
# rapid relaunch with "Unable to start the app on the device". That is
# environmental, not a test failure, so this script RETRIES it rather than
# reporting a red suite. PENDING.md called a retry-on-race loop "the reliable
# driver until the device-mode runs are wired into CI"; this is it, and CI is
# now wired.
#
# Only the relaunch signature is retried. A genuine assertion failure is
# reported on the first attempt, because retrying a real failure until it
# passes is how a flaky suite becomes a lying one.
#
# SimCrux has no FFI decode path, so unlike WaveCrux's copy `--clean` is NOT
# the default here — the reuse-hang that forces it there does not apply.
#
# Usage:
#
#   tool/run_integration_tests.sh                       # all tests
#   tool/run_integration_tests.sh workspace             # one subdirectory
#   tool/run_integration_tests.sh workspace diagnostics # multiple subdirs
#   tool/run_integration_tests.sh -d linux              # device override
#   tool/run_integration_tests.sh --clean workspace     # force a clean rebuild between files
#
# Exits non-zero if any test fails.

set -u
set -o pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

DEVICE="macos"
# Default: clean between tests. Necessary for the FFI-heavy decoder suite,
# which hangs on a reused build bundle (see problem (b) in the header).
# `--no-clean` is a safe, faster opt-in for suites that don't exercise the
# FFI decode path (workspace, diagnostics).
CLEAN_BETWEEN=0
SUBDIRS=()

while (("$#")); do
  case "$1" in
    -d|--device)
      DEVICE="$2"
      shift 2
      ;;
    --no-clean)
      CLEAN_BETWEEN=0
      shift
      ;;
    --clean)
      CLEAN_BETWEEN=1
      shift
      ;;
    -h|--help)
      sed -n '1,/^# Usage:/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      SUBDIRS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#SUBDIRS[@]} -eq 0 ]]; then
  # No subdirs specified → discover them.
  while IFS= read -r dir; do
    SUBDIRS+=("$(basename "$dir")")
    # `web` holds web-only integration tests (run separately on -d chrome via
    # tool/run_web_integration_tests.sh). They cannot build for a desktop/mobile
    # device, so exclude them from the default discovery here.
  done < <(find integration_test -mindepth 1 -maxdepth 1 -type d ! -name helpers ! -name web | sort)
fi

# ── Collect test files ───────────────────────────────────────────────────────

TEST_FILES=()
for sub in "${SUBDIRS[@]}"; do
  while IFS= read -r f; do
    TEST_FILES+=("$f")
  done < <(find "integration_test/$sub" -name '*_test.dart' -type f | sort)
done

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
  echo "No integration test files found under: ${SUBDIRS[*]}" >&2
  exit 1
fi

echo "Running ${#TEST_FILES[@]} integration test file(s) on device '$DEVICE'..."
echo

# ── Run each file individually ───────────────────────────────────────────────

PASSED=()
RETRIED=()
FAILED=()
TOTAL=${#TEST_FILES[@]}
INDEX=0

# Per-file log directory so failed tests' full stack traces survive even
# when the script's stdout is piped through `tail` or otherwise truncated.
LOG_DIR="build/integration_test_logs"
mkdir -p "$LOG_DIR"
echo "Per-file logs: $LOG_DIR/"
echo

for f in "${TEST_FILES[@]}"; do
  INDEX=$((INDEX + 1))
  printf '── [%d/%d] %s ' "$INDEX" "$TOTAL" "$f"
  printf '%*s\n' $((72 - ${#f})) '' | tr ' ' '─'

  if [[ $CLEAN_BETWEEN -eq 1 ]]; then
    # `flutter clean` between tests forces a fresh build bundle for each
    # invocation. Without this, the macOS embedder inherits accessibility
    # / semantics state from the previous run and the next test trips
    # `_verifySemanticsHandlesWereDisposed` at teardown.
    flutter clean >/dev/null 2>&1
    flutter pub get >/dev/null 2>&1
  fi

  # `flutter clean` above removes the entire `build/` tree — including this
  # log directory created before the loop. Recreate it here so the `tee`
  # below does not fail; under `set -o pipefail` a failed `tee` would flip
  # the pipeline's exit status and make every passing test be counted as a
  # failure.
  mkdir -p "$LOG_DIR"

  # Compute a flat log filename from the test path (slashes → underscores).
  log_name=$(echo "$f" | tr '/' '_').log

  # Retry ONLY the macOS relaunch race (PENDING.md). Everything else is
  # reported on its first attempt — retrying a genuine failure until it
  # passes is how a flaky suite becomes a lying one.
  attempt=0
  max_attempts=3
  while :; do
    attempt=$((attempt + 1))
    if flutter test "$f" -d "$DEVICE" 2>&1 | tee "$LOG_DIR/$log_name"; then
      PASSED+=("$f")
      break
    fi
    if grep -qE 'Unable to start the app on the device|Error waiting for a debug connection' "$LOG_DIR/$log_name" \
       && [[ $attempt -lt $max_attempts ]]; then
      echo "   ↻ relaunch race (attempt $attempt/$max_attempts) — retrying"
      RETRIED+=("$f")
      sleep 5
      continue
    fi
    FAILED+=("$f")
    break
  done
  echo
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo "════════════════════════════════════════════════════════════════════════════════"
echo "Integration test summary"
echo "────────────────────────────────────────────────────────────────────────────────"
echo "Passed: ${#PASSED[@]} / ${#TEST_FILES[@]}"
echo "Failed: ${#FAILED[@]}"
if [[ ${#RETRIED[@]} -gt 0 ]]; then
  # Surfaced, not swallowed: a rising count here means the race is getting
  # worse and deserves attention even while the suite stays green.
  echo "Retried past the relaunch race: ${#RETRIED[@]}"
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo
  echo "Failed tests:"
  for f in "${FAILED[@]}"; do
    echo "  ✗ $f"
  done
  exit 1
fi
echo
echo "All integration tests passed."
exit 0
