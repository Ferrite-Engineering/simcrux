// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pr_annotation.dart';
import 'package:simcrux/domain/models/test_result.dart';

/// Turns a finished regression's results into the [PrAnnotation] batch a
/// dispatcher posts.
///
/// Pure and open-core: no I/O, no platform knowledge, no tier gate. The
/// Pro overlay owns *where* annotations go; what they say is ordinary
/// logic worth testing without a network.
///
/// ### What it emits
///
/// 1. **One status check** summarising the run — this is the annotation a
///    required-status-check gates on.
/// 2. **One annotation per failing test**, up to [maxFailureAnnotations].
///
/// Passing tests produce nothing. A PR comment listing four hundred
/// passing tests is noise that trains people to collapse the whole
/// section, which then hides the failures too.
///
/// ### Why failures are capped
///
/// GitHub's Checks API accepts 50 annotations per request, and a run
/// where nine hundred tests fail is a broken build, not nine hundred
/// separate problems — the first few plus an accurate count is strictly
/// more useful than a wall. When the cap truncates, the status check's
/// summary says so explicitly rather than silently showing a subset:
/// silent truncation reads as "these are all the failures", which is the
/// same false-clean failure mode the CLI exit codes were designed to
/// avoid.
@immutable
class RunAnnotationBuilder {
  /// Creates a builder.
  const RunAnnotationBuilder({
    this.maxFailureAnnotations = 25,
    this.checkName = 'SimCrux regression',
  });

  /// Ceiling on per-failure annotations. Default 25 — half of GitHub's
  /// 50-per-request limit, leaving headroom for the status check and any
  /// dispatcher-side additions without a second request.
  final int maxFailureAnnotations;

  /// Title used for the summary status check.
  final String checkName;

  /// Statuses that count as a failure for gating purposes.
  ///
  /// `timeout` is included: a test killed by the watchdog did not pass,
  /// and letting a timeout slide through a merge gate is exactly how a
  /// hanging test becomes permanent. `cancelled` is excluded — the user
  /// stopped the run, which is not a verdict about the design. `unknown`
  /// is included, because a result the detector could not classify is
  /// not evidence of success.
  static const Set<TestStatus> failingStatuses = <TestStatus>{
    TestStatus.fail,
    TestStatus.timeout,
    TestStatus.unknown,
  };

  /// Builds the batch for [results].
  ///
  /// [runId] is echoed into the status check body so a reader can find
  /// the run locally. [cancelled] downgrades the status check to a
  /// notice — a cancelled run is not a failed one, and marking it
  /// failed would teach people to ignore the check.
  List<PrAnnotation> build({
    required List<TestResult> results,
    required String runId,
    bool cancelled = false,
  }) {
    final failures = results
        .where((r) => failingStatuses.contains(r.status))
        .toList(growable: false);
    final passed = results.where((r) => r.status == TestStatus.pass).length;
    final skipped = results.where((r) => r.status == TestStatus.skipped).length;

    final annotations = <PrAnnotation>[
      _statusCheck(
        runId: runId,
        total: results.length,
        passed: passed,
        skipped: skipped,
        failures: failures,
        cancelled: cancelled,
      ),
    ];

    for (final failure in failures.take(maxFailureAnnotations)) {
      annotations.add(_failureAnnotation(failure));
    }
    return List<PrAnnotation>.unmodifiable(annotations);
  }

  PrAnnotation _statusCheck({
    required String runId,
    required int total,
    required int passed,
    required int skipped,
    required List<TestResult> failures,
    required bool cancelled,
  }) {
    final buffer = StringBuffer()..writeln('$passed of $total tests passed.');
    if (failures.isNotEmpty) {
      buffer.writeln('${failures.length} failed.');
    }
    if (skipped > 0) {
      buffer.writeln('$skipped skipped.');
    }
    if (cancelled) {
      buffer.writeln(
        'The run was cancelled before finishing, so these totals are '
        'partial.',
      );
    }
    if (failures.length > maxFailureAnnotations) {
      // Say it out loud. A truncated list that does not announce itself
      // is indistinguishable from a complete one.
      buffer.writeln(
        'Showing the first $maxFailureAnnotations of ${failures.length} '
        'failures as inline annotations.',
      );
    }
    buffer.write('Run $runId.');

    final PrAnnotationSeverity severity;
    if (cancelled) {
      severity = PrAnnotationSeverity.notice;
    } else if (failures.isNotEmpty) {
      severity = PrAnnotationSeverity.error;
    } else {
      severity = PrAnnotationSeverity.notice;
    }

    return PrAnnotation(
      targetKind: PrAnnotationTargetKind.statusCheck,
      severity: severity,
      title: checkName,
      message: buffer.toString(),
      extraMetadata: <String, String>{
        'simcrux.run_id': runId,
        'simcrux.total': '$total',
        'simcrux.passed': '$passed',
        'simcrux.failed': '${failures.length}',
        'simcrux.skipped': '$skipped',
        if (cancelled) 'simcrux.cancelled': 'true',
      },
    );
  }

  PrAnnotation _failureAnnotation(TestResult result) {
    final reason = switch (result.status) {
      TestStatus.timeout => 'timed out',
      TestStatus.unknown => 'produced an unclassifiable result',
      _ => 'failed',
    };
    final buffer = StringBuffer('${result.testId} $reason');
    if (result.exitCode != null) {
      buffer.write(' (exit ${result.exitCode})');
    }
    buffer.write('.');
    if (result.failureMessage != null &&
        result.failureMessage!.trim().isNotEmpty) {
      buffer
        ..writeln()
        ..writeln()
        ..write(result.failureMessage!.trim());
    }
    if (result.executionSeed != null) {
      // The single most useful thing a reviewer can be handed: the exact
      // reproduction command, not a description of one.
      buffer
        ..writeln()
        ..writeln()
        ..write(
          'Reproduce: simcrux --filter ${result.testId} '
          '(seed ${result.executionSeed}).',
        );
    }

    return PrAnnotation(
      targetKind: PrAnnotationTargetKind.annotation,
      severity: PrAnnotationSeverity.error,
      title: result.testId,
      // Deliberately no filePath / lineNumber. A test result knows its
      // log path, not the diff line that caused it, and GitHub silently
      // drops annotations whose path is not in the PR's changed files —
      // so a guessed path produces annotations that vanish. Top-level is
      // honest and always renders.
      message: buffer.toString(),
      extraMetadata: <String, String>{
        'simcrux.test_id': result.testId,
        'simcrux.status': result.status.name,
        if (result.executionSeed != null)
          'simcrux.seed': '${result.executionSeed}',
        if (result.waveformPath != null)
          'simcrux.waveform': result.waveformPath!,
      },
    );
  }
}
