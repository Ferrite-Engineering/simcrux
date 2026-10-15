// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_guards/crux_guards.dart';
import 'package:flutter_test/flutter_test.dart';

import 'crux_guard_sources.dart';

// The app never ends its own process with `dart:io`'s `exit`. That exit runs
// no Dart, so the unclean-shutdown detector's session marker stayed on disk
// and the next launch counted a normal Quit as a crash. Every quit path calls
// `cruxExit` from crux_telemetry, which removes the marker first. The scanner
// is crux_guards' `cruxAuditProcessExit`; a direct `exit` that is right for a
// reason the scan cannot see goes in `exemptions:` with that reason.

void main() {
  test('no quit path ends the process without marking a clean exit', () {
    final result = cruxAuditProcessExit(sources: cruxGuardSourcesUnder('lib'));

    expect(result.filesScanned, greaterThan(100));
    expect(result.isClean, isTrue, reason: result.describe());
  });
}
