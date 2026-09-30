// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/statistics/providers/job_scheduler_stats_provider.dart';

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  JobSchedulerStatsNotifier notifier() =>
      container.read(jobSchedulerStatsProvider.notifier);
  JobSchedulerStats stats() => container.read(jobSchedulerStatsProvider);

  group('lifecycle', () {
    test('starts idle', () {
      expect(stats().isRunning, isFalse);
      expect(stats().totalTests, 0);
    });

    test('runStarted seeds the totals and queues everything', () {
      notifier().runStarted(totalTests: 40, maxConcurrency: 8);
      expect(stats().isRunning, isTrue);
      expect(stats().totalTests, 40);
      expect(stats().maxConcurrency, 8);
      expect(stats().queuedTests, 40);
      expect(stats().completedTests, 0);
    });

    test('runFinished flips isRunning but keeps the tallies', () {
      notifier()
        ..runStarted(totalTests: 40, maxConcurrency: 8)
        ..progress(runningTests: 4, completedTests: 12, runtimeSeconds: 2)
        ..runFinished();

      expect(stats().isRunning, isFalse);
      expect(
        stats().completedTests,
        12,
        reason:
            'after a two-hour regression the numbers must not vanish '
            'the instant it completes',
      );
      expect(stats().totalTests, 40);
      expect(stats().runningTests, 0);
    });

    test('progress before a run started is ignored', () {
      notifier().progress(runningTests: 4, completedTests: 2);
      expect(stats().isRunning, isFalse);
      expect(stats().completedTests, 0);
    });

    test('a new run clears the previous run history', () {
      notifier()
        ..runStarted(totalTests: 10, maxConcurrency: 4)
        ..progress(runningTests: 2, completedTests: 5, runtimeSeconds: 3)
        ..runFinished()
        ..runStarted(totalTests: 20, maxConcurrency: 8);

      expect(stats().completedTests, 0);
      expect(stats().recentThroughput, isEmpty);
      expect(stats().meanRuntimeSeconds, 0);
    });
  });

  group('derived readings', () {
    test('queue depth is what has neither finished nor started', () {
      notifier()
        ..runStarted(totalTests: 40, maxConcurrency: 8)
        ..progress(runningTests: 8, completedTests: 12);
      expect(stats().queuedTests, 20);
    });

    test('queue depth never goes negative', () {
      notifier()
        ..runStarted(totalTests: 10, maxConcurrency: 8)
        ..progress(runningTests: 8, completedTests: 10);
      expect(stats().queuedTests, 0);
    });

    test('mean runtime averages the completions it was given', () {
      notifier()
        ..runStarted(totalTests: 3, maxConcurrency: 2)
        ..progress(runningTests: 1, completedTests: 1, runtimeSeconds: 2)
        ..progress(runningTests: 1, completedTests: 2, runtimeSeconds: 4);
      expect(stats().meanRuntimeSeconds, closeTo(3, 1e-9));
    });

    test('a progress update with no runtime does not disturb the mean', () {
      notifier()
        ..runStarted(totalTests: 3, maxConcurrency: 2)
        ..progress(runningTests: 1, completedTests: 1, runtimeSeconds: 4)
        ..progress(runningTests: 2, completedTests: 1);
      expect(stats().meanRuntimeSeconds, closeTo(4, 1e-9));
    });

    test('throughput is suppressed in the first instants of a run', () {
      // Dividing a completion count by a near-zero elapsed time yields a
      // throughput in the thousands, which renders as a spike that never
      // happened.
      notifier()
        ..runStarted(totalTests: 100, maxConcurrency: 8)
        ..progress(runningTests: 8, completedTests: 5);
      expect(stats().testsPerMinute, 0);
    });

    test('the throughput window is bounded', () {
      notifier().runStarted(totalTests: 5000, maxConcurrency: 8);
      for (var i = 1; i <= kJobThroughputWindow + 25; i++) {
        notifier().progress(runningTests: 8, completedTests: i);
      }
      expect(stats().recentThroughput.length, kJobThroughputWindow);
    });
  });
}
