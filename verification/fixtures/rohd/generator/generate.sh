#!/bin/sh
# Regenerates the ROHD fixtures from pinned sources.
#
#   generate.sh <empty-work-dir> <fixture-dir> <file>...
#
# Builds the small design in this directory against the ROHD commits pinned in
# pubspec.yaml.txt, runs it, and copies the named outputs into <fixture-dir>:
#
#   top.sv          SystemVerilog with inline "// ROHD:" source comments
#   Top.flc.json    FLC v6 source-trace sidecar
#   top.vcd         waveform written by WaveDumper
#   dart-test.json  `dart test --file-reporter json` over probe_test.dart
#   per_module/...  the same design written one module per file, with its sidecar
#
# Machine-specific absolute paths are rewritten to /work/rohd_fixture and
# /pub-cache so the committed files are reproducible. Needs network access
# the first time (git dependencies) and the Dart SDK on PATH.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
dest=$2
shift 2

mkdir -p "$work/lib" "$work/bin" "$work/test" "$dest"
work=$(cd "$work" && pwd)
dest=$(cd "$dest" && pwd)
cp "$here/pubspec.yaml.txt" "$work/pubspec.yaml"
cp "$here/design.dart.txt" "$work/lib/design.dart"
cp "$here/probe.dart.txt" "$work/bin/probe.dart"
cp "$here/probe_test.dart.txt" "$work/test/probe_test.dart"

cd "$work"
dart pub get
dart run bin/probe.dart out
# A failing run is the point: two of the four tests fail on purpose.
dart test --reporter silent --file-reporter json:out/dart-test.json || true

cache=${PUB_CACHE:-$HOME/.pub-cache}
for f in "$@"; do
  mkdir -p "$(dirname "$dest/$f")"
  sed -e "s#$work#/work/rohd_fixture#g" -e "s#$cache#/pub-cache#g" \
    "out/$f" > "$dest/$f"
done
