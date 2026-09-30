// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Reduces a multi-frame Python traceback to the one line a dashboard row
/// can hold, without discarding the trace.
///
/// **Never surface a raw Python traceback.** RISCOF failures arrive as ten to forty lines of
/// `File "…", line N, in …` frames whose only user-relevant content is the
/// final `SomeError: message` line. Putting all of it into
/// `TestExecutionFinished.failureMessage` — documented as a *"short
/// human-readable failure summary"* — turns the dashboard row into a wall
/// of interpreter internals.
///
/// The full trace is **not** thrown away: every line still reaches the
/// stream as a `TestLogLine` and lands in the retained stderr log, one
/// click away in the inspector. This class only decides what the *row*
/// says.
///
/// Pure and incremental: feed it stderr lines as they arrive through
/// `runProcessStreaming`'s `onLine` hook, then read [summary].
class PythonTracebackReducer {
  /// Creates a reducer with no lines seen yet.
  PythonTracebackReducer();

  /// The line Python prints to open a traceback.
  static const String kTracebackHeader = 'Traceback (most recent call last):';

  /// Matches the terminal `ExceptionType: message` line of a traceback.
  ///
  /// Python writes it flush-left (frame lines are indented), and the type
  /// may be dotted (`riscof.utils.ValidationError`) or bare
  /// (`FileNotFoundError`). The message part is optional — a bare
  /// `KeyboardInterrupt` has none.
  static final RegExp _terminalLine = RegExp(
    r'^([A-Za-z_][\w.]*(?:Error|Exception|Interrupt|Warning|Exit))'
    r'(?::\s*(.*))?$',
  );

  bool _inTraceback = false;
  String? _summary;

  /// True once a traceback header has been seen. Used to decide whether the
  /// reduced summary is worth preferring over an exit-code message.
  bool get sawTraceback => _inTraceback || _summary != null;

  /// The reduced one-line summary, or null when no traceback was seen.
  ///
  /// When several tracebacks arrive (a chained "During handling of the
  /// above exception…"), the **last** terminal line wins: that is the
  /// exception that actually escaped.
  String? get summary => _summary;

  /// Feeds one captured line. Safe to call for stdout lines too — a
  /// traceback on stdout is unusual but not impossible, and the header
  /// check is what arms the reducer either way.
  void addLine(String line) {
    final trimmed = line.trimRight();
    if (trimmed.trimLeft() == kTracebackHeader) {
      _inTraceback = true;
      return;
    }
    if (!_inTraceback) return;
    // Frame lines are indented; the terminal line is not. Anything
    // indented is still inside the trace.
    if (trimmed.isEmpty ||
        trimmed.startsWith(' ') ||
        trimmed.startsWith('\t')) {
      return;
    }
    final match = _terminalLine.firstMatch(trimmed);
    if (match == null) {
      // A non-indented, non-exception line ends the traceback (RISCOF
      // often prints its own summary afterwards). Leave any summary we
      // already captured intact.
      _inTraceback = false;
      return;
    }
    final type = match.group(1)!;
    final message = match.group(2)?.trim();
    _summary = (message == null || message.isEmpty) ? type : '$type: $message';
    _inTraceback = false;
  }

  /// Convenience for tests and for reducing an already-captured blob.
  static String? reduce(String stderr) {
    final reducer = PythonTracebackReducer();
    stderr.split('\n').forEach(reducer.addLine);
    return reducer.summary;
  }
}
