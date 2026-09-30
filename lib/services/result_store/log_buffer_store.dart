// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:collection';

/// Per-test stdout/stderr log buffer.
///
/// The scheduler streams `TestLogLine` events into one [LogBuffer] per
/// running test; the inspector pane and the built-in log viewer
/// subscribe to the same buffer via [LogBufferStore.stream] (which
/// surfaces incremental appends) or [LogBufferStore.snapshot] (one
/// shot, current contents).
///
/// In-memory only — the buffer is bounded by `maxLines` to keep RSS
/// flat across very long regressions. Lines beyond `maxLines` are
/// dropped from the head (oldest first) and a count is exposed via
/// [LogBuffer.droppedCount] so the UI can surface "(N earlier lines
/// elided)".
///
/// Backed by a [ListQueue] so the at-capacity steady state is O(1) per
/// appended line (head drop + tail add); a plain [List] with
/// `removeRange` shifts every retained element on every append once
/// the buffer is full.
class LogBuffer {
  /// Creates a [LogBuffer].
  ///
  /// [initialDroppedCount] seeds [droppedCount] — used when the store
  /// re-creates a buffer whose predecessor was evicted, so the pane's
  /// "(N earlier lines elided)" note still counts the lines that existed.
  LogBuffer({this.maxLines = 5000, int initialDroppedCount = 0})
    : _dropped = initialDroppedCount;

  /// Maximum buffered lines per test. Older lines fall off the head.
  final int maxLines;

  final ListQueue<LogLine> _lines = ListQueue<LogLine>();
  int _dropped;

  /// Monotonic append counter; lets [snapshot] reuse its last-built
  /// list when nothing changed in between.
  int _version = 0;
  int _snapshotVersion = -1;
  List<LogLine> _snapshotCache = const <LogLine>[];

  final StreamController<LogLine> _controller =
      StreamController<LogLine>.broadcast();

  /// Append a single line to the buffer. Triggers any active
  /// listeners via [stream].
  void append({required String line, required bool fromStderr}) {
    final entry = LogLine(line: line, fromStderr: fromStderr);
    _lines.addLast(entry);
    while (_lines.length > maxLines) {
      _lines.removeFirst();
      _dropped++;
    }
    _version++;
    if (!_controller.isClosed) _controller.add(entry);
  }

  /// Current contents (oldest first). Returns an unmodifiable view.
  ///
  /// The list is rebuilt only when the buffer changed since the last
  /// call — repeated reads of an unchanged buffer return the identical
  /// instance, so callers polling on a coalescing timer don't pay a
  /// per-read copy.
  List<LogLine> get snapshot {
    if (_snapshotVersion != _version) {
      _snapshotCache = List<LogLine>.unmodifiable(_lines);
      _snapshotVersion = _version;
    }
    return _snapshotCache;
  }

  /// Number of lines currently buffered (post-truncation). Cheap —
  /// does not materialize [snapshot].
  int get lineCount => _lines.length;

  /// Number of lines dropped due to [maxLines] truncation.
  int get droppedCount => _dropped;

  /// Live append stream. Closed when [close] is called.
  Stream<LogLine> get stream => _controller.stream;

  /// Whether anyone is currently subscribed to [stream] — the inspector
  /// pane or the full log viewer watching this test. The store refuses to
  /// evict a buffer someone is reading.
  bool get hasListener => _controller.hasListener;

  /// Closes the append stream. The snapshot remains readable.
  Future<void> close() => _controller.close();
}

/// One captured log line.
class LogLine {
  /// Creates a [LogLine].
  const LogLine({required this.line, required this.fromStderr});

  /// The raw line, without trailing newline.
  final String line;

  /// True if the line came from stderr, false for stdout.
  final bool fromStderr;
}

/// Maps `testId` → [LogBuffer]. Owned by the in-memory result store.
///
/// **Two bounds, not one.** Each [LogBuffer] caps its own lines, but the
/// *number* of buffers used to be unbounded: one ring per test in the run,
/// each holding up to `maxLinesPerTest`. A 2 000-test regression where every
/// test fills its ring retains 2 000 × 5 000 = 10 000 000 `LogLine`s, which
/// is a few hundred MB of live objects for logs whose full text is already
/// on disk in the run's ndjson. So the store bounds the retained set too:
/// at most [maxBufferedTests] buffers and [maxTotalLines] lines across all
/// of them, whichever binds first.
///
/// Eviction is least-recently-used — `Map` preserves insertion order and
/// [bufferFor] / [tryGet] re-insert on access, the same shape the netlist
/// renderer's label-layout cache uses. A buffer with a live [
/// LogBuffer.stream] listener (the inspector pane, the full log viewer) is
/// never evicted, so the log being read cannot be pulled out from under it.
/// An evicted test's line count is remembered, so if the user opens that
/// test later the fresh buffer reports those lines through
/// [LogBuffer.droppedCount] and the pane says "(N earlier lines elided)"
/// rather than showing a silently empty log.
class LogBufferStore {
  /// Creates an empty [LogBufferStore].
  LogBufferStore({
    this.maxLinesPerTest = 5000,
    this.maxBufferedTests = 256,
    this.maxTotalLines = 200000,
  });

  /// Per-buffer line cap; pushed through to each lazily-created
  /// [LogBuffer].
  final int maxLinesPerTest;

  /// Maximum number of per-test buffers retained at once.
  final int maxBufferedTests;

  /// Maximum lines retained across every buffer. Binds before
  /// [maxBufferedTests] when tests are chatty, and never binds when they
  /// are quiet — a 10 000-test run of near-silent tests keeps them all.
  final int maxTotalLines;

  /// Insertion-ordered, oldest first: the LRU queue.
  final Map<String, LogBuffer> _buffers = <String, LogBuffer>{};

  /// Lines an evicted test had buffered, so a re-created buffer can report
  /// them as elided. One `int` per evicted test — the same O(tests) order
  /// the result store's own per-test index already carries.
  final Map<String, int> _evictedLines = <String, int>{};

  int _liveLines = 0;
  int _evictedBuffers = 0;

  /// Returns the buffer for [testId], creating an empty one on
  /// first access and promoting it to the most-recently-used end.
  LogBuffer bufferFor(String testId) {
    final existing = _buffers.remove(testId);
    if (existing != null) {
      _buffers[testId] = existing;
      return existing;
    }
    final buffer = LogBuffer(
      maxLines: maxLinesPerTest,
      initialDroppedCount: _evictedLines.remove(testId) ?? 0,
    );
    _buffers[testId] = buffer;
    _pruneToBounds();
    return buffer;
  }

  /// Returns the buffer for [testId], or null when no log lines have
  /// been recorded for that test (or its buffer was evicted).
  ///
  /// A plain lookup: it does **not** promote. Promotion belongs to
  /// [bufferFor], which is what both log providers call; keeping `tryGet`
  /// side-effect free means callers can walk [testIds] and read each
  /// buffer without mutating the LRU order underneath the iteration.
  LogBuffer? tryGet(String testId) => _buffers[testId];

  /// All test ids currently buffered, least-recently-used first.
  ///
  /// A snapshot, not a live view of the map: eviction may run while a
  /// caller is part-way through the list.
  List<String> get testIds => List<String>.unmodifiable(_buffers.keys);

  /// Aggregate line count across every buffered test.
  int get totalLineCount =>
      _buffers.values.fold<int>(0, (sum, b) => sum + b.lineCount);

  /// How many per-test buffers have been evicted to stay inside the
  /// bounds. Surfaced for diagnostics and the soak assertions.
  int get evictedBufferCount => _evictedBuffers;

  /// Lines discarded with [testId]'s evicted buffer, or 0 when that test
  /// was never evicted.
  int evictedLinesFor(String testId) => _evictedLines[testId] ?? 0;

  /// Drops least-recently-used buffers until both bounds hold. Runs only
  /// when a *new* test id arrives, so the fold is paid once per test, not
  /// once per log line.
  void _pruneToBounds() {
    _liveLines = totalLineCount;
    if (_buffers.length <= maxBufferedTests && _liveLines <= maxTotalLines) {
      return;
    }
    // The buffer that was just inserted — the test that is starting now.
    // It is never the victim, however chatty the run.
    final newest = _buffers.keys.last;
    // `toList` because eviction mutates the map while we walk it.
    for (final id in _buffers.keys.toList()) {
      if (_buffers.length <= maxBufferedTests && _liveLines <= maxTotalLines) {
        return;
      }
      if (id == newest) continue;
      final candidate = _buffers[id]!;
      // Never evict a buffer the UI is streaming.
      if (candidate.hasListener) continue;
      _buffers.remove(id);
      _liveLines -= candidate.lineCount;
      _evictedLines[id] =
          (_evictedLines[id] ?? 0) +
          candidate.lineCount +
          candidate.droppedCount;
      _evictedBuffers++;
      unawaited(candidate.close());
    }
  }

  /// Closes every buffer. Idempotent.
  Future<void> closeAll() async {
    for (final buffer in _buffers.values) {
      await buffer.close();
    }
  }
}
