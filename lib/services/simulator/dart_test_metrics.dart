// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The `dart.*` metrics a Dart test run carries on its `TestResult`, and the
/// reader the inspector uses to turn them back into rows.
///
/// A SimCrux test is one row, and one `dart test` run is many cases, exactly as
/// a Cocotb run is. The cases ride the row's string metrics the way Cocotb's do:
///
/// | Key | Value |
/// |---|---|
/// | `dart.tests`, `dart.pass`, `dart.fail`, `dart.error`, `dart.skip` | counts |
/// | `dart.objection_warnings` | ROHD-VF objection warnings, all cases |
/// | `dart.complete` | `true` when the runner reached its `done` event |
/// | `dart.case.<n>.name` | the full case name |
/// | `dart.case.<n>.status` | `PASS`, `FAIL`, `ERROR` or `SKIP` |
/// | `dart.case.<n>.duration_ms` | wall clock, when known |
/// | `dart.case.<n>.file`, `.line`, `.column` | where the test is declared |
/// | `dart.case.<n>.message`, `.stack` | the first error, failing cases only |
/// | `dart.case.<n>.source_file`, `.source_line`, `.source_column` | the first stack frame in the user's own code |
/// | `dart.case.<n>.rohd_vf` | `true` for a reclassified ROHD-VF `Test failed.` |
/// | `dart.case.<n>.logs` | JSON list of `{m, s?, t?, l?}`, non-passing cases |
///
/// `n` is the case's position in the run, from zero. Detail for passing cases
/// is the name, status, duration and declaration only, so a thousand-case run
/// does not write a thousand stacks.
library;

import 'dart:convert';

import 'package:simcrux/services/simulator/dart_test_report.dart';

/// The most cases whose detail (message, stack, logs) is written.
const int kDartTestMaxDetailedCases = 100;

/// The most cases written at all; a run beyond this is counted, not listed.
const int kDartTestMaxCases = 2000;

const int _maxMessage = 2000;
const int _maxStack = 4000;
const int _maxLogEntries = 200;
const int _maxLogMessage = 500;

/// Builds the `dart.*` metrics for [report].
///
/// [resolve] turns a location's URI into a file path (or `null` when the file
/// is not the user's); the driver supplies one bound to the package root.
Map<String, String> dartTestMetrics(
  DartTestReport report, {
  required String? Function(String uri) resolve,
}) {
  final out = <String, String>{
    'dart.tests': '${report.cases.length}',
    'dart.pass': '${report.count(DartTestOutcome.pass)}',
    'dart.fail': '${report.count(DartTestOutcome.fail)}',
    'dart.error': '${report.count(DartTestOutcome.error)}',
    'dart.skip': '${report.count(DartTestOutcome.skip)}',
    'dart.complete': '${report.complete}',
  };
  if (report.objectionWarnings > 0) {
    out['dart.objection_warnings'] = '${report.objectionWarnings}';
  }
  var detailed = 0;
  for (var i = 0; i < report.cases.length && i < kDartTestMaxCases; i++) {
    final c = report.cases[i];
    final k = 'dart.case.$i';
    out['$k.name'] = c.name;
    out['$k.status'] = _status(c.outcome);
    final duration = c.durationMs;
    if (duration != null) out['$k.duration_ms'] = '$duration';
    _put(out, k, '', c.declared, resolve);
    if (c.outcome == DartTestOutcome.pass) continue;
    if (detailed++ >= kDartTestMaxDetailedCases) continue;
    final message = c.message;
    if (message != null && message.isNotEmpty) {
      out['$k.message'] = _clip(message, _maxMessage);
    }
    final stack = c.stack;
    if (stack != null && stack.isNotEmpty) {
      out['$k.stack'] = _clip(stack, _maxStack);
    }
    _put(out, k, 'source_', c.failureFrame, resolve);
    if (c.rohdVfFailure) out['$k.rohd_vf'] = 'true';
    if (c.logs.isNotEmpty) {
      out['$k.logs'] = jsonEncode(<Object>[
        for (final l in c.logs.take(_maxLogEntries))
          <String, Object>{
            'm': _clip(l.message, _maxLogMessage),
            if (l.severity != null) 's': l.severity!,
            if (l.simTime != null) 't': l.simTime!,
            if (l.logger != null) 'l': l.logger!,
          },
      ]);
    }
  }
  return out;
}

void _put(
  Map<String, String> out,
  String key,
  String prefix,
  DartSourceLocation? at,
  String? Function(String uri) resolve,
) {
  if (at == null) return;
  final path = resolve(at.uri);
  if (path == null) return;
  out['$key.${prefix}file'] = path;
  if (at.line != null) out['$key.${prefix}line'] = '${at.line}';
  if (at.column != null) out['$key.${prefix}column'] = '${at.column}';
}

String _status(DartTestOutcome o) => switch (o) {
  DartTestOutcome.pass => 'PASS',
  DartTestOutcome.fail => 'FAIL',
  DartTestOutcome.error => 'ERROR',
  DartTestOutcome.skip => 'SKIP',
};

String _clip(String s, int max) => s.length <= max ? s : s.substring(0, max);

/// One case as the inspector shows it.
class DartTestRow {
  /// Creates a row.
  const DartTestRow({
    required this.name,
    required this.status,
    this.durationMs,
    this.file,
    this.line,
    this.column,
    this.message,
    this.sourceFile,
    this.sourceLine,
    this.sourceColumn,
    this.rohdVf = false,
    this.logs = const <DartTestLogEntry>[],
  });

  /// The full case name.
  final String name;

  /// `PASS`, `FAIL`, `ERROR` or `SKIP`.
  final String status;

  /// Wall clock, when known.
  final int? durationMs;

  /// Where the test is declared.
  final String? file;

  /// 1-based line of the declaration.
  final int? line;

  /// 1-based column of the declaration.
  final int? column;

  /// The first line of the error message.
  final String? message;

  /// The user's own frame the failure points at.
  final String? sourceFile;

  /// 1-based line of that frame.
  final int? sourceLine;

  /// 1-based column of that frame.
  final int? sourceColumn;

  /// Whether this was a ROHD-VF `Test failed.`.
  final bool rohdVf;

  /// What the case printed, ROHD-VF lines split.
  final List<DartTestLogEntry> logs;

  /// Whether the case did not pass.
  bool get failing => status == 'FAIL' || status == 'ERROR';

  /// The file Go to Source opens: the failing frame when there is one, else
  /// the declaration. Null when neither is known.
  String? get goToFile => sourceFile ?? file;

  /// The line in [goToFile].
  int? get goToLine => sourceFile != null ? sourceLine : line;

  /// The column in [goToFile].
  int? get goToColumn => sourceFile != null ? sourceColumn : column;
}

/// What the inspector shows for a Dart test row.
class DartTestResultView {
  const DartTestResultView._({
    required this.rows,
    required this.tests,
    required this.objectionWarnings,
    required this.complete,
  });

  /// Reads [metrics], or returns `null` for a row that is not a Dart test run.
  static DartTestResultView? fromMetrics(Map<String, String> metrics) {
    final tests = int.tryParse(metrics['dart.tests'] ?? '');
    if (tests == null) return null;
    final rows = <DartTestRow>[];
    for (var i = 0; i < kDartTestMaxCases; i++) {
      final k = 'dart.case.$i';
      final name = metrics['$k.name'];
      if (name == null) break;
      rows.add(
        DartTestRow(
          name: name,
          status: metrics['$k.status'] ?? 'ERROR',
          durationMs: int.tryParse(metrics['$k.duration_ms'] ?? ''),
          file: metrics['$k.file'],
          line: int.tryParse(metrics['$k.line'] ?? ''),
          column: int.tryParse(metrics['$k.column'] ?? ''),
          message: _firstLine(metrics['$k.message']),
          sourceFile: metrics['$k.source_file'],
          sourceLine: int.tryParse(metrics['$k.source_line'] ?? ''),
          sourceColumn: int.tryParse(metrics['$k.source_column'] ?? ''),
          rohdVf: metrics['$k.rohd_vf'] == 'true',
          logs: _logs(metrics['$k.logs']),
        ),
      );
    }
    return DartTestResultView._(
      rows: List<DartTestRow>.unmodifiable(rows),
      tests: tests,
      objectionWarnings:
          int.tryParse(metrics['dart.objection_warnings'] ?? '') ?? 0,
      complete: metrics['dart.complete'] != 'false',
    );
  }

  /// The listed cases.
  final List<DartTestRow> rows;

  /// How many cases the run had; more than [rows] when the list was capped.
  final int tests;

  /// ROHD-VF objection warnings across the run.
  final int objectionWarnings;

  /// Whether the runner finished; false for a killed or truncated run.
  final bool complete;
}

String? _firstLine(String? s) {
  if (s == null) return null;
  for (final line in const LineSplitter().convert(s)) {
    if (line.trim().isNotEmpty) return line.trim();
  }
  return null;
}

List<DartTestLogEntry> _logs(String? json) {
  if (json == null) return const <DartTestLogEntry>[];
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List<Object?>) return const <DartTestLogEntry>[];
    return <DartTestLogEntry>[
      for (final e in decoded)
        if (e is Map<String, Object?> && e['m'] is String)
          DartTestLogEntry(
            message: e['m']! as String,
            severity: e['s'] is String ? e['s']! as String : null,
            simTime: e['t'] is int ? e['t']! as int : null,
            logger: e['l'] is String ? e['l']! as String : null,
          ),
    ];
  } on FormatException {
    return const <DartTestLogEntry>[];
  }
}
