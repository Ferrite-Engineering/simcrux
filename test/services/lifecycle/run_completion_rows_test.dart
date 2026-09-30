// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The spec metadata a completed-run hook needs and a `TestResult` does not
// carry.
//
// A result knows its test id, its status and its timings. It does not know
// which suite it belongs to or which simulator ran it — those are properties
// of the `TestSpec`, held by the result store. A hook writing a durable
// record of the run needs them, and the store's own indexes are keyed the
// other way round (suite name → results), so inverting them in every hook
// that needs the mapping is both duplicated work and the wrong data structure.

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';

TestResult result(String testId, {int runtimeMs = 10}) => TestResult(
  testId: testId,
  runId: 'run-1',
  status: TestStatus.pass,
  startedAt: DateTime.utc(2026, 6),
  finishedAt: DateTime.utc(2026, 6).add(Duration(milliseconds: runtimeMs)),
);

void main() {
  late InMemoryResultStore store;

  setUp(() {
    store = InMemoryResultStore.forRun(
      TestRun(
        id: 'run-1',
        startedAt: DateTime.utc(2026, 6),
        testIds: const ['a', 'b'],
      ),
    );
  });

  test(
    'a result recorded with metadata can name its suite and simulator',
    () async {
      final r = result('a');
      await store.recordResultWithMetadata(
        r,
        suiteName: 'unit',
        simulatorId: 'verilator',
      );

      expect(store.suiteOf(r), 'unit');
      expect(store.simulatorOf(r), 'verilator');
    },
  );

  test('a result recorded without metadata names neither, rather than '
      'guessing', () async {
    final r = result('a');
    await store.recordResult(r);

    expect(store.suiteOf(r), isNull);
    expect(store.simulatorOf(r), isNull);
  });

  test('two results that compare EQUAL keep their own metadata', () async {
    // The defect this lookup is identity-keyed to avoid. `TestResult` has
    // value equality, so the same test with the same status and the same
    // runtime — which is what a passing test looks like on two runs, or the
    // same spec dispatched to two simulators — compares equal. A hash map
    // would collapse them and hand back one entry's suite for both.
    final first = result('a');
    final second = result('a');
    expect(first, second, reason: 'the premise: these compare equal');

    await store.recordResultWithMetadata(
      first,
      suiteName: 'unit',
      simulatorId: 'verilator',
    );
    await store.recordResultWithMetadata(
      second,
      suiteName: 'regression',
      simulatorId: 'icarus',
    );

    expect(store.suiteOf(first), 'unit');
    expect(store.simulatorOf(first), 'verilator');
    expect(store.suiteOf(second), 'regression');
    expect(store.simulatorOf(second), 'icarus');
  });
}
