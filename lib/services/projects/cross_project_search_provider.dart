// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/cross_project_search_service.dart';
import 'package:simcrux/domain/models/cross_project_search_match.dart';
import 'package:simcrux/domain/models/cross_project_search_progress.dart';
import 'package:simcrux/domain/models/cross_project_search_query.dart';

/// Extension-point seam for the active [CrossProjectSearchService].
///
/// **Open-core default.** Returns [NoopCrossProjectSearchService] —
/// zero matches; immediate complete with a single
/// [CrossProjectSearchProgress.emptyWorkspace] event on the progress
/// stream. Open-core does not own a multi-project surface, so
/// cross-project search is a no-op in the open-core build.
///
/// **Pro override.** The Pro overlay registers
/// `ProCrossProjectSearchService`, which runs each open project's
/// search in a background isolate, streams matches as they arrive,
/// and emits per-project lifecycle events on the progress stream.
final Provider<CrossProjectSearchService> crossProjectSearchServiceProvider =
    Provider<CrossProjectSearchService>(
      (_) => NoopCrossProjectSearchService(),
    );

/// Immutable snapshot of the cross-project search UI state.
///
/// Held in [activeCrossProjectSearchProvider] so the dialog can
/// detach and re-attach without losing accumulated matches. The
/// dialog's typical lifecycle is: open → user types pattern →
/// dialog dispatches a [search] → matches accumulate here → user
/// closes dialog → state remains so re-opening with the same
/// pattern shows the prior results immediately while the next
/// search re-runs.
class CrossProjectSearchState {
  /// Creates a [CrossProjectSearchState].
  CrossProjectSearchState({
    this.query = const CrossProjectSearchQuery(pattern: ''),
    List<CrossProjectSearchMatch>? matches,
    Map<String, CrossProjectSearchProgress>? progressByProject,
    this.isSearching = false,
  }) : matches = List<CrossProjectSearchMatch>.unmodifiable(
         matches ?? const <CrossProjectSearchMatch>[],
       ),
       progressByProject = Map<String, CrossProjectSearchProgress>.unmodifiable(
         progressByProject ?? const <String, CrossProjectSearchProgress>{},
       );

  /// Convenience: the empty / idle state.
  factory CrossProjectSearchState.idle() => CrossProjectSearchState();

  /// The pattern + scope of the active or most-recent search.
  final CrossProjectSearchQuery query;

  /// Accumulated matches across every project's worker.
  final List<CrossProjectSearchMatch> matches;

  /// Most recent progress event per project. The dialog renders
  /// per-project headers off of this map; the latest event for a
  /// given project id overwrites any prior event for that project.
  final Map<String, CrossProjectSearchProgress> progressByProject;

  /// True while at least one project's worker is still emitting.
  final bool isSearching;

  /// Field-by-field copy with optional overrides.
  CrossProjectSearchState copyWith({
    CrossProjectSearchQuery? query,
    List<CrossProjectSearchMatch>? matches,
    Map<String, CrossProjectSearchProgress>? progressByProject,
    bool? isSearching,
  }) {
    return CrossProjectSearchState(
      query: query ?? this.query,
      matches: matches ?? this.matches,
      progressByProject: progressByProject ?? this.progressByProject,
      isSearching: isSearching ?? this.isSearching,
    );
  }
}

/// Notifier managing the [CrossProjectSearchState] lifecycle. The
/// dialog reads the state and dispatches mutations via the notifier.
///
/// Open-core ships an empty-state default; the dialog, and every read
/// and mutation of this state, lives in the Pro overlay. No open-core
/// code reads it: the Search Across Projects action dispatches through
/// `crossProjectSearchOpenerProvider`, which defaults to null.
class CrossProjectSearchNotifier extends Notifier<CrossProjectSearchState> {
  @override
  CrossProjectSearchState build() => CrossProjectSearchState.idle();

  /// Reset the state to idle (used when the dialog closes or when
  /// the user explicitly clears the search).
  void reset() {
    state = CrossProjectSearchState.idle();
  }

  /// Begin a search with [query]. Clears the prior matches and
  /// progress so the dialog renders the new search from scratch.
  /// Setting [isSearching] to `true` arms the busy indicator; the
  /// dispatcher transitions back to `false` when the service
  /// streams close.
  void startSearch(CrossProjectSearchQuery query) {
    state = CrossProjectSearchState(
      query: query,
      isSearching: true,
    );
  }

  /// Append a match to the accumulated list.
  void appendMatch(CrossProjectSearchMatch match) {
    final next = List<CrossProjectSearchMatch>.from(state.matches)..add(match);
    state = state.copyWith(matches: next);
  }

  /// Record / overwrite the most recent progress event for the
  /// emitting project.
  void updateProgress(CrossProjectSearchProgress progress) {
    final next = Map<String, CrossProjectSearchProgress>.from(
      state.progressByProject,
    );
    next[progress.projectId] = progress;
    state = state.copyWith(progressByProject: next);
  }

  /// Mark the search as finished. The dialog uses this transition
  /// to swap the spinner for the final "N matches" status text.
  void completeSearch() {
    state = state.copyWith(isSearching: false);
  }
}

/// Active cross-project search state. Held at the app level so the
/// dialog can close and re-open without losing accumulated matches.
final NotifierProvider<CrossProjectSearchNotifier, CrossProjectSearchState>
activeCrossProjectSearchProvider =
    NotifierProvider<CrossProjectSearchNotifier, CrossProjectSearchState>(
      CrossProjectSearchNotifier.new,
    );
