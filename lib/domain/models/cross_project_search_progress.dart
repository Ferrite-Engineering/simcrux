// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Lifecycle phase of a single project's search worker.
enum CrossProjectSearchProgressStatus {
  /// Worker is alive and emitting matches.
  searching,

  /// Worker finished successfully. No further matches will arrive
  /// for this project.
  completed,

  /// Worker emitted a failure (manifest unreadable, store throw,
  /// directory walk fail, …). The dialog UI surfaces this as a
  /// per-project error banner with a "Retry" affordance.
  failed,

  /// Worker was cancelled (host called
  /// [CrossProjectSearchService.cancelActiveSearch] or replaced the
  /// search mid-flight). No further matches will arrive for this
  /// project.
  cancelled,
}

/// Per-project status update streamed by
/// [CrossProjectSearchService.progress].
///
/// The dialog UI uses this to render the per-project header
/// indicators ("Searching…", "12 matches", "Search failed"). The
/// service does not interleave per-project progress events with
/// match events on the same stream — workers post matches on the
/// matches stream and status events on the progress stream so
/// consumers can subscribe to either independently.
@immutable
class CrossProjectSearchProgress {
  /// Creates a [CrossProjectSearchProgress].
  const CrossProjectSearchProgress({
    required this.projectId,
    required this.projectName,
    required this.status,
    this.matchCount = 0,
    this.truncated = false,
    this.error,
  });

  /// Convenience: progress event signaling the empty-workspace
  /// case (no projects to search). [projectId] / [projectName] are
  /// the empty sentinel values; consumers route on this exclusively
  /// via [status] == completed combined with the absence of any
  /// `searching` event ever seen.
  static const CrossProjectSearchProgress emptyWorkspace =
      CrossProjectSearchProgress(
        projectId: '',
        projectName: '',
        status: CrossProjectSearchProgressStatus.completed,
      );

  /// Stable id of the project this progress event describes.
  final String projectId;

  /// Display name of the project at the moment the event was
  /// emitted.
  final String projectName;

  /// Lifecycle phase of the project's worker.
  final CrossProjectSearchProgressStatus status;

  /// Running count of matches the worker has emitted for this
  /// project so far. Increments as matches stream; the dialog UI
  /// reads this to render per-project hit counts without buffering
  /// the matches stream.
  final int matchCount;

  /// True when the worker stopped emitting matches because the
  /// per-project limit was reached. The dialog UI annotates the
  /// project header with a "≥N matches" indicator in that case.
  final bool truncated;

  /// Human-readable error message, set only when [status] ==
  /// [CrossProjectSearchProgressStatus.failed]. The dialog UI shows
  /// this verbatim in the per-project error banner.
  final String? error;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CrossProjectSearchProgress &&
        other.projectId == projectId &&
        other.projectName == projectName &&
        other.status == status &&
        other.matchCount == matchCount &&
        other.truncated == truncated &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
    projectId,
    projectName,
    status,
    matchCount,
    truncated,
    error,
  );

  @override
  String toString() =>
      'CrossProjectSearchProgress(project: $projectName ($projectId), '
      'status: ${status.name}, matches: $matchCount, truncated: $truncated)';
}
