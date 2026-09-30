// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/pass_fail_detector/regex_detector.dart';

/// `guardedRegexHasMatch` spawned a fresh isolate per
/// pattern per test (~20k spawns on a regex-heavy 10k-test run). Workers
/// are now pooled. These guard that the pooling is real and that it does
/// not weaken the killable-deadline guarantee the pool replaced.
void main() {
  tearDown(shutdownRegexIsolatePool);

  test('a completed match returns its worker to the pool', () async {
    await shutdownRegexIsolatePool();
    expect(debugRegexPoolIdleCount, 0);
    expect(await guardedRegexHasMatch('needle', 'hay needle hay'), isTrue);
    expect(
      debugRegexPoolIdleCount,
      1,
      reason: 'the worker must be parked for reuse, not discarded',
    );
  });

  test('sequential matches reuse the same pooled worker', () async {
    await shutdownRegexIsolatePool();
    for (var i = 0; i < 25; i++) {
      expect(await guardedRegexHasMatch('t$i', 'prefix t$i suffix'), isTrue);
      expect(
        debugRegexPoolIdleCount,
        1,
        reason: 'iteration $i must not have spawned an extra worker',
      );
    }
  });

  test('results stay correct across reuse', () async {
    await shutdownRegexIsolatePool();
    expect(await guardedRegexHasMatch('^ERROR', 'ERROR: boom'), isTrue);
    expect(await guardedRegexHasMatch('^ERROR', 'all good'), isFalse);
    expect(
      await guardedRegexHasMatch(r'UVM_ERROR\s+:\s+0', 'UVM_ERROR : 0'),
      isTrue,
    );
    expect(await guardedRegexHasMatch('multi', 'a\nmulti\nb'), isTrue);
  });

  test(
    'a catastrophic pattern still returns by the deadline, and its '
    'killed worker is not returned to the pool',
    () async {
      await shutdownRegexIsolatePool();
      // Warm the pool so the killed worker is demonstrably removed.
      await guardedRegexHasMatch('ok', 'ok');
      expect(debugRegexPoolIdleCount, 1);

      final sw = Stopwatch()..start();
      final result = await guardedRegexHasMatch(
        // Classic exponential backtracker with no match.
        '(a+)+b',
        'a' * 4000,
        deadline: const Duration(milliseconds: 300),
      );
      sw.stop();
      expect(result, isFalse, reason: 'timeout ⇒ no conclusive match');
      expect(
        sw.elapsedMilliseconds,
        lessThan(5000),
        reason: 'the deadline must still bound the match',
      );
      expect(
        debugRegexPoolIdleCount,
        0,
        reason: 'a killed worker must never be parked for reuse',
      );
    },
  );

  test('the pool recovers after a kill', () async {
    await shutdownRegexIsolatePool();
    await guardedRegexHasMatch(
      '(a+)+b',
      'a' * 4000,
      deadline: const Duration(milliseconds: 200),
    );
    expect(debugRegexPoolIdleCount, 0);
    // A fresh worker is spawned on demand and the pool refills.
    expect(await guardedRegexHasMatch('needle', 'needle'), isTrue);
    expect(debugRegexPoolIdleCount, 1);
  });

  test('concurrent matches are each served correctly', () async {
    await shutdownRegexIsolatePool();
    final results = await Future.wait(<Future<bool>>[
      for (var i = 0; i < 12; i++)
        guardedRegexHasMatch('token$i', 'xx token$i yy'),
    ]);
    expect(results, everyElement(isTrue));
    // Concurrency needs more than one worker, but the idle pool is
    // bounded so the excess is shut down rather than left resident.
    expect(debugRegexPoolIdleCount, lessThanOrEqualTo(4));
  });

  test(
    'a worker leased when shutdown runs is reaped, not re-parked',
    () async {
      await shutdownRegexIsolatePool();
      expect(debugRegexPoolIdleCount, 0);

      // Start a match against an empty pool: run() is parked awaiting
      // _RegexWorker.spawn(), i.e. the worker is out on a lease.
      final leased = guardedRegexHasMatch('needle', 'hay needle hay');

      // Shut the pool down while that lease is in flight. Without leased-
      // worker quiescing, the match completes with a live worker and re-
      // parks it into the pool the shutdown believed it had emptied.
      await shutdownRegexIsolatePool();

      // The match still resolves correctly...
      expect(await leased, isTrue);
      // ...but its worker must NOT have resurrected the pool.
      expect(
        debugRegexPoolIdleCount,
        0,
        reason: 'a worker leased across a shutdown must never be re-parked',
      );
    },
  );

  test('onTimeout override is honored', () async {
    await shutdownRegexIsolatePool();
    final result = await guardedRegexHasMatch(
      '(a+)+b',
      'a' * 4000,
      deadline: const Duration(milliseconds: 200),
      onTimeout: true,
    );
    expect(result, isTrue);
  });
}
