// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderFamily;
import 'package:meta/meta.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

/// Coalescing window for log-driven provider invalidation. A chatty
/// testbench can emit thousands of lines per second; invalidating per
/// line would recompute (and re-render) the log surfaces per line. The
/// first line after a quiet period arms a one-shot timer; every line
/// inside the window rides along, so the UI refreshes at most
/// ~12 Hz per buffer while staying visibly live.
const Duration kLogInvalidationCoalesceWindow = Duration(milliseconds: 80);

/// Subscribes [ref] to [buffer]'s append stream, coalescing bursts of
/// appended lines into at most one [Ref.invalidateSelf] per
/// [kLogInvalidationCoalesceWindow]. Shared by both log providers.
void _invalidateOnAppendCoalesced(Ref ref, LogBuffer buffer) {
  Timer? pending;
  final sub = buffer.stream.listen((_) {
    pending ??= Timer(kLogInvalidationCoalesceWindow, ref.invalidateSelf);
  });
  ref.onDispose(() {
    pending?.cancel();
    unawaited(sub.cancel());
  });
}

/// Arguments to [inspectorLogSnapshotProvider].
@immutable
class InspectorLogArgs {
  /// Creates an [InspectorLogArgs].
  const InspectorLogArgs({
    required this.testId,
    required this.tailLineCount,
  });

  /// The test whose buffer to read.
  final String testId;

  /// How many trailing lines to retain on the returned snapshot.
  final int tailLineCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InspectorLogArgs &&
          other.testId == testId &&
          other.tailLineCount == tailLineCount;

  @override
  int get hashCode => Object.hash(testId, tailLineCount);
}

/// Snapshot of a test's captured log: the tail of buffered lines plus
/// metadata for the "(N earlier lines elided)" caption.
@immutable
class InspectorLogSnapshot {
  /// Creates an [InspectorLogSnapshot].
  InspectorLogSnapshot({
    required List<LogLine> tailLines,
    required this.totalLineCount,
    required this.droppedCount,
  }) : tailLines = List<LogLine>.unmodifiable(tailLines);

  /// The (up to) `tailLineCount` most-recent lines from the
  /// buffer, oldest first.
  final List<LogLine> tailLines;

  /// Total number of lines currently buffered (post-truncation).
  final int totalLineCount;

  /// Number of lines that have been dropped from the head of the
  /// buffer due to the per-test line cap.
  final int droppedCount;

  /// True when the buffer has no lines whatsoever.
  bool get isEmpty => tailLines.isEmpty;
}

/// Live tail of the per-test log buffer, capped at the family
/// parameter's `tailLineCount` lines.
final ProviderFamily<InspectorLogSnapshot, InspectorLogArgs>
inspectorLogSnapshotProvider =
    Provider.family<InspectorLogSnapshot, InspectorLogArgs>(
      inspectorLogSnapshot,
    );

/// Body of [inspectorLogSnapshotProvider]. Exposed as a top-level
/// function so `simcruxTabOverridesFactory` can override the provider
/// per-tab with the same implementation.
///
/// Subscribes to the underlying [LogBuffer.stream] so appended lines
/// trigger a [Ref.invalidateSelf] — coalesced to at most one
/// invalidation per [kLogInvalidationCoalesceWindow], so a chatty
/// testbench cannot force a recompute per line — and the next
/// `ref.watch` picks up the fresh snapshot and the inspector tail
/// re-renders. Without the subscription the provider would only
/// re-evaluate on [resultStoreProvider] changes, leaving the snapshot
/// frozen at whatever the buffer held when the active store was
/// published (almost always empty, since the runner publishes the
/// store before the test emits its first log line).
///
/// The buffer is eagerly created via [LogBufferStore.bufferFor] so
/// the subscription can attach before any line lands; without that
/// hop the buffer may not exist yet when the notifier first runs.
InspectorLogSnapshot inspectorLogSnapshot(Ref ref, InspectorLogArgs args) {
  final store = ref.watch(resultStoreProvider);
  if (store is! InMemoryResultStore) {
    return InspectorLogSnapshot(
      tailLines: const <LogLine>[],
      totalLineCount: 0,
      droppedCount: 0,
    );
  }
  final buffer = store.logBufferStore.bufferFor(args.testId);
  _invalidateOnAppendCoalesced(ref, buffer);

  final all = buffer.snapshot;
  final start = all.length > args.tailLineCount
      ? all.length - args.tailLineCount
      : 0;
  final tail = all.sublist(start);
  return InspectorLogSnapshot(
    tailLines: tail,
    totalLineCount: all.length,
    droppedCount: buffer.droppedCount,
  );
}

/// Live `LogBuffer` snapshot stream for the built-in log viewer.
/// Returns the full buffer (not just the tail).
final ProviderFamily<List<LogLine>, String> fullInspectorLogProvider =
    Provider.family<List<LogLine>, String>(fullInspectorLog);

/// Body of [fullInspectorLogProvider]. Exposed as a top-level function
/// so `simcruxTabOverridesFactory` can override the provider per-tab
/// with the same implementation.
///
/// Subscribes to the underlying [LogBuffer.stream] so appended lines
/// trigger a coalesced [Ref.invalidateSelf] (at most one per
/// [kLogInvalidationCoalesceWindow]) — see [inspectorLogSnapshot] for
/// the full rationale.
List<LogLine> fullInspectorLog(Ref ref, String testId) {
  final store = ref.watch(resultStoreProvider);
  if (store is! InMemoryResultStore) return const <LogLine>[];
  final buffer = store.logBufferStore.bufferFor(testId);
  _invalidateOnAppendCoalesced(ref, buffer);
  return buffer.snapshot;
}
