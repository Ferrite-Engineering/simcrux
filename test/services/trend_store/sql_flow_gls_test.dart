// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/flow_run_record.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/trend_store/sql_trend_store.dart';

// `flow_gls_results` (trend-store v5): one row per gate-level test per run,
// replaced rather than doubled, newest run first, narrowed by test, and the
// default of the interface records and returns nothing.

TrendPoint _point(String runId, String testId, DateTime at) => TrendPoint(
  runId: runId,
  testId: testId,
  status: TestStatus.pass,
  runtime: const Duration(seconds: 1),
  startedAt: at,
  trigger: RegressionTrigger.gls,
);

FlowGlsRecord _record(
  String runId, {
  String testId = 'gls/cpu/alu',
  String outcome = 'equal',
  int? real = 0,
  int? x = 0,
  int? first,
}) => FlowGlsRecord(
  runId: runId,
  testId: testId,
  flowRunId: 'ingest-librelane-t-1',
  netlist: 'nl',
  delays: 'functional',
  outcome: outcome,
  realDiffs: real,
  xDiffs: x,
  firstDiffPs: first,
);

class _Bare extends TrendStore {
  @override
  Future<void> recordTrendPoint(TrendPoint point) async {}

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) async* {}

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) async* {}
}

void main() {
  late SqlTrendStore store;

  setUp(() async => store = await SqlTrendStore.open());
  tearDown(() => store.close());

  test('a record comes back as it went in', () async {
    final at = DateTime.utc(2026, 10, 1, 12);
    await store.recordTrendPoint(_point('r1', 'gls/cpu/alu', at));
    await store.recordFlowGls(
      _record('r1', outcome: 'x_only', x: 12, first: 4000),
    );
    final rows = await store.flowGlsResults();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.runId, 'r1');
    expect(row.testId, 'gls/cpu/alu');
    expect(row.flowRunId, 'ingest-librelane-t-1');
    expect(row.netlist, 'nl');
    expect(row.delays, 'functional');
    expect(row.outcome, 'x_only');
    expect(row.realDiffs, 0);
    expect(row.xDiffs, 12);
    expect(row.firstDiffPs, 4000);
  });

  test('a did-not-run row keeps its counts null', () async {
    await store.recordFlowGls(
      _record('r1', outcome: 'not_run', real: null, x: null),
    );
    final row = (await store.flowGlsResults()).single;
    expect(row.outcome, 'not_run');
    expect(row.realDiffs, isNull);
    expect(row.xDiffs, isNull);
    expect(row.firstDiffPs, isNull);
  });

  test('a second record for one run and test replaces the first', () async {
    await store.recordFlowGls(_record('r1'));
    await store.recordFlowGls(_record('r1', outcome: 'differs', real: 3));
    final rows = await store.flowGlsResults();
    expect(rows, hasLength(1));
    expect(rows.single.outcome, 'differs');
    expect(rows.single.realDiffs, 3);
  });

  test('newest run first, narrowed by test, bounded by the limit', () async {
    await store.recordTrendPoint(
      _point('r1', 'gls/a', DateTime.utc(2026, 10)),
    );
    await store.recordTrendPoint(
      _point('r2', 'gls/a', DateTime.utc(2026, 10, 2)),
    );
    await store.recordTrendPoint(
      _point('r2', 'gls/b', DateTime.utc(2026, 10, 2)),
    );
    await store.recordFlowGls(_record('r1', testId: 'gls/a'));
    await store.recordFlowGls(_record('r2', testId: 'gls/a'));
    await store.recordFlowGls(_record('r2', testId: 'gls/b'));
    final all = await store.flowGlsResults();
    expect(all.map((r) => '${r.runId}:${r.testId}'), <String>[
      'r2:gls/a',
      'r2:gls/b',
      'r1:gls/a',
    ]);
    final a = await store.flowGlsResults(testId: 'gls/a');
    expect(a.map((r) => r.runId), <String>['r2', 'r1']);
    expect(await store.flowGlsResults(limit: 1), hasLength(1));
    expect(await store.flowGlsResults(limit: 0), isEmpty);
  });

  test('the rows age out with their result row', () async {
    final old = DateTime.utc(2020);
    await store.recordTrendPoint(_point('r1', 'gls/a', old));
    await store.recordFlowGls(_record('r1', testId: 'gls/a'));
    await store.recordTrendPoint(
      _point('r2', 'gls/a', DateTime.now().toUtc()),
    );
    await store.recordFlowGls(_record('r2', testId: 'gls/a'));
    await store.applyRetention(const RetentionPolicy(maxAgeDays: 30));
    final rows = await store.flowGlsResults();
    expect(rows.map((r) => r.runId), <String>['r2']);
  });

  test('the interface default records and returns nothing', () async {
    final bare = _Bare();
    await bare.recordFlowGls(_record('r1'));
    expect(await bare.flowGlsResults(), isEmpty);
  });
}
