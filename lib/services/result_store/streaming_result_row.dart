// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// One `result` line of a streaming `results.ndjson` archive, typed.
///
/// **Why this exists separately from the raw map.** `StreamingResultsReader`
/// deliberately keeps each result line as a decoded `Map<String, Object?>` so
/// a caller can project only what it needs. That was fine while there was one
/// caller. There are now two with different needs — the trend rebuild, which
/// wants the five fields a `TrendPoint` is made of, and the Enterprise shared
/// team database, which wants every field a pooled dashboard can show — and
/// two callers each reaching into the same map by string key is two copies of
/// the wire format, drifting the first time a key is added.
///
/// So the key names live here, once, and both callers project from a typed
/// row. The archive stays the authority on what a run contained; this is the
/// single place that knows how to read it.
///
/// **Everything is nullable that the writer can omit.** An archive written by
/// an older build carries fewer keys, and the reader's contract is that a
/// missing key reads as unknown rather than as a default that looks like data.
/// The one deliberate exception is [didExecute], which defaults to `true`:
/// archives written before the flag existed recorded only tests that ran, so
/// `true` is what their rows actually meant.
library;

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// A typed projection of one `result` line.
@immutable
class StreamingResultRow {
  /// Creates a [StreamingResultRow].
  const StreamingResultRow({
    required this.testId,
    required this.status,
    required this.runtime,
    required this.startedAt,
    this.testName,
    this.suiteName,
    this.simulatorId,
    this.finishedAt,
    this.exitCode,
    this.waveformPath,
    this.stdoutPath,
    this.stderrPath,
    this.failureMessage,
    this.killSignal,
    this.didExecute = true,
    this.metrics = const <String, String>{},
  });

  /// Projects a decoded `result` line, or returns `null` when the line cannot
  /// describe a test.
  ///
  /// `null` for a missing or empty `id`, and for an unparseable `started_at`:
  /// a row that cannot say which test it is, or when it ran, is not a row a
  /// trend or a pooled history can hold. Every other absent field reads as
  /// unknown rather than disqualifying the line, because a partially-written
  /// archive is exactly the case recovery exists for.
  static StreamingResultRow? parse(Map<String, Object?> row) {
    final testId = row['id'];
    if (testId is! String || testId.isEmpty) return null;
    final startedAt = _date(row['started_at']);
    if (startedAt == null) return null;
    return StreamingResultRow(
      testId: testId,
      testName: _text(row['name']),
      suiteName: _text(row['suite']),
      simulatorId: _text(row['simulator']),
      status: _status(row['status']),
      runtime: Duration(
        milliseconds: (row['runtime_ms'] as num?)?.toInt() ?? 0,
      ),
      startedAt: startedAt,
      finishedAt: _date(row['finished_at']),
      exitCode: (row['exit_code'] as num?)?.toInt(),
      waveformPath: _text(row['waveform_path']),
      stdoutPath: _text(row['stdout_path']),
      stderrPath: _text(row['stderr_path']),
      failureMessage: _text(row['failure_message']),
      killSignal: KillSignal.fromWireName(row['kill_signal']),
      // Absent means an archive from before the flag shipped, whose rows
      // recorded only tests that ran.
      didExecute: row['did_execute'] is! bool || row['did_execute']! as bool,
      metrics: _metrics(row['metrics']),
    );
  }

  /// The `TestSpec.id` this result belongs to.
  final String testId;

  /// Display name, when the archive carried one.
  final String? testName;

  /// Suite the test belongs to.
  final String? suiteName;

  /// Simulator that ran it.
  final String? simulatorId;

  /// Terminal status.
  final TestStatus status;

  /// Wall-clock runtime.
  final Duration runtime;

  /// When the simulator was launched (UTC).
  final DateTime startedAt;

  /// When the result was finalized (UTC).
  final DateTime? finishedAt;

  /// Simulator process exit code.
  final int? exitCode;

  /// Captured waveform path, on the machine that produced it.
  final String? waveformPath;

  /// Captured stdout path, on the machine that produced it.
  final String? stdoutPath;

  /// Captured stderr path, on the machine that produced it.
  final String? stderrPath;

  /// Short human-readable failure summary.
  final String? failureMessage;

  /// How the process was killed, when it was.
  final KillSignal? killSignal;

  /// Whether the toolchain actually launched.
  ///
  /// The live ingest path excludes a result that never executed from the trend
  /// store, because a missing simulator is not a fact about the test's
  /// behaviour. Any replay of an archive has to reproduce that filter or it
  /// fills a recovered history with "iverilog not found" rows.
  final bool didExecute;

  /// Free-form simulator-emitted metrics.
  final Map<String, String> metrics;

  @override
  String toString() => 'StreamingResultRow($testId, ${status.name})';

  static String? _text(Object? raw) {
    if (raw is! String) return null;
    return raw.isEmpty ? null : raw;
  }

  static DateTime? _date(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  static TestStatus _status(Object? raw) {
    if (raw is! String) return TestStatus.unknown;
    for (final status in TestStatus.values) {
      if (status.name == raw) return status;
    }
    return TestStatus.unknown;
  }

  static Map<String, String> _metrics(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is String && value != null) out[key] = '$value';
    });
    return Map<String, String>.unmodifiable(out);
  }
}
