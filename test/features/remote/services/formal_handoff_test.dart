// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_cxp_ui/crux_cxp_ui.dart' show crossProbeElementFor;
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
// with the `formal.trace_step` coordinate the row can state (none when no
// property states a step) and never a `signal` candidate, which WaveCrux
// would prefer to the trace; "Show in NetCrux" sends the failing property's
// signal with its `formal.` keys; and the hand-off's counter says the row
// was a formal one.

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

/// [base] with a failing assertion at `fifo.sv:38`, reading [reads] when
/// given.
TestResult _withProperty(TestResult base, {String? reads}) => TestResult(
  testId: base.testId,
  runId: 'r',
  status: TestStatus.fail,
  startedAt: DateTime.utc(2026, 10),
  finishedAt: DateTime.utc(2026, 10),
  waveformPath: base.waveformPath,
  metrics: <String, String>{
    ...base.metrics,
    'formal.property.0.kind': 'ASSERT',
    'formal.property.0.location': 'fifo.sv:38.3-38.9',
    'formal.property.0.status': 'counterexample',
    'formal.property.0.label': 'a_never_over',
    'formal.property.0.reads': ?reads,
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

    test('a failing property with a stated step: the coordinate rides the '
        'selection, WaveCrux gets the trace, and no candidate is a signal', () {
      const trace = '/work/prove_bug/engine_0/trace.vcd';
      final result = TestResult(
        testId: 'proofs/handshake_bug',
        runId: 'r',
        status: TestStatus.fail,
        startedAt: DateTime.utc(2026, 10),
        finishedAt: DateTime.utc(2026, 10),
        waveformPath: trace,
        metrics: <String, String>{
          ..._sbyRow().metrics,
          'formal.property.0.kind': 'ASSERT',
          'formal.property.0.location': 'handshake_imm.sv:45.15-45.38',
          'formal.property.0.status': 'counterexample',
          'formal.property.0.step': '6',
          'formal.property.0.trace': 'engine_0/trace.vcd',
          'formal.property.0.reads': 'handshake.f_wait,handshake.rst',
        },
      );
      final selection = crossProbeSelectionForRow(
        DashboardRow(
          suiteName: 'proofs',
          testName: 'handshake_bug',
          simulatorId: SbyDriver.kId,
          result: result,
        ),
        designId: 'd1',
      );
      expect(selection.coordinate?.streamId, 'formal.trace_step');
      expect(selection.coordinate?.sequenceIndex, 6);
      expect(selection.metadata['formal.property_kind'], 'assert');
      expect(selection.metadata[cxpDesignIdMetadataKey], 'd1');
      expect(
        selection.candidates.where((c) => c.kind == ElementKind.signal),
        isEmpty,
      );
      expect(
        crossProbeElementFor(
          selection,
          const PeerIdentity(
            peerId: 'wavecrux-1-1',
            productName: 'wavecrux',
            productVersion: '1.2.0',
          ),
        ),
        const ElementId(kind: ElementKind.source, path: trace),
      );

      // "Show in NetCrux": each signal the property reads, nearest first,
      // with the keys that make NetCrux draw its fan-in; the property itself
      // last.
      final attempts = formalShowInNetCruxAttempts(result, designId: 'd1');
      expect(
        [for (final a in attempts) a.candidates.single],
        const <ElementId>[
          ElementId(kind: ElementKind.signal, path: 'handshake.f_wait'),
          ElementId(kind: ElementKind.signal, path: 'handshake.rst'),
          ElementId(kind: ElementKind.property, path: 'handshake_imm.sv:45'),
        ],
      );
      for (final attempt in attempts) {
        expect(attempt.metadata['formal.property_kind'], 'assert');
        expect(attempt.metadata[cxpDesignIdMetadataKey], 'd1');
      }
      const netcruxPeer = PeerIdentity(
        peerId: 'netcrux-1-1',
        productName: 'netcrux',
        productVersion: '1.2.0',
      );
      expect(
        [
          for (final a in attempts) crossProbeElementFor(a, netcruxPeer)!.kind,
        ],
        const <ElementKind>[
          ElementKind.signal,
          ElementKind.signal,
          ElementKind.property,
        ],
      );
    });

    test('Show in NetCrux without a known signal sends the property', () {
      final result = _sbyRow(trace: '/w/engine_0/trace.vcd');
      expect(formalShowInNetCruxAttempts(result), isEmpty);
      expect(formalShowInNetCruxSignals(result), isEmpty);
      final withProperty = _withProperty(result);
      final attempts = formalShowInNetCruxAttempts(withProperty);
      expect(
        attempts.single.candidates.single,
        const ElementId(kind: ElementKind.property, path: 'fifo.sv:38'),
      );
      expect(attempts.single.metadata['formal.property_label'], 'a_never_over');
    });

    test('Show in NetCrux offers every signal the property reads, once, '
        'for a signal that exists only under ifdef FORMAL', () {
      // `f_wait` is declared under `ifdef FORMAL`: SymbiYosys reads the file
      // with FORMAL defined and so the property reads it, but NetCrux reads
      // it without, so its netlist has no `f_wait`. The run records the
      // property's reads, and a peer that lacks the first one needs the rest.
      final result = _withProperty(
        _sbyRow(trace: '/w/engine_0/trace.vcd'),
        reads:
            ' handshake_imm.f_wait,handshake_imm.valid,, '
            'handshake_imm.f_wait,handshake_imm.ready',
      );
      expect(formalShowInNetCruxSignals(result), const <String>[
        'handshake_imm.f_wait',
        'handshake_imm.valid',
        'handshake_imm.ready',
      ]);
      final attempts = formalShowInNetCruxAttempts(result);
      expect(attempts, hasLength(4));
      expect(attempts.every((a) => a.candidates.length == 1), isTrue);
      expect(attempts.last.candidates.single.kind, ElementKind.property);
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
