#!/usr/bin/env bash
# Sourced by scripts/deploy_web.sh; not run on its own. The desktop release
# scripts in the Pro overlay carry the same file.
#
# Fills the About dialog's build facts and copyright year. The product's
# lib/core/app_info/about_providers.dart reads them with
# String.fromEnvironment and shows "dev" when they are absent. Each value is
# taken from the environment when the caller set it and is otherwise worked
# out here.
#
#   BUILD_COMMIT           short commit of the checkout
#   BUILD_ARCHITECTURE     CPU architecture of the bundle
#   BUILD_FLUTTER_VERSION  Flutter SDK version, e.g. 3.47.7
#   BUILD_YEAR             four-digit UTC year of the build
#
# Result: those four exported, and BUILD_INFO_DEFINES, an array of the four
# --dart-define arguments, always four entries.

: "${BUILD_COMMIT:=$(git rev-parse --short=7 HEAD 2>/dev/null || true)}"
: "${BUILD_ARCHITECTURE:=$(uname -m 2>/dev/null || true)}"
: "${BUILD_YEAR:=$(date -u +%Y)}"
if [[ -z "${BUILD_FLUTTER_VERSION:-}" ]]; then
  BUILD_FLUTTER_VERSION="$(flutter --version --machine 2>/dev/null |
    sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' | head -n 1 || true)"
fi
BUILD_COMMIT="${BUILD_COMMIT:0:7}" # a caller may pass the full sha
export BUILD_COMMIT BUILD_ARCHITECTURE BUILD_FLUTTER_VERSION BUILD_YEAR

BUILD_INFO_DEFINES=(
  "--dart-define=BUILD_COMMIT=$BUILD_COMMIT"
  "--dart-define=BUILD_ARCHITECTURE=$BUILD_ARCHITECTURE"
  "--dart-define=BUILD_FLUTTER_VERSION=$BUILD_FLUTTER_VERSION"
  "--dart-define=BUILD_YEAR=$BUILD_YEAR"
)
echo "=== Build info: commit=${BUILD_COMMIT:-none} arch=${BUILD_ARCHITECTURE:-none} flutter=${BUILD_FLUTTER_VERSION:-none} year=$BUILD_YEAR ==="
