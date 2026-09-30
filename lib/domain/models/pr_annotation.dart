// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Discrete kinds of PR-side surfaces a [PrAnnotation] targets.
///
/// Mapped per-platform by the concrete dispatcher:
///
/// - GitHub: `annotation` and `status_check` route to the Checks
///   API; `comment` routes to the Issues / Pull Requests comments
///   endpoint.
/// - GitLab: `annotation` becomes a positional MR discussion thread;
///   `comment` becomes an MR note; `status_check` becomes a commit
///   pipeline status.
/// - Webhook: every kind is serialized into the same JSON payload
///   verbatim and POSTed to the receiver.
enum PrAnnotationTargetKind {
  /// Line-level (or range) inline annotation against the diff.
  annotation,

  /// A top-level comment on the PR / MR.
  comment,

  /// A status-check that gates merge eligibility.
  statusCheck,
}

/// Severity classification for an annotation.
///
/// Each platform's dispatcher maps this to its own concept:
///
/// - GitHub annotation_level: `error → failure`, `warning → warning`,
///   `notice → notice`.
/// - GitLab discussion title prefix: `[ERROR]` / `[WARNING]` /
///   `[NOTICE]`.
/// - Webhook payload: emitted verbatim as a string.
enum PrAnnotationSeverity {
  /// Surface as a build-blocking error.
  error,

  /// Surface as a warning that should be addressed but does not
  /// block merge.
  warning,

  /// Surface as informational.
  notice,
}

/// One annotation a [PrAnnotationDispatcher] should emit against a
/// PR / MR.
///
/// Plain immutable value type with no platform-specific fields
/// beyond [extraMetadata], which the concrete dispatcher reads to
/// satisfy platform-specific contracts (e.g. GitHub check-run
/// conclusion overrides, GitLab discussion thread ids).
@immutable
class PrAnnotation {
  /// Creates a [PrAnnotation].
  PrAnnotation({
    required this.targetKind,
    required this.severity,
    required this.title,
    required this.message,
    this.filePath,
    this.lineNumber,
    this.endLineNumber,
    Map<String, String> extraMetadata = const <String, String>{},
  }) : extraMetadata = Map<String, String>.unmodifiable(extraMetadata);

  /// Which PR-side surface this annotation targets.
  final PrAnnotationTargetKind targetKind;

  /// Severity classification.
  final PrAnnotationSeverity severity;

  /// Short heading — surfaces as the GitHub check-run "title" or
  /// the GitLab discussion title prefix.
  final String title;

  /// Body of the annotation. Supports limited markdown for
  /// GitHub / GitLab; webhook receivers see the raw string.
  final String message;

  /// Optional file path (relative to the repo root) for line-level
  /// annotations. Null for top-level comments / status checks.
  final String? filePath;

  /// Optional starting line number (1-based). Null when [filePath]
  /// is also null.
  final int? lineNumber;

  /// Optional ending line number (1-based) for range annotations.
  /// Null = single-line annotation at [lineNumber].
  final int? endLineNumber;

  /// Platform-specific extras the dispatcher reads to satisfy
  /// platform-specific contracts. Examples:
  ///
  /// - GitHub: `'check_run.conclusion'` overrides the auto-derived
  ///   pass/fail conclusion.
  /// - GitLab: `'discussion.thread_id'` continues an existing
  ///   thread instead of starting a new one.
  /// - Webhook: keys are emitted verbatim in the JSON payload's
  ///   `extras` field.
  final Map<String, String> extraMetadata;

  /// Returns a copy with the given fields replaced.
  PrAnnotation copyWith({
    PrAnnotationTargetKind? targetKind,
    PrAnnotationSeverity? severity,
    String? title,
    String? message,
    String? filePath,
    int? lineNumber,
    int? endLineNumber,
    Map<String, String>? extraMetadata,
  }) {
    return PrAnnotation(
      targetKind: targetKind ?? this.targetKind,
      severity: severity ?? this.severity,
      title: title ?? this.title,
      message: message ?? this.message,
      filePath: filePath ?? this.filePath,
      lineNumber: lineNumber ?? this.lineNumber,
      endLineNumber: endLineNumber ?? this.endLineNumber,
      extraMetadata: extraMetadata ?? this.extraMetadata,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PrAnnotation) return false;
    if (other.targetKind != targetKind) return false;
    if (other.severity != severity) return false;
    if (other.title != title) return false;
    if (other.message != message) return false;
    if (other.filePath != filePath) return false;
    if (other.lineNumber != lineNumber) return false;
    if (other.endLineNumber != endLineNumber) return false;
    if (other.extraMetadata.length != extraMetadata.length) return false;
    for (final entry in extraMetadata.entries) {
      if (other.extraMetadata[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    targetKind,
    severity,
    title,
    message,
    filePath,
    lineNumber,
    endLineNumber,
    extraMetadata.length,
  );

  @override
  String toString() =>
      'PrAnnotation($severity $targetKind: $title @ '
      '${filePath ?? '<top-level>'}:${lineNumber ?? '-'})';
}
