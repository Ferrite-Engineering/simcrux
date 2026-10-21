// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/remote/services/cross_probe_selection.dart';
import 'package:simcrux/features/remote/services/debug_in_wavecrux_dispatcher.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../../../support/recording_telemetry_service.dart';

// The counterexample hand-off for a general `sby` row: the row's trace goes
// to WaveCrux through the shared cross-probe layer as a `source` element,
// with no stream coordinate yet (that is the producer's job, later), and the
// hand-off's counter says the row was a formal one.

TestResult _sbyRow({String? trace, String tool = 'sby'}) => TestResult(
  testId: 'proofs/handshake_bug',
  runId: 'r',
  status: TestStatus.fail,
  startedAt: DateTime.utc(2026, 10),
  finishedAt: DateTime.utc(2026, 10),
  waveformPath: trace,
  metrics: <String, String>{
    SbyDriver.kMetricTool: tool,
    SbyDriver.kMetricVerdict: 'FAIL',
    SbyDriver.kMetricMode: 'prove',
  },
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('Cross-probe Selection on an sby row', () {
    test('offers the counterexample trace as a source element', () {
      final selection = crossProbeSelectionForRow(
        DashboardRow(
          suiteName: 'proofs',
          testName: 'handshake_bug',
          simulatorId: SbyDriver.kId,
          result: _sbyRow(trace: '/work/prove_bug/engine_0/trace.vcd'),
        ),
      );
      expect(
        selection.candidates,
        contains(
          const ElementId(
            kind: ElementKind.source,
            path: '/work/prove_bug/engine_0/trace.vcd',
          ),
        ),
      );
    });

    test('carries the element only: no stream coordinate', () {
      final selection = crossProbeSelectionForRow(
        DashboardRow(
          suiteName: 'proofs',
          testName: 'handshake_bug',
          simulatorId: SbyDriver.kId,
          result: _sbyRow(trace: '/work/prove_bug/engine_0/trace.vcd'),
        ),
      );
      expect(
        selection.metadata.keys.where((k) => k.contains('stream')),
        isEmpty,
      );
    });

    test('a row without a trace offers no source', () {
      final selection = crossProbeSelectionForRow(
        DashboardRow(
          suiteName: 'proofs',
          testName: 'undecided',
          simulatorId: SbyDriver.kId,
          result: _sbyRow(),
        ),
      );
      expect(
        selection.candidates.where((c) => c.kind == ElementKind.source),
        isEmpty,
      );
    });
  });

  group('debug_in_wavecrux.used names the kind of row', () {
    late RecordingTelemetryService telemetry;
    late ProviderContainer container;

    setUp(() {
      telemetry = RecordingTelemetryService();
      container = ProviderContainer(
        overrides: [telemetryServiceProvider.overrideWithValue(telemetry)],
      );
    });
    tearDown(() => container.dispose());

    Future<Map<String, Object?>> dispatch(TestResult? result) async {
      await container
          .read(debugInWaveCruxDispatcherProvider)
          .dispatch(waveformPath: null, result: result);
      return telemetry.named('debug_in_wavecrux.used').last.properties;
    }

    test('formal for an sby row', () async {
      expect(await dispatch(_sbyRow()), <String, Object?>{
        'outcome': 'no_waveform',
        'origin': 'formal',
      });
    });

    test('eqy for an equivalence row', () async {
      expect((await dispatch(_sbyRow(tool: 'eqy')))['origin'], 'eqy');
    });

    test('test for a simulation row, or no row', () async {
      expect((await dispatch(null))['origin'], 'test');
      expect(
        (await dispatch(
          TestResult(
            testId: 'unit/alu',
            runId: 'r',
            status: TestStatus.pass,
            startedAt: DateTime.utc(2026),
            finishedAt: DateTime.utc(2026),
          ),
        ))['origin'],
        'test',
      );
    });
  });
}
