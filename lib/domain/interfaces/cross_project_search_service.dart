// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:simcrux/domain/models/cross_project_search_match.dart';
import 'package:simcrux/domain/models/cross_project_search_progress.dart';
import 'package:simcrux/domain/models/cross_project_search_query.dart';

/// Extension-point interface running cross-project search across
/// every currently-open project in the multi-project workspace.
///
/// Open-core ships [NoopCrossProjectSearchService] as the default
/// (zero matches, immediate complete). The Pro overlay overrides
/// `crossProjectSearchServiceProvider` with a streaming
/// background-isolate implementation that walks each open project
/// in parallel and emits matches as they are found.
///
/// **Streaming contract.** [search] is a single-shot stream — each
/// call returns a fresh stream. Matches arrive as workers find them;
/// the service never batches at the end. [progress] is a long-lived
/// broadcast stream that emits per-project lifecycle events for the
/// active search (the most recent [search] invocation).
///
/// **Cancellation.** Closing the matches stream (cancelling its
/// subscription) cancels the active search. The service also exposes
/// [cancelActiveSearch] for explicit cancellation paths that don't
/// own the matches subscription (e.g. the dialog closing while still
/// holding the future, the user re-typing to trigger a fresh search
/// before the previous one drains).
abstract class CrossProjectSearchService {
  /// Run [query] across every open project. Returns a single-subscription
  /// stream that emits matches as workers find them and closes when
  /// every per-project worker has completed (or the search has been
  /// cancelled).
  ///
  /// An empty pattern emits zero matches and closes immediately. A
  /// query against an empty workspace emits zero matches and closes
  /// immediately (the [progress] stream surfaces
  /// [CrossProjectSearchProgress.emptyWorkspace] in that case).
  Stream<CrossProjectSearchMatch> search(CrossProjectSearchQuery query);

  /// Per-project lifecycle events for the active search. Broadcast
  /// stream — multiple listeners are supported (the dialog subscribes
  /// the header indicators separately from the body).
  ///
  /// New subscribers do NOT replay past events. Subscribe before
  /// calling [search] to capture the full lifecycle.
  Stream<CrossProjectSearchProgress> get progress;

  /// Cancel the active search. Workers signal cancellation through
  /// their cancellation flag; pending matches may still arrive
  /// briefly before each worker's cleanup completes, but no further
  /// matches are emitted once each worker has acknowledged.
  ///
  /// No-op when no search is active.
  Future<void> cancelActiveSearch();
}

/// Open-core default. Emits zero matches and a single
/// [CrossProjectSearchProgress.emptyWorkspace] event so consumers
/// can wire the service unconditionally — the Pro overlay activates
/// real cross-project search via `proOverrides`.
class NoopCrossProjectSearchService implements CrossProjectSearchService {
  /// Creates a [NoopCrossProjectSearchService].
  NoopCrossProjectSearchService();

  final StreamController<CrossProjectSearchProgress> _progress =
      StreamController<CrossProjectSearchProgress>.broadcast();

  @override
  Stream<CrossProjectSearchMatch> search(CrossProjectSearchQuery query) {
    // Schedule the emptyWorkspace progress event on a microtask so
    // subscribers added in the same tick as the call still observe it.
    scheduleMicrotask(() {
      if (!_progress.isClosed) {
        _progress.add(CrossProjectSearchProgress.emptyWorkspace);
      }
    });
    return const Stream<CrossProjectSearchMatch>.empty();
  }

  @override
  Stream<CrossProjectSearchProgress> get progress => _progress.stream;

  @override
  Future<void> cancelActiveSearch() async {
    // Noop service has nothing to cancel.
  }

  /// Disposes the internal progress broadcast controller. Tests
  /// invoke this to keep the analyzer happy; production callers do
  /// not own the noop instance directly (Riverpod manages it).
  Future<void> dispose() async {
    if (!_progress.isClosed) {
      await _progress.close();
    }
  }
}
