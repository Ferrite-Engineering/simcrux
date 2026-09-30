// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io' show IOSink, stderr;

import 'package:logging/logging.dart';

/// Writes every `package:logging` record at [Level.SEVERE] or above to
/// stderr, with its error and stack trace.
///
/// The issue reporter's ring buffer holds these records too, but only in
/// memory: it is read in the session that produced it or never. A release
/// build has no other trace — `developer.log` emits nothing from an AOT
/// build — so an uncaught framework or async error on a user's machine was
/// invisible unless they filed a report before quitting. stderr reaches the
/// terminal the app was launched from and, on Linux desktops, the user's
/// journal.
///
/// stderr, never stdout: the desktop executable's `--ci` and `--json` runs,
/// `--help` and import branches write to stdout for scripts to read, and a
/// log line there corrupts it.
///
/// Attached in `bootstrap()` beside the ring buffer, before any provider is
/// constructed, and not on the web, which has no stderr (the browser console
/// already shows these errors).
class SevereLogStderrSink {
  /// Creates a sink writing to [sink], or to the process's stderr when null.
  SevereLogStderrSink({IOSink? sink}) : _sinkOverride = sink;

  /// The process-wide sink attached by `bootstrap()`.
  static final SevereLogStderrSink instance = SevereLogStderrSink();

  /// The least severe level written.
  static const Level threshold = Level.SEVERE;

  final IOSink? _sinkOverride;
  IOSink? _sink;
  StreamSubscription<LogRecord>? _subscription;
  bool _failed = false;

  /// Whether the sink is subscribed and still able to write.
  bool get isAttached => _subscription != null && !_failed;

  /// Subscribes to [Logger.root]. Idempotent.
  ///
  /// A process can have no usable stderr — a Windows GUI launch has no
  /// console attached — and a write to it then fails asynchronously, on the
  /// sink's `done` future. Left unobserved, that failure would itself be an
  /// uncaught error, logged at SEVERE, written here, failing again. So the
  /// first failure, synchronous or not, stops the sink for good.
  void attach() {
    if (_subscription != null || _failed) return;
    final IOSink sink;
    try {
      sink = _sinkOverride ?? stderr;
    } on Object {
      _failed = true;
      return;
    }
    _sink = sink;
    unawaited(
      sink.done.then<void>(
        (_) => _stop(),
        onError: (Object _, StackTrace _) => _stop(),
      ),
    );
    _subscription = Logger.root.onRecord.listen(_write);
  }

  /// Cancels the subscription. Mainly for tests.
  Future<void> detach() async {
    await _subscription?.cancel();
    _subscription = null;
    _sink = null;
  }

  void _stop() {
    _failed = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _sink = null;
  }

  void _write(LogRecord record) {
    final sink = _sink;
    if (sink == null || _failed || record.level < threshold) return;
    try {
      sink.writeln(format(record));
    } on Object {
      // Bound to another stream, or already closed: nowhere to write.
      _stop();
    }
  }

  /// Formats [record] as `HH:MM:SS.mmm LEVEL logger: message`, followed by
  /// the error when the message does not already carry it, and by the stack
  /// trace, one indented line each.
  static String format(LogRecord record) {
    final t = record.time;
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}'
        '.${t.millisecond.toString().padLeft(3, '0')}';
    final logger = record.loggerName.isEmpty ? 'root' : record.loggerName;
    final out = StringBuffer(
      '$stamp ${record.level.name} $logger: ${record.message}',
    );
    final error = record.error;
    if (error != null) {
      final text = error.toString();
      if (!record.message.contains(text)) out.write('\n  $text');
    }
    final stack = record.stackTrace;
    if (stack != null) {
      for (final line in stack.toString().trimRight().split('\n')) {
        out.write('\n  $line');
      }
    }
    return out.toString();
  }
}
