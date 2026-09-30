// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Discriminated union pointing at the object that produced a
/// [CrossProjectSearchMatch]. The dialog's click-to-jump dispatcher
/// pattern-matches on the runtime type to select the right
/// navigation handler — switch to the project, then surface the
/// specific test / failure / source file.
///
/// The target is intentionally opaque to the open-core service
/// surface: open-core ships the type vocabulary, the Pro overlay
/// (and any future Crux peer integration) is free to populate it
/// from whatever its registries hold.
@immutable
sealed class CrossProjectSearchTarget {
  /// Const constructor for [CrossProjectSearchTarget] subclasses.
  const CrossProjectSearchTarget();

  /// Type discriminator written into the JSON payload. Stable
  /// strings (not enum indexes) so isolate-boundary serialization
  /// survives across schema additions.
  String get kind;

  /// JSON serialization for crossing the isolate boundary.
  Map<String, Object?> toJson();

  /// Tolerant JSON parser. Unknown `kind` values return `null`.
  static CrossProjectSearchTarget? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    if (kind is! String) return null;
    switch (kind) {
      case 'test':
        return CrossProjectSearchTestTarget._fromJson(raw);
      case 'failure':
        return CrossProjectSearchFailureTarget._fromJson(raw);
      case 'source_file':
        return CrossProjectSearchSourceFileTarget._fromJson(raw);
      default:
        return null;
    }
  }
}

/// Points at a `TestSpec` (or `TestResult.testId`). Click-to-jump
/// switches the active project then selects the test row in the
/// dashboard.
@immutable
class CrossProjectSearchTestTarget extends CrossProjectSearchTarget {
  /// Creates a [CrossProjectSearchTestTarget].
  const CrossProjectSearchTestTarget({
    required this.testId,
    this.runId,
  });

  /// `TestSpec.id` for the matched test.
  final String testId;

  /// Run that produced the test list, when known. The dashboard
  /// scrolls to the test inside this run; `null` falls back to the
  /// most recent run.
  final String? runId;

  @override
  String get kind => 'test';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'test_id': testId,
    'run_id': runId,
  };

  static CrossProjectSearchTestTarget? _fromJson(Map<Object?, Object?> raw) {
    final testId = raw['test_id'];
    if (testId is! String || testId.isEmpty) return null;
    final runIdRaw = raw['run_id'];
    return CrossProjectSearchTestTarget(
      testId: testId,
      runId: runIdRaw is String ? runIdRaw : null,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CrossProjectSearchTestTarget &&
        other.testId == testId &&
        other.runId == runId;
  }

  @override
  int get hashCode => Object.hash('test', testId, runId);

  @override
  String toString() =>
      'CrossProjectSearchTestTarget(testId: $testId, runId: $runId)';
}

/// Points at a specific failure inside a specific run. Click-to-jump
/// surfaces the test's failure detail.
@immutable
class CrossProjectSearchFailureTarget extends CrossProjectSearchTarget {
  /// Creates a [CrossProjectSearchFailureTarget].
  const CrossProjectSearchFailureTarget({
    required this.testId,
    required this.runId,
    required this.failureMessage,
  });

  /// `TestSpec.id` whose failure matched.
  final String testId;

  /// `TestRun.id` for the run that produced the failure.
  final String runId;

  /// The matched failure-message text. Stored on the target so the
  /// detail surface does not need to re-query the result store to
  /// know what to highlight.
  final String failureMessage;

  @override
  String get kind => 'failure';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'test_id': testId,
    'run_id': runId,
    'failure_message': failureMessage,
  };

  static CrossProjectSearchFailureTarget? _fromJson(Map<Object?, Object?> raw) {
    final testId = raw['test_id'];
    final runId = raw['run_id'];
    final failureMessage = raw['failure_message'];
    if (testId is! String || testId.isEmpty) return null;
    if (runId is! String || runId.isEmpty) return null;
    if (failureMessage is! String) return null;
    return CrossProjectSearchFailureTarget(
      testId: testId,
      runId: runId,
      failureMessage: failureMessage,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CrossProjectSearchFailureTarget &&
        other.testId == testId &&
        other.runId == runId &&
        other.failureMessage == failureMessage;
  }

  @override
  int get hashCode => Object.hash('failure', testId, runId, failureMessage);

  @override
  String toString() =>
      'CrossProjectSearchFailureTarget(testId: $testId, runId: $runId)';
}

/// Points at a source file (and optionally a line) inside the
/// project tree. Click-to-jump opens the file in whichever surface
/// the host can serve (source pane when available, otherwise reveal
/// in finder).
@immutable
class CrossProjectSearchSourceFileTarget extends CrossProjectSearchTarget {
  /// Creates a [CrossProjectSearchSourceFileTarget].
  const CrossProjectSearchSourceFileTarget({
    required this.filePath,
    this.line,
  });

  /// Absolute path to the matched source file.
  final String filePath;

  /// 1-indexed line number when the match is more specific than the
  /// whole-file level; `null` for whole-path matches.
  final int? line;

  @override
  String get kind => 'source_file';

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'file_path': filePath,
    'line': line,
  };

  static CrossProjectSearchSourceFileTarget? _fromJson(
    Map<Object?, Object?> raw,
  ) {
    final filePath = raw['file_path'];
    if (filePath is! String || filePath.isEmpty) return null;
    final lineRaw = raw['line'];
    final line = lineRaw is int ? lineRaw : null;
    return CrossProjectSearchSourceFileTarget(
      filePath: filePath,
      line: line,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CrossProjectSearchSourceFileTarget &&
        other.filePath == filePath &&
        other.line == line;
  }

  @override
  int get hashCode => Object.hash('source_file', filePath, line);

  @override
  String toString() =>
      'CrossProjectSearchSourceFileTarget(filePath: $filePath, line: $line)';
}
