// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/pr_annotation.dart';

/// Per-annotation outcome the dispatcher reports.
enum PrAnnotationDispatchOutcome {
  /// Successfully posted to the target platform.
  success,

  /// Skipped because the platform applied a rate limit. The
  /// dispatcher will not retry beyond its built-in backoff.
  rateLimited,

  /// Skipped because authentication failed (401 / 403). The whole
  /// batch is typically aborted with this outcome.
  authFailed,

  /// Skipped because of a transient network failure (timeout,
  /// connection reset, DNS error, etc.). The dispatcher retries
  /// these per its built-in backoff before reporting failure.
  networkError,

  /// Skipped because the platform returned a non-auth, non-retry
  /// error (malformed request, unknown endpoint, server-side
  /// validation failure, etc.).
  platformError,

  /// Skipped because the dispatcher chose not to send this
  /// annotation (e.g. unsupported targetKind for the platform).
  unsupported,
}

/// Outcome of dispatching a single [PrAnnotation].
@immutable
class PrAnnotationDispatchResult {
  /// Creates a [PrAnnotationDispatchResult].
  const PrAnnotationDispatchResult({
    required this.annotation,
    required this.outcome,
    this.statusCode,
    this.errorMessage,
  });

  /// The annotation that was attempted.
  final PrAnnotation annotation;

  /// What happened.
  final PrAnnotationDispatchOutcome outcome;

  /// HTTP status code returned by the platform, if applicable.
  /// Null for non-HTTP failure modes (DNS, timeout, unsupported).
  final int? statusCode;

  /// Diagnostic detail. Surfaces in the dispatch-result snackbar /
  /// log entry. Never contains the auth token or any other secret.
  final String? errorMessage;

  /// True when [outcome] is [PrAnnotationDispatchOutcome.success].
  bool get isSuccess => outcome == PrAnnotationDispatchOutcome.success;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrAnnotationDispatchResult &&
          other.annotation == annotation &&
          other.outcome == outcome &&
          other.statusCode == statusCode &&
          other.errorMessage == errorMessage;

  @override
  int get hashCode =>
      Object.hash(annotation, outcome, statusCode, errorMessage);

  @override
  String toString() =>
      'PrAnnotationDispatchResult($outcome'
      '${statusCode != null ? ' status=$statusCode' : ''}'
      '${errorMessage != null ? ' "$errorMessage"' : ''})';
}

/// Aggregate result of dispatching one batch of annotations.
@immutable
class PrAnnotationBatchResult {
  /// Creates a [PrAnnotationBatchResult].
  PrAnnotationBatchResult({
    required List<PrAnnotationDispatchResult> entries,
  }) : entries = List<PrAnnotationDispatchResult>.unmodifiable(entries);

  /// One outcome per attempted annotation.
  final List<PrAnnotationDispatchResult> entries;

  /// Number of annotations that successfully posted.
  int get successCount => entries.where((e) => e.isSuccess).length;

  /// Number of annotations that did not post.
  int get failureCount => entries.length - successCount;

  /// True when every attempted annotation succeeded.
  bool get allSucceeded => failureCount == 0 && entries.isNotEmpty;

  /// True when no annotations were attempted (zero-input batch).
  bool get isEmpty => entries.isEmpty;
}

/// Progress event the dispatcher's `progress` stream emits per
/// annotation as a long batch runs. Lets the UI surface progress
/// indicators without forcing callers to await the full
/// `dispatch` future.
@immutable
class PrAnnotationProgress {
  /// Creates a [PrAnnotationProgress].
  const PrAnnotationProgress({
    required this.completed,
    required this.total,
    required this.lastResult,
  });

  /// Number of annotations processed so far (1-based).
  final int completed;

  /// Total number of annotations in the batch.
  final int total;

  /// Outcome of the most recent annotation.
  final PrAnnotationDispatchResult lastResult;

  /// Convenience: `completed / total` clamped to `[0.0, 1.0]`.
  double get fraction => total == 0 ? 0.0 : (completed / total).clamp(0.0, 1.0);
}
