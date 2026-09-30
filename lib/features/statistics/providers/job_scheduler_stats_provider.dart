// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

/// How many throughput samples the rolling window keeps.
const int kJobThroughputWindow = 60;

/// Live regression-scheduler state for the statistics strip.
///
/// Root-scope, not per-tab: there is one scheduler per app, and a strip
/// that reset its throughput history when the user switched tabs would be
/// measuring the wrong thing.
@immutable
class JobSchedulerStats {
  /// Creates a snapshot.
  const JobSchedulerStats({
    required this.runningTests,
    required this.maxConcurrency,
    required this.queuedTests,
    required this.completedTests,
    required this.totalTests,
    required this.testsPerMinute,
    required this.meanRuntimeSeconds,
    required this.recentThroughput,
    required this.isRunning,
  });

  /// The idle state.
  static const JobSchedulerStats idle = JobSchedulerStats(
    runningTests: 0,
    maxConcurrency: 0,
    queuedTests: 0,
    completedTests: 0,
    totalTests: 0,
    testsPerMinute: 0,
    meanRuntimeSeconds: 0,
    recentThroughput: <double>[],
    isRunning: false,
  );

  /// Tests executing right now.
  final int runningTests;

  /// Configured worker-pool ceiling.
  final int maxConcurrency;

  /// Tests admitted to the run but not yet started.
  final int queuedTests;

  /// Tests that have reported a terminal status.
  final int completedTests;

  /// Tests in the run.
  final int totalTests;

  /// Completion rate over the sampling window.
  final double testsPerMinute;

  /// Mean wall-clock runtime of completed tests, in seconds.
  final double meanRuntimeSeconds;

  /// Recent throughput samples, oldest first — the sparkline series.
  final List<double> recentThroughput;

  /// Whether a regression is in flight.
  ///
  /// Drives the strip's dimmed styling. The job segments stay *present*
  /// when idle rather than disappearing — a strip whose segment list
  /// changes length every time a run starts and stops makes the whole
  /// layout jump.
  final bool isRunning;

  @override
  String toString() =>
      'JobSchedulerStats(running: $runningTests/$maxConcurrency, '
      'queued: $queuedTests, done: $completedTests/$totalTests)';
}

/// Live scheduler statistics, root-scope.
///
/// Fed by `RegressionRunner` as it consumes the scheduler's event stream —
/// the runner already sees every `TestStarted` / `TestFinished`, so this
/// notifier observes rather than polls.
class JobSchedulerStatsNotifier extends Notifier<JobSchedulerStats> {
  final List<double> _throughput = <double>[];
  final List<double> _runtimes = <double>[];
  DateTime? _runStartedAt;

  @override
  JobSchedulerStats build() => JobSchedulerStats.idle;

  /// Marks the start of a run and clears the per-run history.
  void runStarted({required int totalTests, required int maxConcurrency}) {
    _throughput.clear();
    _runtimes.clear();
    _runStartedAt = DateTime.now();
    state = JobSchedulerStats(
      runningTests: 0,
      maxConcurrency: maxConcurrency,
      queuedTests: totalTests,
      completedTests: 0,
      totalTests: totalTests,
      testsPerMinute: 0,
      meanRuntimeSeconds: 0,
      recentThroughput: const <double>[],
      isRunning: true,
    );
  }

  /// Records progress mid-run.
  ///
  /// [runtimeSeconds] is the just-completed test's wall-clock duration, or
  /// null when this update is not a completion (a test starting, say).
  void progress({
    required int runningTests,
    required int completedTests,
    double? runtimeSeconds,
  }) {
    final started = _runStartedAt;
    if (started == null) return;

    if (runtimeSeconds != null) _runtimes.add(runtimeSeconds);

    final elapsedMinutes =
        DateTime.now().difference(started).inMilliseconds / 60000.0;
    // Guard the first instants of a run: dividing a completion count by a
    // near-zero elapsed time produces a throughput in the thousands, which
    // renders as a spike that never happened.
    final perMinute = elapsedMinutes < (1 / 60)
        ? 0.0
        : completedTests / elapsedMinutes;

    _throughput.add(perMinute);
    if (_throughput.length > kJobThroughputWindow) _throughput.removeAt(0);

    final meanRuntime = _runtimes.isEmpty
        ? 0.0
        : _runtimes.reduce((a, b) => a + b) / _runtimes.length;

    state = JobSchedulerStats(
      runningTests: runningTests,
      maxConcurrency: state.maxConcurrency,
      queuedTests: (state.totalTests - completedTests - runningTests).clamp(
        0,
        state.totalTests,
      ),
      completedTests: completedTests,
      totalTests: state.totalTests,
      testsPerMinute: perMinute,
      meanRuntimeSeconds: meanRuntime,
      recentThroughput: List<double>.unmodifiable(_throughput),
      isRunning: true,
    );
  }

  /// Marks the run finished.
  ///
  /// Keeps the final tallies visible and only flips [JobSchedulerStats.isRunning]
  /// — after a two-hour regression the last thing a user wants is for the
  /// numbers to vanish the instant it completes.
  void runFinished() {
    _runStartedAt = null;
    state = JobSchedulerStats(
      runningTests: 0,
      maxConcurrency: state.maxConcurrency,
      queuedTests: 0,
      completedTests: state.completedTests,
      totalTests: state.totalTests,
      testsPerMinute: state.testsPerMinute,
      meanRuntimeSeconds: state.meanRuntimeSeconds,
      recentThroughput: state.recentThroughput,
      isRunning: false,
    );
  }
}

/// The app-wide scheduler statistics.
final NotifierProvider<JobSchedulerStatsNotifier, JobSchedulerStats>
jobSchedulerStatsProvider =
    NotifierProvider<JobSchedulerStatsNotifier, JobSchedulerStats>(
      JobSchedulerStatsNotifier.new,
    );
