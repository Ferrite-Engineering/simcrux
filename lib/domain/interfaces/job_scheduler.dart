// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/test_result.dart';

/// Orchestrate a regression run: working-directory allocation,
/// concurrency control, resource-lock arbitration, per-test timeout
/// escalation, cancellation propagation, and event streaming to the
/// UI.
///
/// The open-core implementation is a semaphore-bounded local-process
/// pool; a remote-backend implementation (the Pro overlay's distributed
/// execution) plugs in without changing this interface.
abstract class JobScheduler {
  /// Submit a regression run. Returns a stream of [RegressionEvent]s
  /// — tests starting, log lines, results, and the final
  /// [RegressionFinished]. The stream completes when the run is
  /// done or fully cancelled.
  Stream<RegressionEvent> submit(RegressionRequest request);

  /// Cancel a running regression. All in-flight tests are killed
  /// gracefully (SIGTERM with escalation to SIGKILL on a short
  /// timeout). Resolves when every test has reported a terminal
  /// status.
  Future<void> cancel(String runId);

  /// Current status snapshot for [runId]. Used by the dashboard for
  /// polling and by the CLI for `simcrux status`.
  RegressionStatus statusOf(String runId);

  /// Resource locks held across all live runs. Read-only.
  Map<String, ResourceLock> get heldLocks;
}

/// A run's progress snapshot.
@immutable
class RegressionStatus {
  /// Creates a [RegressionStatus].
  const RegressionStatus({
    required this.runId,
    required this.totalTests,
    required this.completedTests,
    required this.runningTests,
    required this.isFinished,
  });

  /// Run identifier.
  final String runId;

  /// Total tests in the run.
  final int totalTests;

  /// Tests that have reported a terminal status.
  final int completedTests;

  /// Tests currently executing (running and reading the log stream).
  final int runningTests;

  /// True when every test has reported a terminal status.
  final bool isFinished;
}

/// Streamed event from `JobScheduler.submit`.
@immutable
sealed class RegressionEvent {
  /// Const default constructor.
  const RegressionEvent({required this.runId});

  /// Run this event belongs to.
  final String runId;
}

/// A test has been picked up by the worker pool and started.
@immutable
class TestStarted extends RegressionEvent {
  /// Creates a [TestStarted].
  const TestStarted({required super.runId, required this.testId});

  /// The `TestSpec.id` that started.
  final String testId;
}

/// A log line was captured from a running test.
@immutable
class TestLog extends RegressionEvent {
  /// Creates a [TestLog].
  const TestLog({
    required super.runId,
    required this.testId,
    required this.line,
    required this.fromStderr,
  });

  /// The `TestSpec.id` that emitted the line.
  final String testId;

  /// The raw line, without trailing newline.
  final String line;

  /// True for stderr; false for stdout.
  final bool fromStderr;
}

/// A test produced an intermediate status hint.
@immutable
class TestProgress extends RegressionEvent {
  /// Creates a [TestProgress].
  const TestProgress({
    required super.runId,
    required this.testId,
    required this.status,
  });

  /// The `TestSpec.id`.
  final String testId;

  /// The intermediate status (not yet terminal).
  final TestStatus status;
}

/// A test finished with a final classified result.
@immutable
class TestFinished extends RegressionEvent {
  /// Creates a [TestFinished].
  const TestFinished({required super.runId, required this.result});

  /// The classified, finalized result.
  final TestResult result;
}

/// The full run has finished (every test has reported a terminal
/// status or has been cancelled). Always the final event on the
/// stream.
@immutable
class RegressionFinished extends RegressionEvent {
  /// Creates a [RegressionFinished].
  const RegressionFinished({required super.runId, required this.cancelled});

  /// True when the run was cancelled by the user; false when every
  /// test finished naturally.
  final bool cancelled;
}
