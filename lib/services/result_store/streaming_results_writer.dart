// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/result_store/ndjson_recovery.dart';

/// Schema version written to NDJSON `meta` and to the
/// summary file. Bump only on incompatible changes.
const int kStreamingResultsSchemaVersion = 1;

/// Streaming writer that appends one JSON object per line to a
/// `results.ndjson` file as each test finishes, and writes a
/// `results.summary.json` aggregate at run completion.
///
/// Designed for the very-large-regression case where the
/// in-memory [TestRun.results] list grows beyond what the process
/// can comfortably hold. Each [recordRow] call appends a single
/// line — the file remains the authoritative record while the
/// process keeps a bounded in-memory footprint of "aggregate
/// counts only".
///
/// The format is purposely flat and forward-compatible:
///
/// ```json
/// {"type":"meta","version":1,"run_id":"…","started_at":"…"}
/// {"type":"result","id":"…","name":"…","suite":"…","status":"pass"}
/// {"type":"result"}
/// {"type":"summary","totals":{"pass":42,"fail":3},"finished_at":"…","total":45}
/// ```
///
/// Readers tolerate unknown line types and unknown keys; consumers
/// in subsequent versions can extend the stream additively without
/// breaking older readers.
class StreamingResultsWriter {
  /// Creates a [StreamingResultsWriter] backed by [resultsPath]. The
  /// companion summary lives next to it as `<name>.summary.json`.
  ///
  /// [openSink] is injectable so tests can capture writes into an
  /// in-memory buffer without touching the disk.
  ///
  /// [containWithin], when set, is the directory both files must stay
  /// inside: each is checked with [projectOutputPathProblem] immediately
  /// before it is opened, and a path that leads out throws
  /// [ProjectOutputPathException] with nothing created or truncated. The
  /// `--ci` runner sets it to the project directory unless project tooling
  /// is allowed, because both paths may come from the project file.
  StreamingResultsWriter({
    required this.resultsPath,
    String? summaryPath,
    this.containWithin,
    Future<IOSink> Function(String path)? openSink,
    Future<void> Function(String path, String contents)? writeSummary,
  }) : summaryPath = summaryPath ?? '${_stripExt(resultsPath)}.summary.json',
       _openSink = openSink ?? _defaultOpenSink,
       _writeSummary = writeSummary ?? _defaultWriteSummary;

  /// Path that the NDJSON stream is appended to. Recreated on every
  /// run — the writer is one-shot and not designed for append-resume.
  final String resultsPath;

  /// Path that the aggregate summary is written to at
  /// [recordRunCompletion].
  final String summaryPath;

  /// The directory [resultsPath] and [summaryPath] must stay inside, or
  /// null when they may be written anywhere.
  final String? containWithin;

  final Future<IOSink> Function(String path) _openSink;
  final Future<void> Function(String path, String contents) _writeSummary;

  IOSink? _sink;
  bool _opened = false;
  bool _closed = false;

  /// Aggregate counts. The streaming writer's only in-memory state.
  final Map<TestStatus, int> _totals = <TestStatus, int>{};

  /// Total rows recorded so far. Useful for memory-bounded smoke
  /// tests.
  int get recordedCount => _totals.values.fold<int>(0, (a, b) => a + b);

  /// Snapshot of the counts collected so far.
  Map<TestStatus, int> get totalsByStatus =>
      Map<TestStatus, int>.unmodifiable(_totals);

  /// True after [recordRunCompletion] has run.
  bool get isClosed => _closed;

  /// Opens the NDJSON file and writes the leading `meta` record.
  /// Call once before [recordRow]. Idempotent.
  Future<void> start({
    required String runId,
    required DateTime startedAt,
    String? configPath,
  }) async {
    if (_opened) return;
    // Both paths before either is touched: a summary path that leads out
    // must not wait until the run has finished to be refused.
    _checkContained(resultsPath);
    _checkContained(summaryPath);
    _opened = true;
    _sink = await _openSink(resultsPath);
    final meta = <String, Object?>{
      'type': 'meta',
      'version': kStreamingResultsSchemaVersion,
      'run_id': runId,
      'started_at': startedAt.toUtc().toIso8601String(),
      'config_path': configPath,
    };
    _sink!.writeln(jsonEncode(meta));
  }

  /// Appends a single result line to the NDJSON file. Updates the
  /// aggregate counts.
  Future<void> recordRow(DashboardRow row) async {
    if (!_opened) {
      throw StateError(
        'StreamingResultsWriter.recordRow called before start().',
      );
    }
    if (_closed) {
      throw StateError(
        'StreamingResultsWriter.recordRow called after recordRunCompletion().',
      );
    }
    _totals.update(row.result.status, (n) => n + 1, ifAbsent: () => 1);
    _sink!.writeln(jsonEncode(_encodeRow(row)));
  }

  /// Writes the trailing `summary` line to the NDJSON, closes the
  /// stream, and writes the standalone `results.summary.json`
  /// document.
  Future<void> recordRunCompletion({
    required DateTime finishedAt,
  }) async {
    if (_closed) return;
    if (!_opened) {
      // Allow zero-result runs to still close cleanly.
      _checkContained(resultsPath);
      _opened = true;
      _sink = await _openSink(resultsPath);
    }
    _closed = true;
    final summary = <String, Object?>{
      'type': 'summary',
      'version': kStreamingResultsSchemaVersion,
      'finished_at': finishedAt.toUtc().toIso8601String(),
      'total': recordedCount,
      'totals': _totalsAsMap(),
    };
    _sink!.writeln(jsonEncode(summary));
    await _sink!.flush();
    await _sink!.close();
    const encoder = JsonEncoder.withIndent('  ');
    // Checked again at the moment of writing: the run may have taken hours,
    // and a directory on the way can have become a link since [start].
    _checkContained(summaryPath);
    await _writeSummary(summaryPath, encoder.convert(summary));
  }

  /// Throws [ProjectOutputPathException] when [path] leads outside
  /// [containWithin].
  void _checkContained(String path) {
    final root = containWithin;
    if (root == null) return;
    final problem = projectOutputPathProblem(path, root);
    if (problem == null) return;
    throw ProjectOutputPathException(
      path: path,
      projectDir: root,
      problem: problem,
    );
  }

  /// Best-effort close used in error paths to avoid leaking the
  /// underlying file handle when [recordRunCompletion] was never
  /// reached.
  Future<void> abortWithoutSummary() async {
    if (_closed) return;
    _closed = true;
    if (_sink != null) {
      try {
        await _sink!.flush();
        await _sink!.close();
      } on Object {
        // Aborting; swallow.
      }
    }
  }

  Map<String, int> _totalsAsMap() {
    return <String, int>{
      for (final entry in _totals.entries) entry.key.name: entry.value,
    };
  }

  static Map<String, Object?> _encodeRow(DashboardRow row) {
    final r = row.result;
    return <String, Object?>{
      'type': 'result',
      'id': row.testId,
      'name': row.testName,
      'suite': row.suiteName,
      'simulator': row.simulatorId,
      'status': r.status.name,
      'runtime_ms': r.runtime.inMilliseconds,
      'started_at': r.startedAt.toUtc().toIso8601String(),
      'finished_at': r.finishedAt.toUtc().toIso8601String(),
      'exit_code': r.exitCode,
      'waveform_path': r.waveformPath,
      'stdout_path': r.stdoutPath,
      'stderr_path': r.stderrPath,
      'failure_message': r.failureMessage,
      'kill_signal': r.killSignal?.wireName,
      // Whether the simulator actually ran. Written because the archive is
      // the input to a trend-store rebuild, and the live ingest path excludes
      // a result whose toolchain never launched (`TestResult.didExecute`) —
      // without this key the rebuild could not reproduce that filter and
      // would fill a recovered history with "iverilog not found" rows.
      // Additive and forward-compatible: readers ignore unknown keys, and an
      // archive written before this key defaults to `true` on the way back
      // in, which is what its `trends.db` rows assumed anyway.
      'did_execute': r.didExecute,
      if (r.metrics.isNotEmpty) 'metrics': Map<String, String>.from(r.metrics),
    };
  }

  static Future<IOSink> _defaultOpenSink(String path) async {
    final file = File(path);
    final parent = file.parent;
    // Sync check avoids the async-IO lint; this runs once per run so
    // the sync penalty is negligible.
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    return file.openWrite();
  }

  static Future<void> _defaultWriteSummary(String path, String contents) =>
      File(path).writeAsString(contents);

  static String _stripExt(String path) {
    final dot = path.lastIndexOf('.');
    if (dot <= 0) return path;
    return path.substring(0, dot);
  }
}

/// Reader counterpart of [StreamingResultsWriter]. Consumes an
/// NDJSON file and reconstructs the rows + summary so the dashboard
/// and export pipeline can operate on a streaming run after-the-fact.
///
/// Tolerant to interrupted writes: returns whatever lines are
/// valid; treats missing trailing summary as "the run did not
/// complete cleanly" and reports `summary == null`.
class StreamingResultsReader {
  /// Const constructor.
  const StreamingResultsReader();

  /// Reads a full NDJSON stream from [path] and decodes into a
  /// [StreamingResultsDocument].
  ///
  /// [recovery] runs first, so a crash-truncated tail is repaired before
  /// the prefix is read. Defaults to [NoopNdjsonRecovery] (no repair) to
  /// preserve the historical behaviour for callers that pass nothing;
  /// pass [FileNdjsonRecovery] to repair in place. (The production export
  /// path runs recovery in [DashboardBundleWriter] rather than here, since
  /// it decodes in-memory text via [decode] rather than through this
  /// method.)
  Future<StreamingResultsDocument> readFile(
    String path, {
    NdjsonRecovery recovery = const NoopNdjsonRecovery(),
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('NDJSON results file does not exist', path);
    }
    await recovery.recover(path);
    final lines = await file.readAsLines();
    return decode(lines);
  }

  /// Decodes [lines] (one JSON object each) into a document.
  /// Exposed so tests can drive the reader from in-memory data.
  StreamingResultsDocument decode(Iterable<String> lines) {
    StreamingResultsMeta? meta;
    final rows = <Map<String, Object?>>[];
    StreamingResultsSummary? summary;
    var lineIndex = 0;
    for (final raw in lines) {
      lineIndex++;
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        // Skip corrupt lines (interrupted write) and keep going.
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      switch (decoded['type']) {
        case 'meta':
          meta = StreamingResultsMeta(
            version:
                (decoded['version'] as num?)?.toInt() ??
                kStreamingResultsSchemaVersion,
            runId: decoded['run_id'] as String? ?? '',
            startedAt: _parseDate(decoded['started_at']),
            configPath: decoded['config_path'] as String?,
          );
        case 'result':
          rows.add(decoded);
        case 'summary':
          summary = StreamingResultsSummary(
            finishedAt: _parseDate(decoded['finished_at']),
            total: (decoded['total'] as num?)?.toInt() ?? 0,
            totals: _decodeStatusMap(decoded['totals']),
          );
      }
      // Unknown line types are silently ignored for forward compat.
    }
    return StreamingResultsDocument(
      meta: meta,
      rows: List<Map<String, Object?>>.unmodifiable(rows),
      summary: summary,
      decodedLines: lineIndex,
    );
  }

  static DateTime _parseDate(Object? value) {
    if (value is String) {
      return DateTime.tryParse(value)?.toUtc() ?? DateTime.utc(1970);
    }
    return DateTime.utc(1970);
  }

  static Map<TestStatus, int> _decodeStatusMap(Object? raw) {
    if (raw is! Map) return const <TestStatus, int>{};
    final out = <TestStatus, int>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final status = TestStatus.values.firstWhere(
        (s) => s.name == key,
        orElse: () => TestStatus.unknown,
      );
      final count = (entry.value as num?)?.toInt() ?? 0;
      out[status] = count;
    }
    return Map<TestStatus, int>.unmodifiable(out);
  }
}

/// Parsed contents of a streaming-results NDJSON file.
class StreamingResultsDocument {
  /// Creates a [StreamingResultsDocument].
  const StreamingResultsDocument({
    required this.meta,
    required this.rows,
    required this.summary,
    required this.decodedLines,
  });

  /// Leading `meta` line, or null if absent / corrupt.
  final StreamingResultsMeta? meta;

  /// Per-result lines (raw JSON maps preserved for the reader to
  /// project as needed).
  final List<Map<String, Object?>> rows;

  /// Trailing `summary` line, or null if the run did not complete.
  final StreamingResultsSummary? summary;

  /// Total number of lines the reader inspected (including blanks /
  /// unknowns).
  final int decodedLines;

  /// True when both a meta header and a final summary were present.
  bool get isComplete => meta != null && summary != null;
}

/// Meta-line projection.
class StreamingResultsMeta {
  /// Creates a [StreamingResultsMeta].
  const StreamingResultsMeta({
    required this.version,
    required this.runId,
    required this.startedAt,
    required this.configPath,
  });

  /// NDJSON schema version (see [kStreamingResultsSchemaVersion]).
  final int version;

  /// `TestRun.id` the file belongs to.
  final String runId;

  /// Run start time (UTC).
  final DateTime startedAt;

  /// Originating `simcrux.yaml` path, if any.
  final String? configPath;
}

/// Summary-line projection.
class StreamingResultsSummary {
  /// Creates a [StreamingResultsSummary].
  const StreamingResultsSummary({
    required this.finishedAt,
    required this.total,
    required this.totals,
  });

  /// Run completion time (UTC).
  final DateTime finishedAt;

  /// Total number of result rows.
  final int total;

  /// Counts indexed by [TestStatus].
  final Map<TestStatus, int> totals;
}

/// Helper used by the export pipeline to materialize a streaming
/// document back into the in-memory [TestRun] + [DashboardRow] shape
/// the existing exporters consume.
///
/// Streaming throws away suite/simulator/test-name (they live only
/// in the NDJSON) but the reader keeps them, so this helper is the
/// inverse of [StreamingResultsWriter._encodeRow].
class StreamingResultsHydrator {
  /// Const constructor.
  const StreamingResultsHydrator();

  /// Hydrates [doc] into a `(TestRun, List<DashboardRow>)` pair the
  /// existing JSON/JUnit/HTML/CSV exporters know how to render.
  ({TestRun run, List<DashboardRow> rows}) hydrate(
    StreamingResultsDocument doc,
  ) {
    final meta = doc.meta;
    final startedAt = meta?.startedAt ?? DateTime.utc(1970);
    final runId = meta?.runId ?? '';
    final rows = <DashboardRow>[];
    final testIds = <String>[];
    final results = <TestResult>[];
    for (final raw in doc.rows) {
      final id = raw['id'] as String?;
      if (id == null) continue;
      testIds.add(id);
      final statusName = raw['status'] as String? ?? 'unknown';
      final status = TestStatus.values.firstWhere(
        (s) => s.name == statusName,
        orElse: () => TestStatus.unknown,
      );
      final started = _parseDate(raw['started_at']);
      final finished = _parseDate(raw['finished_at']);
      final result = TestResult(
        testId: id,
        runId: runId,
        status: status,
        startedAt: started,
        finishedAt: finished,
        exitCode: (raw['exit_code'] as num?)?.toInt(),
        stdoutPath: raw['stdout_path'] as String?,
        stderrPath: raw['stderr_path'] as String?,
        waveformPath: raw['waveform_path'] as String?,
        failureMessage: raw['failure_message'] as String?,
        killSignal: KillSignal.fromWireName(raw['kill_signal']),
        // Absent in archives written before the key existed; `true` is both
        // the model's default and the assumption those runs' trend rows were
        // written under.
        didExecute: raw['did_execute'] as bool? ?? true,
        metrics: _decodeMetrics(raw['metrics']),
      );
      results.add(result);
      rows.add(
        DashboardRow(
          result: result,
          suiteName: raw['suite'] as String? ?? '',
          simulatorId: raw['simulator'] as String? ?? '',
          testName: raw['name'] as String? ?? id,
        ),
      );
    }
    final run = TestRun(
      id: runId,
      startedAt: startedAt,
      finishedAt: doc.summary?.finishedAt,
      testIds: testIds,
      results: results,
    );
    return (run: run, rows: rows);
  }

  static Map<String, String> _decodeMetrics(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return <String, String>{
      for (final entry in raw.entries)
        if (entry.key is String) entry.key as String: '${entry.value ?? ''}',
    };
  }

  static DateTime _parseDate(Object? raw) {
    if (raw is String) {
      return DateTime.tryParse(raw)?.toUtc() ?? DateTime.utc(1970);
    }
    return DateTime.utc(1970);
  }
}
