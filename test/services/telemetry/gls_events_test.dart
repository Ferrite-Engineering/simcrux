// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The gate-level counters and the result row, fired on the real code path:
// the regression runner at the end of a gate-level run, handed the derived
// specs and a scheduler that wraps the real one. Every assertion reads what
// production code handed a RecordingTelemetryService or the trend store,
// never a hand-built event.

import 'dart:async';
import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../support/gls_support.dart';
import '../../support/poll_until.dart';
import '../../support/recording_telemetry_service.dart';
import 'catalog_events_test.dart' show expectMatchesCatalog;

/// Waits (bounded) for the store to hold a gate-level row.
Future<void> _untilRows(TrendStore store) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while ((await store.flowGlsResults()).isEmpty) {
    if (DateTime.now().isAfter(deadline)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late RecordingTelemetryService telemetry;
  late ProviderContainer container;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_gls_events_');
    telemetry = RecordingTelemetryService();
    container = ProviderContainer(
      overrides: [
        telemetryServiceProvider.overrideWithValue(telemetry),
        trendStoreDirectoryOverrideProvider.overrideWithValue(
          p.join(tmp.path, 'trends'),
        ),
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

  TestSpec macTest() {
    final mac = p.absolute('$kGlFixtures/mac');
    return TestSpec(
      id: 'mac/plain',
      name: 'plain',
      suiteName: 'mac',
      simulatorId: 'icarus',
      top: 'tb',
      sources: <String>[p.join(mac, 'dut.v'), p.join(mac, 'tb.v')],
      defines: const <String, String>{'OUT': '"mac.txt"'},
    );
  }

  /// Runs one gate-level test through the regression runner: the run
  /// directory is the MAC's, the RTL and gate port dumps are [rtl] and
  /// [gate] of the research fixtures.
  Future<void> runGls({
    String rtl = 'rtl_x',
    String gate = 'gate_x',
    bool withModels = true,
  }) async {
    final run = p.join(tmp.path, 'run');
    Directory(run).createSync();
    writeMacRun(run: run, pdkParent: tmp.path, withModels: withModels);
    final info = (await GlsRunInfo.read(
      runRoot: run,
      flowRunId: 'flow-run-1',
    )).info!;
    final scratch = GlsScratch(root: p.join(tmp.path, 'scratch'));
    const options = GlsOptions();
    final planSet = await GlsPlanner.plan(
      info: info,
      options: options,
      selected: <TestSpec>[macTest()],
      runDir: await scratch.allocateRun('r'),
      scratch: scratch,
    );
    final finished = Completer<void>();
    container.listen<AsyncValue<RegressionRunState?>>(
      regressionRunnerProvider,
      (
        _,
        next,
      ) {
        final value = next.value;
        if (value != null && value.isFinished && !finished.isCompleted) {
          finished.complete();
        }
      },
    );
    container
        .read(regressionRunnerProvider.notifier)
        .arm(
          RegressionConfig(
            projectFilePath: p.join(tmp.path, 'simcrux.yaml'),
            schemaVersion: '1',
            suites: const <Suite>[],
            simulatorBinaries: const {},
          ),
        );
    await container
        .read(regressionRunnerProvider.notifier)
        .submitSpecs(
          <TestSpec>[for (final plan in planSet.plans) plan.submitSpec],
          trigger: RegressionTrigger.gls,
          wrapScheduler: (_) => GlsScheduler(
            inner: FakeGlsInner(
              (_) => glsPass(),
              onRun: glsVcdWriter(rtl: rtl, gate: gate),
            ),
            plans: planSet.plans,
            info: info,
            options: options,
          ),
        );
    await finished.future;
  }

  test('one flow.gls.completed per gate-level run: six closed properties '
      'and nothing of the design', () async {
    await runGls();
    await pollUntil(() => telemetry.named('flow.gls.completed').isNotEmpty);
    final event = telemetry.named('flow.gls.completed').single;
    expect(event.properties, <String, Object?>{
      'outcome': 'x_only',
      'simulator': 'icarus',
      'netlist': 'nl',
      'delays': 'functional',
      'target': 'sky130',
      'tests': 1,
    });
    expect(event.properties.length, lessThanOrEqualTo(6));
    expectMatchesCatalog(event);
    final values = event.properties.values.join(' ');
    for (final secret in const ['mac', 'tb.uut', 'parity', 'acc', 'clk']) {
      expect(values, isNot(contains(secret)), reason: secret);
    }
    // No count of differences and no cycle in any event of the run.
    for (final e in telemetry.events) {
      expect(e.properties.keys, isNot(contains('real_diffs')));
      expect(e.properties.keys, isNot(contains('x_diffs')));
    }
  });

  test('regression.completed names the trigger gls', () async {
    await runGls();
    await pollUntil(() => telemetry.named('regression.completed').isNotEmpty);
    final event = telemetry.named('regression.completed').single;
    expect(event.properties['trigger'], 'gls');
    expectMatchesCatalog(event);
  });

  test('a run whose dumps agree reports equal', () async {
    await runGls(rtl: 'verilator_rtl', gate: 'verilator_rtl');
    await pollUntil(() => telemetry.named('flow.gls.completed').isNotEmpty);
    expect(
      telemetry.named('flow.gls.completed').single.properties['outcome'],
      'equal',
    );
  });

  test('missing cell models: flow.tool.missing{pdk_models}, outcome '
      'not_run', () async {
    await runGls(withModels: false);
    await pollUntil(() => telemetry.named('flow.tool.missing').isNotEmpty);
    final missing = telemetry.named('flow.tool.missing').single;
    expect(missing.properties, <String, Object?>{'tool': 'pdk_models'});
    expectMatchesCatalog(missing);
    await pollUntil(() => telemetry.named('flow.gls.completed').isNotEmpty);
    expect(
      telemetry.named('flow.gls.completed').single.properties['outcome'],
      'not_run',
    );
  });

  test('the result row is recorded in flow_gls_results, trigger gls, keyed '
      'to the flow run, with both counts and the first difference', () async {
    await runGls();
    final store = await container.read(trendStoreProvider.future);
    await _untilRows(store);
    final row = (await store.flowGlsResults()).single;
    expect(row.testId, 'gls/mac/plain');
    expect(row.flowRunId, 'flow-run-1');
    expect(row.netlist, 'nl');
    expect(row.delays, 'functional');
    expect(row.outcome, 'x_only');
    expect(row.realDiffs, 0);
    expect(row.xDiffs, greaterThanOrEqualTo(199));
    expect(row.firstDiffPs, isNotNull);
    // The gate-level result is a trend point of the same run.
    final points = await store.pointsForRun(row.runId);
    expect(points.single.testId, 'gls/mac/plain');
  });

  test('a test that did not run is still a row, so it is never mistaken '
      'for a pass', () async {
    await runGls(withModels: false);
    final store = await container.read(trendStoreProvider.future);
    await _untilRows(store);
    final row = (await store.flowGlsResults()).single;
    expect(row.outcome, 'not_run');
    expect(row.realDiffs, isNull);
    expect(row.xDiffs, isNull);
  });
}
