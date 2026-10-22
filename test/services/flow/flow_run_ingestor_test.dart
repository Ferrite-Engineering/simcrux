// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/trend_store/sql_trend_store.dart';

import 'librelane_run_builder.dart';

/// Ingest reads runs SimCrux did not launch, read-only, inside the
/// directories it was allowed, and files them with `didExecute` false and
/// the `ingest` trigger.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('flow_ingest_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Every file under [dir] with its size and modification time: what a
  /// read-only pass must leave exactly as it found it.
  Map<String, String> snapshot(String dir) => <String, String>{
    for (final e in Directory(
      dir,
    ).listSync(recursive: true, followLinks: false))
      p.relative(e.path, from: dir): e is File
          ? '${e.lengthSync()} ${e.lastModifiedSync().microsecondsSinceEpoch}'
          : 'dir',
  };

  test('a report.json, a run directory and a directory of runs', () async {
    final runs = Directory(p.join(tmp.path, 'runs'))..createSync();
    for (final name in const ['path_ice40_met', 'path_ice40_violated']) {
      final dir = Directory(p.join(runs.path, 'adder', name))
        ..createSync(recursive: true);
      File('$fixtures/$name/report.json').copySync(
        p.join(dir.path, 'report.json'),
      );
    }
    LibreLaneRunBuilder(tmp.path, tag: 'RUN_A')
      ..step('yosys-synthesis')
      ..finalMetrics(cleanMetrics);

    final items = await const FlowRunIngestor().ingest(
      <String>[
        p.join(runs.path, 'adder', 'path_ice40_met', 'report.json'),
        runs.path,
      ],
      allowedRoots: <String>[tmp.path],
    );
    final verdicts = <String?>[
      for (final i in items) i.reading?.verdict.wireName,
    ];
    // The report file, then the directory's runs in name order: the
    // LibreLane `RUN_A`, then `adder/` and its two nextpnr runs.
    expect(verdicts, ['met', 'met', 'met', 'violated']);
    expect(items[1].reading!.run.ref.kind, FlowKind.librelane);
    expect(items[2].reading!.run.ref.kind, FlowKind.nextpnr);
  });

  test('ingest writes nothing inside a run directory', () async {
    final run = LibreLaneRunBuilder(tmp.path)
      ..step('yosys-synthesis')
      ..step('openroad-stapostpnr', complete: false);
    final before = snapshot(run.root);
    await const FlowRunIngestor().ingest(
      <String>[run.root],
      allowedRoots: <String>[tmp.path],
    );
    expect(snapshot(run.root), before);
  });

  test('a path outside the allowed directories is refused', () async {
    final elsewhere = Directory.systemTemp.createTempSync('flow_elsewhere_');
    addTearDown(() => elsewhere.deleteSync(recursive: true));
    final items = await const FlowRunIngestor().ingest(
      <String>[elsewhere.path],
      allowedRoots: <String>[tmp.path],
    );
    expect(items.single.failure, FlowIngestFailure.outside);
  });

  test(
    'a link inside an allowed directory that leaves it is refused',
    () async {
      final elsewhere = Directory.systemTemp.createTempSync('flow_elsewhere_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      File('$fixtures/path_ice40_met/report.json').copySync(
        p.join(elsewhere.path, 'report.json'),
      );
      Link(p.join(tmp.path, 'run')).createSync(elsewhere.path);
      final items = await const FlowRunIngestor().ingest(
        <String>[p.join(tmp.path, 'run')],
        allowedRoots: <String>[tmp.path],
      );
      expect(items.single.failure, FlowIngestFailure.outside);
    },
    testOn: '!windows',
  );

  test('a zipped artifact is named, not opened', () async {
    final zip = File(p.join(tmp.path, 'GDS_logs.zip'))..writeAsStringSync('PK');
    final items = await const FlowRunIngestor().ingest(
      <String>[zip.path],
      allowedRoots: <String>[tmp.path],
    );
    expect(items.single.failure, FlowIngestFailure.archive);
  });

  test('a missing path and an unrecognised directory say so', () async {
    final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
    final items = await const FlowRunIngestor().ingest(
      <String>[p.join(tmp.path, 'nope'), empty.path],
      allowedRoots: <String>[tmp.path],
    );
    expect(items.map((i) => i.failure), [
      FlowIngestFailure.missing,
      FlowIngestFailure.unrecognised,
    ]);
  });

  group('results and persistence', () {
    test('an ingested run is a result that did not execute', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..finalMetrics(<String, Object?>{
          ...cleanMetrics,
          'route__drc_errors': 2,
        });
      final reading = (await const FlowRunIngestor().ingest(
        <String>[run.root],
        allowedRoots: <String>[tmp.path],
      )).single.reading!;
      final result = FlowRunIngestor.resultFor(
        reading,
        now: DateTime.utc(2026, 10, 21),
      );
      expect(result.didExecute, isFalse);
      expect(result.status, TestStatus.fail);
      expect(result.metrics[FlowMetricKeys.verdict], 'violated');
      // The run root as resolved: the path checked is the path read.
      expect(
        result.metrics[FlowMetricKeys.runDir],
        Directory(run.root).resolveSymbolicLinksSync(),
      );
      // The directory above `runs/` names the design.
      expect(result.testId, 'flow/${p.basename(tmp.path)}');
    });

    test('persist records the run once, with its steps and metrics, and '
        'retention prunes them with it', () async {
      final run = LibreLaneRunBuilder(tmp.path)
        ..step('yosys-synthesis')
        ..step('openroad-stapostpnr')
        ..finalMetrics(<String, Object?>{
          ...cleanMetrics,
          'timing__setup__ws__corner:nom_tt_025C_1v80': 1.25,
        });
      final items = await const FlowRunIngestor().ingest(
        <String>[run.root],
        allowedRoots: <String>[tmp.path],
      );
      final store = await SqlTrendStore.open();
      addTearDown(store.close);
      expect(
        await FlowRunIngestor.persist(
          store,
          items,
          now: DateTime.now().toUtc(),
        ),
        1,
      );
      expect(await FlowRunIngestor.persist(store, items), 0);

      final runId = FlowRunIngestor.runIdFor(items.single.reading!);
      final runs = await store.debugRawQuery(
        'SELECT trigger_kind FROM runs WHERE id = ?',
        <Object?>[runId],
      );
      expect(runs.single['trigger_kind'], 'ingest');
      final steps = await store.debugRawQuery(
        'SELECT step_id, status FROM flow_steps WHERE run_id = ? '
        'ORDER BY ordinal',
        <Object?>[runId],
      );
      expect(steps.map((s) => s['step_id']), [
        'yosys-synthesis',
        'openroad-stapostpnr',
      ]);
      final metrics = await store.debugRawQuery(
        'SELECT key, base, modifiers, value_real, aggregated FROM flow_metrics '
        'WHERE run_id = ?',
        <Object?>[runId],
      );
      final corner = metrics.firstWhere(
        (m) => m['key'] == 'timing__setup__ws__corner:nom_tt_025C_1v80',
      );
      expect(corner['base'], 'timing__setup__ws');
      expect(corner['modifiers'], '{"corner":"nom_tt_025C_1v80"}');
      expect(corner['aggregated'], 0);
      expect(
        metrics.firstWhere(
          (m) => m['key'] == 'route__drc_errors',
        )['value_real'],
        0,
      );

      await store.applyRetention(
        const RetentionPolicy(maxAgeDays: 1, maxDataPoints: 0),
      );
      expect(
        await store.debugRawQuery(
          'SELECT * FROM flow_metrics WHERE run_id = ?',
          <Object?>[runId],
        ),
        isEmpty,
      );
      expect(
        await store.debugRawQuery(
          'SELECT * FROM flow_steps WHERE run_id = ?',
          <Object?>[runId],
        ),
        isEmpty,
      );
    });
  });
}
