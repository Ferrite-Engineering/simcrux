// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/re_run_query/re_run_query_service.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';

const _runId = 'run-1';

TestSpec _spec(String id, {String? parentSpecId}) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'icarus',
  top: 'tb',
  parentSpecId: parentSpecId,
);

TestResult _result(String id, TestStatus status) => TestResult(
  testId: id,
  runId: _runId,
  status: status,
  startedAt: DateTime.utc(2026, 5, 25, 12),
  finishedAt: DateTime.utc(2026, 5, 25, 12, 0, 1),
);

void main() {
  group('DefaultReRunQueryService.queryFailedSpecsFrom', () {
    test('returns specs for fail / timeout / unknown statuses only', () async {
      final store = InMemoryResultStore.forRun(
        TestRun(
          id: _runId,
          startedAt: DateTime.utc(2026, 5, 25, 12),
          testIds: const ['unit/a', 'unit/b', 'unit/c', 'unit/d'],
        ),
      );
      addTearDown(
        () async => await store.recordRunCompletion(
          RunSummary(
            runId: _runId,
            startedAt: DateTime.utc(2026, 5, 25, 12),
            finishedAt: DateTime.utc(2026, 5, 25, 12, 1),
            totalsByStatus: const {},
          ),
        ),
      );
      final service = DefaultReRunQueryService(resultStoreResolver: () => store)
        ..trackSubmittedSpecs([
          _spec('unit/a'),
          _spec('unit/b'),
          _spec('unit/c'),
          _spec('unit/d'),
        ]);
      await store.recordResult(_result('unit/a', TestStatus.pass));
      await store.recordResult(_result('unit/b', TestStatus.fail));
      await store.recordResult(_result('unit/c', TestStatus.timeout));
      await store.recordResult(_result('unit/d', TestStatus.unknown));

      final failed = await service.queryFailedSpecsFrom(_runId);
      expect(failed.map((s) => s.id).toSet(), {'unit/b', 'unit/c', 'unit/d'});
    });

    test('returns empty list when no run is in flight', () async {
      final service = DefaultReRunQueryService(resultStoreResolver: () => null);
      expect(await service.queryFailedSpecsFrom(_runId), isEmpty);
    });

    test('silently drops failed results whose specs are not tracked', () async {
      final store = InMemoryResultStore.forRun(
        TestRun(
          id: _runId,
          startedAt: DateTime.utc(2026, 5, 25, 12),
          testIds: const ['unit/a', 'unit/b', 'unit/c', 'unit/d'],
        ),
      );
      // Track only one of the two failed tests.
      final service = DefaultReRunQueryService(resultStoreResolver: () => store)
        ..trackSubmittedSpecs([_spec('unit/b')]);
      await store.recordResult(_result('unit/a', TestStatus.fail));
      await store.recordResult(_result('unit/b', TestStatus.fail));
      final failed = await service.queryFailedSpecsFrom(_runId);
      expect(failed.map((s) => s.id), ['unit/b']);
    });

    test('deduplicates by testId when the store has retried results', () async {
      // The scheduler emits one final result per attempt, but if a
      // future trend store surfaces every retry the query should
      // still return at most one spec per testId.
      final store = InMemoryResultStore.forRun(
        TestRun(
          id: _runId,
          startedAt: DateTime.utc(2026, 5, 25, 12),
          testIds: const ['unit/a', 'unit/b', 'unit/c', 'unit/d'],
        ),
      );
      final service = DefaultReRunQueryService(resultStoreResolver: () => store)
        ..trackSubmittedSpecs([_spec('unit/a')]);
      await store.recordResult(_result('unit/a', TestStatus.fail));
      await store.recordResult(_result('unit/a', TestStatus.fail));
      final failed = await service.queryFailedSpecsFrom(_runId);
      expect(failed, hasLength(1));
    });
  });

  group('DefaultReRunQueryService.queryGroupSpecsFor', () {
    test('returns every tracked spec with the matching parentSpecId', () async {
      final service = DefaultReRunQueryService(resultStoreResolver: () => null)
        ..trackSubmittedSpecs([
          _spec('unit/p+seed=1', parentSpecId: 'unit/p'),
          _spec('unit/p+seed=2', parentSpecId: 'unit/p'),
          _spec('unit/p+seed=3', parentSpecId: 'unit/p'),
          _spec('unit/other'),
        ]);
      final group = await service.queryGroupSpecsFor(
        parentSpecId: 'unit/p',
        runId: _runId,
      );
      expect(group.map((s) => s.id).toSet(), {
        'unit/p+seed=1',
        'unit/p+seed=2',
        'unit/p+seed=3',
      });
    });

    test('returns an empty list when the parentSpecId is unknown', () async {
      final service = DefaultReRunQueryService(resultStoreResolver: () => null)
        ..trackSubmittedSpecs([_spec('unit/a')]);
      final group = await service.queryGroupSpecsFor(
        parentSpecId: 'nonexistent',
        runId: _runId,
      );
      expect(group, isEmpty);
    });
  });

  group('DefaultReRunQueryService.trackSubmittedSpecs', () {
    test('is idempotent — re-registering overwrites the prior entry', () {
      final service = DefaultReRunQueryService(resultStoreResolver: () => null);
      final v1 = _spec('unit/a');
      final v2 = v1.copyWith(seed: 99);
      service
        ..trackSubmittedSpecs([v1])
        ..trackSubmittedSpecs([v2]);
      expect(service.trackedSpecs['unit/a']!.seed, 99);
    });
  });

  group('DefaultReRunQueryService project scoping', () {
    // Two projects that are checkouts of the same repo share suite/test
    // names, so their TestSpec ids collide. A projectScopeResolver must
    // keep each project's inventory separate — a re-run in A must never
    // resolve B's spec.
    TestRun run(String id) => TestRun(
      id: id,
      startedAt: DateTime.utc(2026, 5, 25, 12),
      testIds: const ['suite/t1'],
    );

    test('same test id in two projects keeps separate inventories', () async {
      String? scope;
      final storeA = InMemoryResultStore.forRun(run(_runId));
      final storeB = InMemoryResultStore.forRun(run(_runId));
      final service = DefaultReRunQueryService(
        resultStoreResolver: () => scope == 'A' ? storeA : storeB,
        projectScopeResolver: () => scope,
      );

      scope = 'A';
      service.trackSubmittedSpecs([_spec('suite/t1').copyWith(seed: 1)]);
      await storeA.recordResult(_result('suite/t1', TestStatus.fail));

      scope = 'B';
      service.trackSubmittedSpecs([_spec('suite/t1').copyWith(seed: 2)]);
      await storeB.recordResult(_result('suite/t1', TestStatus.fail));

      // Querying A must resolve A's spec (seed 1), not B's (seed 2) — the
      // pre-fix flat map returned whichever project tracked last.
      scope = 'A';
      final aFailed = await service.queryFailedSpecsFrom(_runId);
      expect(aFailed.single.seed, 1);

      scope = 'B';
      final bFailed = await service.queryFailedSpecsFrom(_runId);
      expect(bFailed.single.seed, 2);
    });

    test('a null scope resolver preserves the single-project behaviour', () {
      final service = DefaultReRunQueryService(resultStoreResolver: () => null)
        ..trackSubmittedSpecs([_spec('unit/a')]);
      expect(service.trackedSpecs.keys, ['unit/a']);
    });
  });
}
