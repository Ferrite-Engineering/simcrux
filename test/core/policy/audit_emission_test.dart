// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_audit/crux_audit.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/policy/simcrux_policy_keys.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../support/answered_telemetry.dart';
import '../../support/poll_until.dart';

class _CapturingSink implements AuditSink {
  final List<AuditEvent> events = <AuditEvent>[];

  @override
  Future<void> record(AuditEvent event) async => events.add(event);

  @override
  Future<void> close() async {}

  @override
  AuditSinkHealth get health => AuditSinkHealth.healthy;
}

class _FakeDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    return const CompileResult(
      success: true,
      artifactPath: 'noop',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final started = DateTime.now().toUtc();
    final exitCode = request.test.id.endsWith('/fail') ? 1 : 0;
    yield TestExecutionFinished(
      status: exitCode == 0 ? TestStatus.pass : TestStatus.fail,
      exitCode: exitCode,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'icarus',
  top: 'tb',
);

RegressionConfig _config(List<TestSpec> tests) {
  final byId = <String, List<TestSpec>>{};
  for (final t in tests) {
    byId.putIfAbsent(t.suiteName, () => <TestSpec>[]).add(t);
  }
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      for (final entry in byId.entries)
        Suite(name: entry.key, tests: entry.value),
    ],
    simulatorBinaries: const {},
  );
}

void main() {
  late Directory tmp;
  late ProviderContainer container;
  late _CapturingSink sink;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_audit_test_');
    sink = _CapturingSink();
    container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _FakeDriver()}),
        ),
        trendStoreDirectoryOverrideProvider.overrideWithValue(tmp.path),
        cruxAuditSinkProvider.overrideWithValue(sink),
        cruxAuditProductIdProvider.overrideWithValue(
          SimCruxPolicyKeys.productId,
        ),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    if (tmp.existsSync()) {
      try {
        tmp.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup.
      }
    }
  });

  List<AuditEvent> ofKind(String kind) =>
      sink.events.where((e) => e.kind == kind).toList();

  /// Resolves when the run reaches a finished state.
  ///
  /// The audit line lands earlier than this — `_recordRunTerminal` fires
  /// before the runner's best-effort retention pass — so a test that tore down
  /// on the audit event alone would dispose the container underneath work that
  /// is still using its `Ref`. Waiting for the state, as every other runner
  /// test does, is what keeps the teardown honest.
  Future<void> waitForFinish() {
    final completer = Completer<void>();
    container.listen<AsyncValue<RegressionRunState?>>(
      regressionRunnerProvider,
      (_, next) {
        final value = next.value;
        if (value != null && value.isFinished && !completer.isCompleted) {
          completer.complete();
        }
      },
    );
    return completer.future;
  }

  test('a regression run records started, simulator and finished', () async {
    final config = _config([_spec('unit/alu'), _spec('unit/regfile')]);
    container.read(activeConfigProvider.notifier).replace(config);
    unawaited(container.read(regressionRunnerProvider.notifier).start(config));

    await waitForFinish();
    await pollUntil(
      () => ofKind(SimCruxAuditKinds.regressionFinished).isNotEmpty,
    );

    final started = ofKind(SimCruxAuditKinds.regressionStarted).single;
    expect(started.product, 'simcrux');
    // The exact count, not a telemetry bucket: an administrator reconciling a
    // night of CI wants the number, and this is not an aggregate metric whose
    // cardinality needs keeping down.
    expect(started.payload['tests'], 2);
    expect(started.payload['runId'], isNotNull);

    // One per RUN, never one per test — a thousand-test suite would otherwise
    // put a thousand identical lines into a file a human reads.
    final invoked = ofKind(SimCruxAuditKinds.simulatorInvoked);
    expect(invoked, hasLength(1));
    expect(invoked.single.payload['simulator'], isNotNull);

    final finished = ofKind(SimCruxAuditKinds.regressionFinished).single;
    expect(finished.payload['outcome'], 'completed');
    expect(finished.payload['tests'], 2);
    expect(finished.payload['failed'], 0);
    expect(finished.payload['runId'], started.payload['runId']);
  });

  test('a failing run reports its failure count', () async {
    final config = _config([_spec('unit/alu'), _spec('unit/fail')]);
    container.read(activeConfigProvider.notifier).replace(config);
    unawaited(container.read(regressionRunnerProvider.notifier).start(config));

    await waitForFinish();
    await pollUntil(
      () => ofKind(SimCruxAuditKinds.regressionFinished).isNotEmpty,
    );

    final finished = ofKind(SimCruxAuditKinds.regressionFinished).single;
    expect(finished.payload['outcome'], 'completed');
    expect(finished.payload['failed'], 1);
  });

  test('the terminal event is idempotent per run', () async {
    final config = _config([_spec('unit/alu')]);
    container.read(activeConfigProvider.notifier).replace(config);
    unawaited(container.read(regressionRunnerProvider.notifier).start(config));

    await waitForFinish();
    await pollUntil(
      () => ofKind(SimCruxAuditKinds.regressionFinished).isNotEmpty,
    );
    await container.read(regressionRunnerProvider.notifier).cancel();

    // `cancel` and the RegressionFinished event are two paths to one ending,
    // and a race between them must not produce two audit lines for one run —
    // the same guarantee `_terminalRecordedRunId` gives the telemetry counter.
    expect(ofKind(SimCruxAuditKinds.regressionFinished), hasLength(1));
  });

  test('every emitted kind is one this product registered', () async {
    final config = _config([_spec('unit/alu')]);
    container.read(activeConfigProvider.notifier).replace(config);
    unawaited(container.read(regressionRunnerProvider.notifier).start(config));
    await waitForFinish();
    await pollUntil(
      () => ofKind(SimCruxAuditKinds.regressionFinished).isNotEmpty,
    );

    for (final event in sink.events) {
      expect(
        SimCruxAuditKinds.all,
        contains(event.kind),
        reason: '${event.kind} is not in SimCruxAuditKinds.all',
      );
    }
  });
}
