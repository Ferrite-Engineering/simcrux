// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:collection';
import 'dart:convert';

/// Bounded, head-dropping line capture used by the scheduler to feed the
/// pass/fail detector without holding an unbounded string for a chatty
/// (multi-GB UVM) testbench.
///
/// Mirrors the ring discipline of `result_store/log_buffer_store.dart`'s
/// `LogBuffer`: the most recent [maxLines] are retained (oldest dropped
/// from the head) with a [droppedLines] counter. Failures in HDL
/// regressions almost always surface near the end of a run (the final
/// `UVM_ERROR` summary, the `$finish` banner), so head-dropping keeps the
/// diagnostically-relevant tail while bounding peak RSS.
///
/// Backed by a [ListQueue] so the at-capacity steady state is O(1) per
/// appended line (head drop + tail add) — a plain [List] with
/// `removeRange(0, overflow)` shifts every retained element on every
/// append once the buffer is full, which turns a long soak into an O(n)
/// CPU cost per line.
///
/// Bounding the captured log also caps the ReDoS exposure surface: the
/// regex pass/fail detector runs against [text], which can no longer grow
/// without limit.
class BoundedLogCapture {
  /// Creates a [BoundedLogCapture] retaining at most [maxLines] lines.
  BoundedLogCapture({this.maxLines = kDefaultMaxCapturedLogLines});

  /// Default per-test captured-line ceiling. Generous enough to retain a
  /// full normal run's output, bounded enough that a runaway log cannot
  /// grow the working set without limit.
  static const int kDefaultMaxCapturedLogLines = 100000;

  /// Maximum retained lines. Oldest lines fall off the head.
  final int maxLines;

  final ListQueue<String> _lines = ListQueue<String>();
  int _dropped = 0;

  /// Appends a single captured line.
  void addLine(String line) {
    _lines.addLast(line);
    while (_lines.length > maxLines) {
      _lines.removeFirst();
      _dropped++;
    }
  }

  /// Appends a multi-line blob (e.g. a compile stage's buffered output),
  /// splitting on line boundaries so the ring bound applies per line.
  void addBlob(String blob) {
    if (blob.isEmpty) return;
    const LineSplitter().convert(blob).forEach(addLine);
  }

  /// Number of lines dropped from the head due to the [maxLines] bound.
  int get droppedLines => _dropped;

  /// Number of lines currently retained (never exceeds [maxLines]).
  int get lineCount => _lines.length;

  /// The retained text, newline-joined — the input the pass/fail
  /// detector classifies against.
  String get text => _lines.join('\n');
}
