// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';

void main() {
  group('crux_telemetry_headless shim', () {
    test('re-exports the pure-Dart telemetry surface the CLI closure '
        'needs', () {
      // The real Flutter-freeness proof is `tool/build_cli.sh` — a
      // `flutter test` cannot demonstrate the absence of `dart:ui` in
      // the link. What this test pins is the shim's *surface*: the
      // symbols `CiRunner` / `DashboardBundleWriter` / `SimcruxCli`
      // compile against must keep resolving through this one file, so
      // a refactor that drops an export fails here with a name, not in
      // the CLI build with an FFI-transformer stack trace.
      const TelemetryService service = NoopTelemetryService();
      expect(
        () => service.record(TelemetryEvent('test.event')),
        returnsNormally,
      );
      expect(telemetryEnumToken(_Sample.one), 'one');
    });
  });
}

enum _Sample { one }
