// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The formal counters, fired on the real code path: the regression runner
// at the end of a run, the CI runner, the WaveCrux hand-off's origin, and the
// pure helpers they share. Every assertion reads what production code handed
// a RecordingTelemetryService, never a hand-built event.

import 'dart:async';
import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/telemetry/formal_telemetry.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../support/poll_until.dart';
import '../../support/recording_telemetry_service.dart';
import 'catalog_events_test.dart' show expectMatchesCatalog;

/// The metrics each test id reports, by id.
final Map<String, Map<String, String>> _metricsById = {
  'proofs/handshake_prove': {
    'formal.tool': 'sby',
    'formal.verdict': 'PASS',
    'formal.mode': 'prove',
    'formal.engine': 'smtbmc',
    'formal.properties': '3',
    'formal.properties_failed': '0',
    'formal.properties_undecided': '0',
  },
  'proofs/handshake_bug': {
    'formal.tool': 'sby',
    'formal.verdict': 'FAIL',
    'formal.mode': 'prove',
    'formal.engine': 'smtbmc',
    'formal.properties': '3',
    'formal.properties_failed': '1',
    'formal.properties_undecided': '2',
  },
  'proofs/fifo_pdr': {
    'formal.tool': 'sby',
    'formal.verdict': 'UNKNOWN',
    'formal.mode': 'prove',
    'formal.engine': 'abc',
    'formal.assertions_disabled': 'noassert',
  },
  // The SVA diagnostic and the pre-trace marker (their own run).
  'diag/temporal_slang': {
    'formal.tool': 'sby',
    'formal.verdict': 'ERROR',
    'formal.frontend': 'slang',
    'formal.not_run_reason': 'sva_unsupported',
    'formal.sva.class': 'implication',
    'formal.sva.construct': '|=>',
    'formal.sva.location': 'rtl/handshake.sv:42',
  },
  'diag/temporal_slang_again': {
    'formal.tool': 'sby',
    'formal.verdict': 'ERROR',
    'formal.frontend': 'slang',
    'formal.not_run_reason': 'sva_unsupported',
    'formal.sva.class': 'implication',
    'formal.sva.construct': '|->',
    'formal.sva.location': 'rtl/other.sv:7',
  },
  'diag/drain_cover': {
    'formal.tool': 'sby',
    'formal.verdict': 'PASS',
    'formal.mode': 'cover',
    'formal.engine': 'smtbmc',
    'formal.frontend': 'slang',
    'formal.pretrace.kind': 'cover',
    'formal.pretrace.depth': '4',
    'formal.pretrace.step': '2',
    'formal.pretrace.location': 'rtl/fifo.sv:47',
  },
  // An EQY run, as the eqy driver records it (its own run).
  'equiv/alu_pass': {
    'formal.tool': 'eqy',
    'formal.verdict': 'FAIL',
    'formal.mode': 'equiv',
    'formal.engine': 'smtbmc',
    'formal.solver': 'yices',
    'formal.properties': '3',
    'formal.properties_failed': '1',
    'formal.properties_undecided': '0',
    'formal.property.0.kind': 'partition',
    'formal.property.0.label': 'alu.z',
    'formal.property.0.status': 'counterexample',
  },
};

class _FormalDriver implements SimulatorDriver {
  @override
  String get id => 'sby';

  @override
  String get displayName => 'Fake sby';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final metrics = _metricsById[request.test.id]!;
    final pass = metrics['formal.verdict'] == 'PASS';
    yield TestExecutionFinished(
      status: pass ? TestStatus.pass : TestStatus.fail,
      exitCode: pass ? 0 : 2,
      startedAt: DateTime.now().toUtc(),
      finishedAt: DateTime.now().toUtc(),
      metrics: metrics,
    );
  }

  @override
  void cancel(String testId) {}
}

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'sby',
  top: id.split('/').last,
);

TestResult _result(String id, Map<String, String> metrics) => TestResult(
  testId: id,
  runId: 'r',
  status: TestStatus.pass,
  startedAt: DateTime.utc(2026),
  finishedAt: DateTime.utc(2026),
  metrics: metrics,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the regression runner records the formal counters', () {
    late Directory tmp;
    late RecordingTelemetryService telemetry;
    late ProviderContainer container;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('simcrux_formal_events_');
      telemetry = RecordingTelemetryService();
      container = ProviderContainer(
        overrides: [
          telemetryServiceProvider.overrideWithValue(telemetry),
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'sby': _FormalDriver()}),
          ),
          trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
        ],
      );
    });

    tearDown(() async {
      container.dispose();
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup.
      }
    });

    Future<void> runSuite(String suite) async {
      final finished = Completer<void>();
      container.listen<AsyncValue<RegressionRunState?>>(
        regressionRunnerProvider,
        (_, next) {
          final value = next.value;
          if (value != null && value.isFinished && !finished.isCompleted) {
            finished.complete();
          }
        },
      );
      await container
          .read(regressionRunnerProvider.notifier)
          .start(
            RegressionConfig(
              projectFilePath: '/proj/simcrux.yaml',
              schemaVersion: '1',
              suites: [
                Suite(
                  name: suite,
                  tests: [
                    for (final id in _metricsById.keys)
                      if (id.startsWith('$suite/')) _spec(id),
                  ],
                ),
              ],
              simulatorBinaries: const {},
            ),
          );
      await finished.future;
    }

    test('one formal.sva.unsupported per (construct, frontend) and one '
        'formal.pretrace.flagged per kind, with nothing of the user', () async {
      await runSuite('diag');
      await pollUntil(
        () => telemetry.named('formal.pretrace.flagged').isNotEmpty,
      );
      final sva = telemetry.named('formal.sva.unsupported').single;
      expect(sva.properties, <String, Object?>{
        'construct': 'implication',
        'frontend': 'slang',
      });
      expectMatchesCatalog(sva);
      final pretrace = telemetry.named('formal.pretrace.flagged').single;
      expect(pretrace.properties, <String, Object?>{'kind': 'cover'});
      expectMatchesCatalog(pretrace);
      for (final event in [sva, pretrace]) {
        final values = event.properties.values.join(' ');
        expect(values, isNot(contains('.sv')), reason: 'no file or line');
        expect(values, isNot(contains('|')), reason: 'no construct text');
      }
    });

    test('one formal.run.completed per (tool, mode, engine), counts summed, '
        'and one formal.assertions.disabled', () async {
      await runSuite('proofs');
      await pollUntil(
        () => telemetry.named('formal.run.completed').length == 2,
      );

      final runs = telemetry.named('formal.run.completed');
      final smtbmc = runs.singleWhere(
        (e) => e.properties['engine'] == 'smtbmc',
      );
      expect(smtbmc.properties, <String, Object?>{
        'tool': 'sby',
        'mode': 'prove',
        'engine': 'smtbmc',
        'frontend': 'unknown',
        // smtbmc with no solver named runs its default, yices.
        'solver': 'yices',
        'properties': 6,
        'failed': 1,
        'undecided': 2,
      });
      final abc = runs.singleWhere((e) => e.properties['engine'] == 'abc');
      expect(abc.properties, <String, Object?>{
        'tool': 'sby',
        'mode': 'prove',
        'engine': 'abc',
        'frontend': 'unknown',
        'solver': 'abc',
      }, reason: 'no status was read, so no counts are claimed');
      runs.forEach(expectMatchesCatalog);

      final disabled = telemetry.named('formal.assertions.disabled').single;
      expect(disabled.properties, <String, Object?>{'how': 'noassert'});
      expectMatchesCatalog(disabled);

      for (final event in runs) {
        expect(event.properties.length, lessThanOrEqualTo(8));
      }
    });

    test('an EQY run is formal.run.completed{tool: eqy, mode: equiv} with '
        'its partitions counted, and nothing of the design', () async {
      await runSuite('equiv');
      await pollUntil(() => telemetry.named('formal.run.completed').isNotEmpty);
      final run = telemetry.named('formal.run.completed').single;
      expect(run.properties, <String, Object?>{
        'tool': 'eqy',
        'mode': 'equiv',
        'engine': 'smtbmc',
        'frontend': 'unknown',
        'solver': 'yices',
        'properties': 3,
        'failed': 1,
        'undecided': 0,
      });
      expectMatchesCatalog(run);
      expect(run.properties.values.join(' '), isNot(contains('alu')));
    });
  });

  group('the helpers', () {
    test('a run with no formal row records nothing', () {
      expect(
        formalRunCompletedProperties([
          _result('a/b', const {'sim.cycles': '10'}),
        ]),
        isEmpty,
      );
      expect(
        formalAssertionsDisabledTokens([_result('a/b', const {})]),
        isEmpty,
      );
    });

    test('an engine outside the vocabulary is other, a mode outside it is '
        'left out', () {
      final props = formalRunCompletedProperties([
        _result('a/b', const {
          'formal.tool': 'sby',
          'formal.verdict': 'PASS',
          'formal.mode': 'weird',
          'formal.engine': 'btormc',
        }),
      ]).single;
      expect(props['engine'], 'other');
      expect(props.containsKey('mode'), isFalse);
    });

    test('a RISC-V row reports riscv_formal', () {
      final props = formalRunCompletedProperties([
        _result('a/b', const {
          'riscv.formal.verdict': 'PASS',
          'riscv.formal.proof_mode': 'bmc',
          'riscv.formal.engine': 'smtbmc boolector',
        }),
      ]).single;
      expect(props['tool'], 'riscv_formal');
      expect(props['mode'], 'bmc');
      expect(props['engine'], 'smtbmc');
    });

    test('frontend and solver: one token per row, unknown and mixed when the '
        "group's rows disagree", () {
      Map<String, Object?> one(Map<String, String> metrics) =>
          formalRunCompletedProperties([_result('a/b', metrics)]).single;
      const base = {'formal.tool': 'sby', 'formal.verdict': 'PASS'};
      expect(one({...base, 'formal.engine': 'smtbmc'})['solver'], 'yices');
      expect(
        one({
          ...base,
          'formal.engine': 'smtbmc',
          'formal.solver': '--nopresat boolector',
        })['solver'],
        'boolector',
      );
      expect(
        one({...base, 'formal.engine': 'smtbmc', 'formal.solver': 'z3'}),
        containsPair('solver', 'z3'),
      );
      expect(
        one({...base, 'formal.engine': 'aiger', 'formal.solver': 'rIC3'}),
        containsPair('solver', 'ric3'),
      );
      expect(
        one({...base, 'formal.engine': 'aiger', 'formal.solver': 'avy'}),
        containsPair('solver', 'other'),
      );
      expect(
        one({...base, 'formal.engine': 'abc', 'formal.solver': 'pdr'}),
        containsPair('solver', 'abc'),
      );
      expect(one(base)['solver'], 'none');
      expect(one(base)['frontend'], 'unknown');
      expect(
        one({...base, 'formal.frontend': 'verific'}),
        containsPair('frontend', 'verific'),
      );
      // A RISC-V row: the solver is the rest of its engine line.
      expect(
        one(const {
          'riscv.formal.verdict': 'PASS',
          'riscv.formal.engine': 'smtbmc bitwuzla',
        }),
        containsPair('solver', 'bitwuzla'),
      );

      final mixed = formalRunCompletedProperties([
        _result('a/b', {
          ...base,
          'formal.engine': 'smtbmc',
          'formal.solver': 'yices',
          'formal.frontend': 'slang',
        }),
        _result('a/c', {
          ...base,
          'formal.engine': 'smtbmc',
          'formal.solver': 'boolector',
          'formal.frontend': 'builtin',
        }),
      ]).single;
      expect(mixed['solver'], 'mixed');
      expect(mixed['frontend'], 'unknown');
      expect(
        mixed.keys,
        unorderedEquals(['tool', 'engine', 'frontend', 'solver']),
      );
    });

    test('counts are clamped to the Worker ceiling', () {
      final props = formalRunCompletedProperties([
        _result('a/b', {
          'formal.tool': 'sby',
          'formal.verdict': 'PASS',
          'formal.properties': '${kTelemetryMaxCount + 5}',
        }),
      ]).single;
      expect(props['properties'], kTelemetryMaxCount);
    });

    test('the SVA and pre-trace helpers read only the closed vocabularies', () {
      expect(
        formalSvaUnsupportedProperties([
          _result('a/b', const {
            'formal.verdict': 'ERROR',
            'formal.sva.class': 'delay',
            'formal.frontend': 'builtin',
          }),
          _result('a/c', const {
            'formal.verdict': 'ERROR',
            'formal.sva.class': 'delay',
            'formal.frontend': 'verific',
          }),
          _result('a/d', const {
            'formal.verdict': 'ERROR',
            'formal.sva.class': 'not_a_class',
            'formal.frontend': 'slang',
          }),
        ]),
        <Map<String, Object?>>[
          {'construct': 'delay', 'frontend': 'builtin'},
        ],
      );
      expect(
        formalPretraceFlaggedKinds([
          _result('a/b', const {
            'formal.verdict': 'FAIL',
            'formal.pretrace.kind': 'assert',
            'formal.pretrace.depth': '1',
            'formal.pretrace.step': '1',
          }),
          _result('a/c', const {'formal.verdict': 'PASS'}),
        ]),
        {'assert'},
      );
      for (final token in ['builtin', 'slang']) {
        expect(kFormalSvaFrontendTokens, contains(token));
      }
      expect(kFormalSvaConstructTokens, hasLength(8));
    });

    test('the hand-off origin follows the row', () {
      expect(debugInWaveCruxOrigin(null), 'test');
      expect(debugInWaveCruxOrigin(_result('a/b', const {})), 'test');
      expect(
        debugInWaveCruxOrigin(
          _result('a/b', const {
            'formal.tool': 'sby',
            'formal.verdict': 'FAIL',
          }),
        ),
        'formal',
      );
      expect(
        debugInWaveCruxOrigin(
          _result('a/b', const {
            'formal.tool': 'eqy',
            'formal.verdict': 'FAIL',
          }),
        ),
        'eqy',
      );
      for (final token in ['test', 'formal', 'eqy']) {
        expect(kDebugInWaveCruxOriginTokens, contains(token));
      }
    });
  });

  test('the catalog lists the formal events at eight properties or '
      'fewer', () {
    for (final name in const [
      'formal.run.completed',
      'formal.import.completed',
      'formal.assertions.disabled',
      'formal.sva.unsupported',
      'formal.pretrace.flagged',
    ]) {
      final entry = kSimcruxEventCatalog.singleWhere((e) => e.name == name);
      expect(entry.propertyKeys.length, lessThanOrEqualTo(8), reason: name);
    }
    final run = kSimcruxEventCatalog.singleWhere(
      (e) => e.name == 'formal.run.completed',
    );
    expect(run.propertyKeys.toSet(), {
      'tool',
      'mode',
      'engine',
      'frontend',
      'solver',
      'properties',
      'failed',
      'undecided',
    });
  });
}
