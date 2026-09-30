// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';

/// Immutable read-only view of the data the web dashboard renders.
///
/// Decoded from either:
///
/// - the consolidated `simcrux-results.json` document produced by
///   `simcrux export-dashboard …`, or
/// - the streaming `results.ndjson` document produced by `--ci` /
///   `output: { streaming: true }`.
///
/// The two formats share the same per-row schema; the consolidated
/// document wraps them in a top-level run/tests envelope, while the
/// NDJSON variant is line-delimited.
@immutable
class WebResultsDocument {
  /// Creates a [WebResultsDocument].
  WebResultsDocument({
    required this.runId,
    required this.startedAt,
    required this.finishedAt,
    required List<WebResultRow> rows,
    required Map<TestStatus, int> totals,
    this.configPath,
  }) : rows = List<WebResultRow>.unmodifiable(rows),
       totals = Map<TestStatus, int>.unmodifiable(totals);

  /// Decodes the consolidated `simcrux-results.json` shape produced
  /// by `simcrux export-dashboard`.
  factory WebResultsDocument.decodeConsolidated(String jsonText) {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object at the top level.');
    }
    final run = decoded['run'];
    if (run is! Map<String, Object?>) {
      throw const FormatException(
        'Missing or malformed `run` block in simcrux-results.json.',
      );
    }
    final tests = decoded['tests'];
    final rows = <WebResultRow>[];
    if (tests is List) {
      for (final t in tests) {
        if (t is Map<String, Object?>) {
          rows.add(WebResultRow.fromJson(t));
        }
      }
    }
    final totals = _recomputeTotals(rows);
    return WebResultsDocument(
      runId: '${run['id'] ?? ''}',
      startedAt: _parseDate(run['started_at']),
      finishedAt: run['finished_at'] != null
          ? _parseDate(run['finished_at'])
          : null,
      rows: rows,
      totals: totals,
      configPath: decoded['config_path'] as String?,
    );
  }

  /// Decodes the streaming NDJSON shape produced by the CI runner.
  factory WebResultsDocument.decodeNdjson(String ndjsonText) {
    var runId = '';
    var startedAt = DateTime.utc(1970);
    DateTime? finishedAt;
    String? configPath;
    final rows = <WebResultRow>[];
    Map<TestStatus, int>? streamingTotals;
    for (final line in ndjsonText.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      switch (decoded['type']) {
        case 'meta':
          runId = '${decoded['run_id'] ?? ''}';
          startedAt = _parseDate(decoded['started_at']);
          configPath = decoded['config_path'] as String?;
        case 'result':
          rows.add(WebResultRow.fromJson(decoded));
        case 'summary':
          finishedAt = _parseDate(decoded['finished_at']);
          final totalsRaw = decoded['totals'];
          if (totalsRaw is Map) {
            streamingTotals = <TestStatus, int>{};
            for (final entry in totalsRaw.entries) {
              if (entry.key is! String) continue;
              final status = TestStatus.values.firstWhere(
                (s) => s.name == entry.key,
                orElse: () => TestStatus.unknown,
              );
              streamingTotals[status] = (entry.value as num?)?.toInt() ?? 0;
            }
          }
      }
    }
    return WebResultsDocument(
      runId: runId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      rows: rows,
      totals: streamingTotals ?? _recomputeTotals(rows),
      configPath: configPath,
    );
  }

  /// Auto-detects the format and decodes. Heuristic: the consolidated
  /// shape is a single top-level JSON object with a `"tests"` list;
  /// the NDJSON shape is line-delimited where each line is its own
  /// object.
  factory WebResultsDocument.decode(String text) {
    final trimmed = text.trimLeft();
    // The streaming meta record is also a top-level JSON object, so we
    // count newlines as the disambiguating signal — a real
    // consolidated document is a single object spanning many lines
    // but always terminates with `}` followed by at most a final
    // newline.
    final firstNewline = trimmed.indexOf('\n');
    final looksConsolidated =
        trimmed.startsWith('{') &&
        (firstNewline == -1 ||
            trimmed.endsWith('}') ||
            trimmed.trimRight().endsWith('}'));
    if (looksConsolidated) {
      try {
        return WebResultsDocument.decodeConsolidated(text);
      } on FormatException {
        // Fall through to NDJSON.
      }
    }
    return WebResultsDocument.decodeNdjson(text);
  }

  /// `TestRun.id` the document belongs to.
  final String runId;

  /// Run start time (UTC).
  final DateTime startedAt;

  /// Run finish time. Null while a streaming run is still in flight.
  final DateTime? finishedAt;

  /// Per-test result rows.
  final List<WebResultRow> rows;

  /// Aggregate counts by [TestStatus]. Recomputed from [rows] when
  /// missing from the source document.
  final Map<TestStatus, int> totals;

  /// Originating `simcrux.yaml` path, if any.
  final String? configPath;

  /// Total row count.
  int get total => rows.length;

  static Map<TestStatus, int> _recomputeTotals(List<WebResultRow> rows) {
    final out = <TestStatus, int>{};
    for (final r in rows) {
      out.update(r.status, (n) => n + 1, ifAbsent: () => 1);
    }
    return out;
  }

  static DateTime _parseDate(Object? raw) {
    if (raw is String) {
      return DateTime.tryParse(raw)?.toUtc() ?? DateTime.utc(1970);
    }
    return DateTime.utc(1970);
  }
}

/// One row in the web dashboard's table. A read-only projection of
/// the corresponding desktop `DashboardRow` — the web build never
/// mutates this state.
@immutable
class WebResultRow {
  /// Creates a [WebResultRow].
  const WebResultRow({
    required this.testId,
    required this.testName,
    required this.suiteName,
    required this.simulatorId,
    required this.status,
    required this.runtime,
    this.startedAt,
    this.finishedAt,
    this.exitCode,
    this.failureMessage,
    this.waveformPath,
    this.stdoutPath,
    this.stderrPath,
    this.metrics = const <String, String>{},
  });

  /// Decodes a single per-test JSON object. Tolerant of missing keys.
  factory WebResultRow.fromJson(Map<String, Object?> json) {
    final statusName = json['status'] as String? ?? 'unknown';
    final status = TestStatus.values.firstWhere(
      (s) => s.name == statusName,
      orElse: () => TestStatus.unknown,
    );
    final runtimeMs = (json['runtime_ms'] as num?)?.toInt() ?? 0;
    final metricsRaw = json['metrics'];
    final metrics = <String, String>{};
    if (metricsRaw is Map) {
      for (final entry in metricsRaw.entries) {
        if (entry.key is String) {
          metrics[entry.key as String] = '${entry.value ?? ''}';
        }
      }
    }
    return WebResultRow(
      testId: json['id'] as String? ?? '',
      testName: json['name'] as String? ?? json['id'] as String? ?? '',
      suiteName: json['suite'] as String? ?? '',
      simulatorId: json['simulator'] as String? ?? '',
      status: status,
      runtime: Duration(milliseconds: runtimeMs),
      startedAt: _parseDateOrNull(json['started_at']),
      finishedAt: _parseDateOrNull(json['finished_at']),
      exitCode: (json['exit_code'] as num?)?.toInt(),
      failureMessage: json['failure_message'] as String?,
      waveformPath: json['waveform_path'] as String?,
      stdoutPath: json['stdout_path'] as String?,
      stderrPath: json['stderr_path'] as String?,
      metrics: Map<String, String>.unmodifiable(metrics),
    );
  }

  /// Stable `TestSpec.id` for this row.
  final String testId;

  /// Human-readable test name.
  final String testName;

  /// Owning suite.
  final String suiteName;

  /// Simulator the test ran on.
  final String simulatorId;

  /// Final classification.
  final TestStatus status;

  /// Wall-clock runtime.
  final Duration runtime;

  /// When the simulator process was launched. May be null when the
  /// source NDJSON omits timestamps.
  final DateTime? startedAt;

  /// When the result was finalized. May be null.
  final DateTime? finishedAt;

  /// Simulator process exit code. Null for cancelled / streaming
  /// runs.
  final int? exitCode;

  /// Short failure summary surfaced by the pass/fail detector.
  final String? failureMessage;

  /// Path to the captured waveform, when retained.
  final String? waveformPath;

  /// Path to the captured stdout log, when retained.
  final String? stdoutPath;

  /// Path to the captured stderr log, when retained.
  final String? stderrPath;

  /// Free-form key/value metrics from the simulator or testbench.
  final Map<String, String> metrics;

  static DateTime? _parseDateOrNull(Object? raw) {
    if (raw is String) {
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }
}
