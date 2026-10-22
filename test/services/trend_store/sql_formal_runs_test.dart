// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/formal_run_record.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/trend_store/sql_trend_store.dart';

// The formal history tables (trend-store v5): a record goes in against the
// result row it belongs to, comes back with its properties and its run's
// start time, replaces rather than doubles, and ages out with its run.

TrendPoint _point(String runId, String testId, DateTime at) => TrendPoint(
  runId: runId,
  testId: testId,
  status: TestStatus.pass,
  runtime: const Duration(seconds: 1),
  startedAt: at,
);

FormalRunRecord _record(
  String runId, {
  String testId = 'formal/prove',
  String verdict = 'PASS',
  String status = 'proved',
  int wallTimeMs = 1200,
}) => FormalRunRecord(
  runId: runId,
  testId: testId,
  tool: 'sby',
  task: 'prove',
  mode: 'prove',
  verdict: verdict,
  wallTimeMs: wallTimeMs,
  wallTimeSource: 'engine',
  engine: 'smtbmc',
  solver: 'yices',
  propertyCount: 2,
  properties: <FormalPropertyRecord>[
    FormalPropertyRecord(
      propertyKey: 'no_overflow',
      keyScheme: FormalPropertyRecord.kSchemeLabel,
      kind: 'assert',
      task: 'prove',
      label: 'no_overflow',
      location: 'rtl/fifo.sv:40',
      status: status,
    ),
    const FormalPropertyRecord(
      propertyKey: 'crux-fnv1a64/1:0123456789abcdef',
      keyScheme: FormalPropertyRecord.kSchemeSignature,
      kind: 'cover',
      task: 'prove',
      location: 'rtl/fifo.sv:52',
      status: 'reached',
      steps: 4,
      tracePath: 'engine_0/trace0.vcd',
      pretraceExposed: true,
    ),
  ],
);

void main() {
  late SqlTrendStore store;

  setUp(() async => store = await SqlTrendStore.open());
  tearDown(() => store.close());

  test('a record comes back with its properties and its run time', () async {
    final at = DateTime.utc(2026, 10, 1, 12);
    await store.recordTrendPoint(_point('r1', 'formal/prove', at));
    await store.recordFormalRun(_record('r1'));

    final runs = await store.formalRuns();
    expect(runs, hasLength(1));
    final run = runs.single;
    expect(run.runId, 'r1');
    expect(run.verdict, 'PASS');
    expect(run.engine, 'smtbmc');
    expect(run.solver, 'yices');
    expect(run.wallTimeMs, 1200);
    expect(run.startedAt, at);
    expect(run.properties.map((p) => p.propertyKey), [
      'no_overflow',
      'crux-fnv1a64/1:0123456789abcdef',
    ]);
    final cover = run.properties.last;
    expect(cover.keyScheme, FormalPropertyRecord.kSchemeSignature);
    expect(cover.kind, 'cover');
    expect(cover.steps, 4);
    expect(cover.tracePath, 'engine_0/trace0.vcd');
    expect(cover.pretraceExposed, isTrue);
    expect(run.properties.first.label, 'no_overflow');
  });

  test('a second record for one run and test replaces the first', () async {
    await store.recordTrendPoint(
      _point('r1', 'formal/prove', DateTime.utc(2026, 10)),
    );
    await store.recordFormalRun(_record('r1'));
    await store.recordFormalRun(_record('r1', verdict: 'FAIL'));
    final runs = await store.formalRuns();
    expect(runs.single.verdict, 'FAIL');
    expect(runs.single.properties, hasLength(2));
  });

  test('newest run first, bounded by the window, narrowed by test', () async {
    for (var i = 1; i <= 3; i++) {
      final at = DateTime.utc(2026, 10, i);
      await store.recordTrendPoint(_point('r$i', 'formal/prove', at));
      await store.recordTrendPoint(_point('r$i', 'formal/other', at));
      await store.recordFormalRun(_record('r$i'));
      await store.recordFormalRun(_record('r$i', testId: 'formal/other'));
    }
    final newest = await store.formalRuns(runWindow: 2);
    expect(newest.map((r) => r.runId).toSet(), {'r3', 'r2'});
    expect(newest.first.runId, 'r3');
    final one = await store.formalRuns(testId: 'formal/other');
    expect(one, hasLength(3));
    expect(one.every((r) => r.testId == 'formal/other'), isTrue);
    expect(one.every((r) => r.properties.length == 2), isTrue);
  });

  test('a property keeps the run it was first seen in', () async {
    await store.recordTrendPoint(
      _point('r1', 'formal/prove', DateTime.utc(2026, 10)),
    );
    await store.recordTrendPoint(
      _point('r2', 'formal/prove', DateTime.utc(2026, 10, 2)),
    );
    await store.recordFormalRun(_record('r1'));
    await store.recordFormalRun(_record('r2'));
    final rows = await store.debugRawQuery(
      'SELECT first_seen_run_id FROM formal_properties',
    );
    expect(rows.map((r) => r['first_seen_run_id']).toSet(), {'r1'});
  });

  test('the formal rows age out with their run', () async {
    final old = DateTime.now().toUtc().subtract(const Duration(days: 40));
    await store.recordTrendPoint(_point('old', 'formal/prove', old));
    await store.recordFormalRun(_record('old'));
    await store.recordTrendPoint(
      _point('new', 'formal/prove', DateTime.now().toUtc()),
    );
    await store.recordFormalRun(_record('new'));

    await store.applyRetention(const RetentionPolicy(maxAgeDays: 30));

    final runs = await store.formalRuns();
    expect(runs.map((r) => r.runId), ['new']);
    expect(
      await store.debugRawQuery(
        "SELECT * FROM formal_property_results WHERE run_id = 'old'",
      ),
      isEmpty,
    );
    // Both identities are still named by the surviving run.
    expect(
      await store.debugRawQuery('SELECT * FROM formal_properties'),
      hasLength(2),
    );

    await store.applyRetention(
      const RetentionPolicy(maxAgeDays: 1, maxDataPoints: 0),
    );
    expect(await store.formalRuns(), isEmpty);
    expect(
      await store.debugRawQuery('SELECT * FROM formal_properties'),
      isEmpty,
    );
  });

  test('the interface default records and returns nothing', () async {
    final mock = _NarrowStore();
    await mock.recordFormalRun(_record('r1'));
    expect(await mock.formalRuns(), isEmpty);
  });
}

class _NarrowStore extends TrendStore {
  @override
  Future<void> recordTrendPoint(TrendPoint point) async {}

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) async* {}

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) async* {}
}
