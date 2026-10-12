#!/usr/bin/env bash
# Copyright 2026 Ferrite Engineering LLC
# SPDX-License-Identifier: Apache-2.0
#
# Open-core copy of the release gate the desktop builds run. Here it guards
# the release paths that ship this repository's own build: scripts/deploy_web.sh,
# .github/workflows/web-deploy.yml. They compile kBetaPeriod from the
# crux-shared this checkout pins, so a deploy from a stale pin would ship
# with the wrong tier gating. Keep the body below identical to the desktop
# copy; only this preamble differs.
#
# Release gate: refuse a release whose version disagrees with the beta flag.
#
# `kBetaPeriod` (crux_license, lib/src/beta_period.dart) opens every tier gate
# during the public beta. A 1.x release built with it still true ships every
# paid feature free, and nothing else in the pipeline notices: the build is
# green, the binary runs, the tier badges still render. A 0.x beta built with
# it false gates a beta population that was promised everything.
#
# The two facts that decide it are read from what the build itself uses,
# never from a restatement of them:
#
#   - the release line, from `version:` in this repo's pubspec.yaml (the line
#     release-desktop.yml's "Determine version" step reads);
#   - the value the build will compile, from the crux_license package this
#     pubspec actually resolves (a dependency_overrides entry first, then
#     dependencies) — the crux-shared pinned by the open-core submodule.
#
# The rule is by major version, so a release candidate is built exactly as
# the release it is a candidate for:
#
#   0.x.y             the public beta   kBetaPeriod must be true
#   1.0.0, 1.0.0-rc.1 production        kBetaPeriod must be false
#
# The flag reaches a release build from that source default and nothing else.
# A BETA_PERIOD define in any release build script, or in the release
# workflow, is refused outright: a define is one line per platform script and
# per CLI build, and the one that gets missed ships a free platform.
#
# Anything this cannot read or parse fails closed.
#
# Usage:
#   scripts/check_beta_period.sh               refuse a mismatch
#   scripts/check_beta_period.sh --advisory    report a mismatch, exit 0
#   scripts/check_beta_period.sh --root <dir>  check another checkout
#   scripts/check_beta_period.sh --print-flag  print the compiled default
#                                              (true|false) and exit 0
#
# --print-flag is how scripts/_require_beta_expiry.sh decides whether a
# BETA_EXPIRY date is needed at all: it reads the flag exactly as this gate
# does, and still exits 2 when the flag cannot be read.
#
# --advisory is for a verification build that will not be published, so the
# pipeline can be exercised at a new version before the flip lands.
#
# Exit codes: 0 consistent (or --advisory), 1 mismatch refused, 2 could not
# determine the flag or the version (fatal even with --advisory), 64 usage.
set -euo pipefail

SELF="$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADVISORY=0
PRINT_FLAG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --advisory) ADVISORY=1 ;;
    --print-flag) PRINT_FLAG=1 ;;
    --root)
      [[ $# -ge 2 ]] || { echo "$SELF: --root needs a directory" >&2; exit 64; }
      ROOT="$(cd "$2" && pwd)"
      shift
      ;;
    -h | --help)
      sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "$SELF: unknown argument '$1'" >&2; exit 64 ;;
  esac
  shift
done

in_actions() { [[ "${GITHUB_ACTIONS:-}" == "true" ]]; }

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Cannot determine: fatal in every mode, because a gate that cannot see the
# flag must not wave the release through.
undetermined() {
  if in_actions; then
    echo "::error title=Beta flag unreadable::$1"
  fi
  echo "error: $1" >&2
  summary "### :x: Release blocked — the beta flag could not be read" "" "$1"
  exit 2
}

PUBSPEC="$ROOT/pubspec.yaml"
[[ -f "$PUBSPEC" ]] || undetermined "no pubspec.yaml at $ROOT."

# ── The release line ──────────────────────────────────────────────────────
VERSION="$(grep -m1 -E '^version:' "$PUBSPEC" | sed -E \
  "s/^version:[[:space:]]*//; s/[[:space:]]+#.*$//; s/[\"']//g; s/[[:space:]]*$//; s/\+.*$//" || true)"
if ! [[ "$VERSION" =~ ^([0-9]+)\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  undetermined "could not read a semver \`version:\` from $PUBSPEC (got '$VERSION')."
fi
MAJOR="${BASH_REMATCH[1]}"

# ── The crux_license package the build resolves ───────────────────────────
# Prints the `path:` of `crux_license` under the top-level YAML section $1.
pubspec_path_under() {
  awk -v want="$1" '
    /^[^[:space:]#]/ { section = $0; sub(/:.*/, "", section); inpkg = 0; next }
    section != want { next }
    /^  crux_license:[[:space:]]*(#.*)?$/ { inpkg = 1; next }
    inpkg && /^    path:/ {
      p = $0
      sub(/^    path:[[:space:]]*/, "", p)
      sub(/[[:space:]]+#.*$/, "", p)
      gsub(/["\047]/, "", p)
      sub(/[[:space:]]*$/, "", p)
      print p
      exit
    }
    inpkg && /^  [^[:space:]]/ { inpkg = 0 }
  ' "$PUBSPEC"
}

LICENSE_PATH="$(pubspec_path_under dependency_overrides)"
[[ -n "$LICENSE_PATH" ]] || LICENSE_PATH="$(pubspec_path_under dependencies)"
[[ -n "$LICENSE_PATH" ]] || undetermined \
  "$PUBSPEC declares no path dependency on crux_license, so the flag's source cannot be located."
case "$LICENSE_PATH" in
  /*) LICENSE_DIR="$LICENSE_PATH" ;;
  *) LICENSE_DIR="$ROOT/${LICENSE_PATH#./}" ;;
esac

SOURCE="$LICENSE_DIR/lib/src/beta_period.dart"
[[ -f "$SOURCE" ]] || undetermined \
  "$SOURCE does not exist. Check out the submodules recursively — the flag's default lives in the pinned crux-shared."
SOURCE_SHOWN="${SOURCE#"$ROOT"/}"

PIN=""
CRUX_SHARED="$(cd "$LICENSE_DIR/../.." && pwd)"
if [[ -e "$CRUX_SHARED/.git" ]]; then
  PIN="$(git -C "$CRUX_SHARED" rev-parse --short=12 HEAD 2>/dev/null || true)"
fi
FROM="$SOURCE_SHOWN${PIN:+ (crux-shared $PIN)}"

# ── The flag's compiled default ───────────────────────────────────────────
# Line comments are dropped and the file joined onto one line, so the
# declaration may wrap however the formatter likes. Two shapes are accepted;
# any other fails closed rather than being guessed at.
CODE="$(sed -E 's://.*$::' "$SOURCE" | tr '\n' ' ')"
RE_DEFINE="const[[:space:]]+bool[[:space:]]+kBetaPeriod[[:space:]]*=[[:space:]]*bool\.fromEnvironment\([[:space:]]*['\"]BETA_PERIOD['\"][[:space:]]*(,[[:space:]]*defaultValue:[[:space:]]*(true|false)[[:space:]]*)?,?[[:space:]]*\)[[:space:]]*;"
RE_CONST="const[[:space:]]+bool[[:space:]]+kBetaPeriod[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*;"
if [[ "$CODE" =~ $RE_DEFINE ]]; then
  # bool.fromEnvironment without a defaultValue compiles to false.
  FLAG="${BASH_REMATCH[2]:-false}"
elif [[ "$CODE" =~ $RE_CONST ]]; then
  FLAG="${BASH_REMATCH[1]}"
else
  undetermined "could not find the kBetaPeriod declaration in $FROM. It must be \`const bool kBetaPeriod = bool.fromEnvironment('BETA_PERIOD', defaultValue: <true|false>);\` or \`const bool kBetaPeriod = <true|false>;\` — update scripts/$SELF if the declaration changed shape deliberately."
fi

if [[ "$PRINT_FLAG" -eq 1 ]]; then
  echo "$FLAG"
  exit 0
fi

# ── Defines in the release build ──────────────────────────────────────────
# Every file a release build runs: the per-platform scripts, the CLI build
# scripts, and the workflow's own inline commands. Comment lines are skipped.
SCANNED=()
for f in "$ROOT"/scripts/*.sh "$ROOT"/scripts/*.ps1 "$ROOT"/tool/*.sh \
  "$ROOT"/.github/workflows/release-desktop.yml; do
  [[ -f "$f" ]] || continue
  [[ "$(basename "$f")" == "$SELF" ]] && continue
  SCANNED+=("$f")
done
DEFINES=""
if [[ ${#SCANNED[@]} -gt 0 ]]; then
  DEFINES="$(grep -n -H -E \
    "(--dart-define|--define|-D)[= ]*[\"']?BETA_PERIOD|dart-define-from-file" \
    "${SCANNED[@]}" | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  DEFINES="${DEFINES//"$ROOT"\//}"
fi

# ── Decide ────────────────────────────────────────────────────────────────
if [[ "$MAJOR" -ge 1 ]]; then
  LINE="production"
  WANT="false"
else
  LINE="the public beta"
  WANT="true"
fi

PROBLEMS=()
if [[ -n "$DEFINES" ]]; then
  PROBLEMS+=("The release build passes a BETA_PERIOD define (or a define file this check cannot see into): $(echo "$DEFINES" | tr '\n' ';' | sed 's/;$//'). A release takes kBetaPeriod from the default in $FROM and from nothing else, because a define has to be repeated in every platform script and every CLI build, and the one that is missed ships a free platform. Remove it and flip the default instead.")
fi
if [[ "$FLAG" != "$WANT" ]]; then
  if [[ "$WANT" == "false" ]]; then
    PROBLEMS+=("$VERSION is a production release, but kBetaPeriod would be true: $FROM still defaults BETA_PERIOD to true, so every tier gate would short-circuit and every paid feature would ship free. Flip the default to false in crux-shared, move the crux-shared pin in the open core and in this overlay to that commit, and dispatch again.")
  else
    PROBLEMS+=("$VERSION is a 0.x beta release, but kBetaPeriod would be false: $FROM defaults BETA_PERIOD to false, the production setting, so the beta's paid features would be gated for users promised all of them. Release it as 1.0.0 or later, or move the crux-shared pin back to a commit where the beta is on.")
  fi
fi

if [[ ${#PROBLEMS[@]} -eq 0 ]]; then
  echo "Beta flag OK: $VERSION is $LINE, and kBetaPeriod defaults to $FLAG in $FROM, with no BETA_PERIOD define in the release build."
  summary "- Beta flag: \`$VERSION\` is $LINE; \`kBetaPeriod\` = \`$FLAG\` from \`$FROM\`."
  exit 0
fi

if [[ "$ADVISORY" -eq 1 ]]; then
  for p in "${PROBLEMS[@]}"; do
    if in_actions; then echo "::warning title=Beta flag::$p"; fi
    echo "warning: $p" >&2
  done
  echo "warning: not refused, because this is a verification build; a publishing run at this commit would be refused." >&2
  summary "### :warning: The beta flag disagrees with the version" "" "${PROBLEMS[@]}" "" \
    "Not refused, because this is a verification build. A publishing run at this commit would be refused."
  exit 0
fi

for p in "${PROBLEMS[@]}"; do
  if in_actions; then echo "::error title=Beta flag::$p"; fi
  echo "error: $p" >&2
done
echo "error: refusing to release $VERSION." >&2
summary "### :x: Release blocked — the beta flag disagrees with the version" "" "${PROBLEMS[@]}"
exit 1
