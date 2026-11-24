// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The `--json` documents of `simcrux run`, `results`, `test` and `trend`,
/// and the rule that decides a run's outcome.
///
/// Every document is `crux_mcp`'s eight-member envelope; the bodies are the
/// contracts' (`spec/mcp/schemas/`). A run's rows are the `result` lines of
/// its `results.ndjson` (`StreamingResultsWriter.encodeRow`, read back with
/// `StreamingResultRow.parse`), whether the run is still in memory (`run`)
/// or read from the file (`results`), so the two cannot describe the same
/// test differently.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';

/// The program name every document names.
const String kSimcruxProgramName = 'simcrux';

/// The four commands, as their documents and tools name them.
const String kRunCommand = 'run';

/// See [kRunCommand].
const String kResultsCommand = 'results';

/// See [kRunCommand].
const String kTestCommand = 'test';

/// See [kRunCommand].
const String kTrendCommand = 'trend';

/// Rows a `run` or `results` document lists unless `--limit` says.
const int kDefaultRowLimit = 100;

/// The most rows `--limit` may ask for.
const int kMaxRowLimit = 1000;

/// Log lines `test` returns unless `--lines` says.
const int kDefaultLogLines = 100;

/// The most log lines `--lines` may ask for.
const int kMaxLogLines = 1000;

/// The most bytes of log text a `test` document carries, whatever `--lines`
/// says.
const int kMaxLogTailBytes = 64 * 1024;

/// The most `results.ndjson` files one `trend` reads.
const int kMaxTrendRuns = 200;

/// How far into a log the first failing line is looked for, in bytes.
const int kFailureLineScanBytes = 8 * 1024 * 1024;

/// The environment variable a SimCrux licence file is named by.
const String kSimcruxLicenseEnv = 'SIMCRUX_LICENSE_FILE';

/// The statuses a document's `totals` counts, in the contracts' order.
const List<TestStatus> kTotalsOrder = <TestStatus>[
  TestStatus.pass,
  TestStatus.fail,
  TestStatus.timeout,
  TestStatus.vacuous,
  TestStatus.cover,
  TestStatus.skipped,
  TestStatus.cancelled,
  TestStatus.unknown,
];

/// The order `tests` lists rows in, failures first: each status's rank.
const List<TestStatus> kRowOrder = <TestStatus>[
  TestStatus.fail,
  TestStatus.timeout,
  TestStatus.unknown,
  TestStatus.cancelled,
  TestStatus.running,
  TestStatus.vacuous,
  TestStatus.skipped,
  TestStatus.cover,
  TestStatus.pass,
];

/// The statuses the gate counts as failures: the `--fail-threshold` rule of
/// `--ci` (`CiRunResult.failuresIn` without `--fail-on-vacuous`), in which
/// `unknown` always counts.
const Set<TestStatus> kGateFailures = <TestStatus>{
  TestStatus.fail,
  TestStatus.timeout,
  TestStatus.unknown,
};

/// Whether [row] is a verdict about the design: its simulator ran and it
/// ended pass, fail, timeout, vacuous or cover. A test that never ran its
/// simulator, was skipped or cancelled, or that SimCrux could not classify
/// (`unknown`) produced no result.
bool producedResult(StreamingResultRow row) =>
    row.didExecute &&
    row.status != TestStatus.unknown &&
    row.status != TestStatus.cancelled &&
    row.status != TestStatus.skipped &&
    row.status != TestStatus.running;

/// What the outcome of a run is decided from.
class SimRunFacts {
  /// The facts of a run whose rows are [rows]; [selected] tests were
  /// submitted (null when not known, as for a file), the scheduler reported
  /// the run [cancelled], and it [finished] (a file with a summary line).
  SimRunFacts({
    required List<StreamingResultRow> rows,
    required this.selected,
    required this.cancelled,
    this.finished = true,
  }) : rows = List<StreamingResultRow>.unmodifiable(rows);

  /// Whether the run finished: false for a file without its summary line.
  final bool finished;

  /// Every row of the run.
  final List<StreamingResultRow> rows;

  /// Tests submitted, or null when not known.
  final int? selected;

  /// Whether the run was cancelled before every test finished.
  final bool cancelled;

  /// Rows by status.
  Map<TestStatus, int> get totals {
    final totals = <TestStatus, int>{};
    for (final r in rows) {
      totals.update(r.status, (n) => n + 1, ifAbsent: () => 1);
    }
    return totals;
  }
}

/// The outcome of a run and the diagnostics that say why.
class SimRunVerdict {
  /// An [outcome] and its [diagnostics].
  const SimRunVerdict(this.outcome, this.diagnostics);

  /// The outcome.
  final McpOutcome outcome;

  /// Why, for every outcome but `completed`; warnings for any.
  final List<McpDiagnostic> diagnostics;
}

/// Maps a run's facts to its outcome. [classifySimRun] everywhere but the
/// test that proves a broken mapping is caught.
typedef SimRunClassifier = SimRunVerdict Function(SimRunFacts facts);

/// The rule that decides a run's outcome (contracts 2.4 and 6.1), in order:
///
/// 1. cancelled before every test finished: `engine_error` (`run.cancelled`);
/// 2. no test selected, in a run that finished: `input_error`
///    (`run.no_tests`);
/// 3. no test produced a result ([producedResult]): `engine_error`
///    (`run.no_results`);
/// 4. a submitted test reported nothing: `engine_error` (`run.unreported`);
/// 5. a `fail`, `timeout` or `unknown` test: `failed_gate` (`gate.failed`);
///    an `unknown` test is a failed test;
/// 6. otherwise `completed`. A `vacuous` test does not fail the gate, as
///    under `--ci`; its row says `vacuous`.
///
/// Tests whose simulator never ran, in a run where others did, add an
/// `engine.missing` warning.
SimRunVerdict classifySimRun(SimRunFacts facts) {
  final rows = facts.rows;
  if (facts.cancelled) {
    return const SimRunVerdict(McpOutcome.engineError, <McpDiagnostic>[
      McpDiagnostic.error(
        'run.cancelled',
        'The run was cancelled before every test finished, so its results '
            'do not cover the regression.',
      ),
    ]);
  }
  final selected = facts.selected ?? rows.length;
  // A run that did not finish and recorded nothing gave no result; one that
  // finished having selected nothing was asked for nothing.
  if (selected == 0 && facts.finished) {
    return const SimRunVerdict(McpOutcome.inputError, <McpDiagnostic>[
      McpDiagnostic.error(
        'run.no_tests',
        'No test was selected: the config has none, or the filter matched '
            'none.',
        fix:
            "List the config's test ids with simcrux results on an "
            'earlier run, and give a filter that one of them contains.',
      ),
    ]);
  }
  final produced = rows.where(producedResult).length;
  if (produced == 0) {
    return SimRunVerdict(McpOutcome.engineError, <McpDiagnostic>[
      McpDiagnostic.error(
        'run.no_results',
        'No test produced a result: each of the ${rows.length} tests is '
            'unknown, cancelled or skipped, or never ran its simulator.',
        fix:
            'Read a test with simcrux test for its failure message and log; '
            'a simulator that is not installed is named there.',
      ),
    ]);
  }
  final warnings = <McpDiagnostic>[];
  final notRun = <String>{
    for (final r in rows)
      if (!r.didExecute) r.simulatorId ?? 'unknown',
  };
  if (notRun.isNotEmpty) {
    final count = rows.where((r) => !r.didExecute).length;
    warnings.add(
      McpDiagnostic.warning(
        'engine.missing',
        '$count of ${rows.length} tests never ran their simulator '
            '(${(notRun.toList()..sort()).join(', ')}), so their rows say '
            'nothing about the design.',
        fix: 'Install the simulator, or put it on PATH, and run again.',
      ),
    );
  }
  final reported = <String>{for (final r in rows) r.testId}.length;
  if (facts.selected != null && reported < facts.selected!) {
    return SimRunVerdict(McpOutcome.engineError, <McpDiagnostic>[
      McpDiagnostic.error(
        'run.unreported',
        '${facts.selected! - reported} of ${facts.selected} submitted tests '
            'reported no result, so the totals do not cover the regression.',
      ),
      ...warnings,
    ]);
  }
  final totals = facts.totals;
  final failed = kGateFailures.fold<int>(0, (n, s) => n + (totals[s] ?? 0));
  if (failed > 0) {
    final parts = <String>[
      for (final s in kGateFailures)
        if ((totals[s] ?? 0) > 0) '${totals[s]} ${s.name}',
    ];
    return SimRunVerdict(McpOutcome.failedGate, <McpDiagnostic>[
      McpDiagnostic.error(
        'gate.failed',
        '$failed of ${rows.length} tests failed the gate '
            '(${parts.join(', ')})'
            '${(totals[TestStatus.unknown] ?? 0) > 0 ? '; an unknown test counts as failed' : ''}.',
      ),
      ...warnings,
    ]);
  }
  return SimRunVerdict(McpOutcome.completed, warnings);
}

/// Which files a command may read beyond the ones it was given: every
/// file when [roots] is empty (the command line, run by a person), else only
/// files inside one of [roots] (the server's root, and SimCrux's own
/// scratch, where `run` keeps failing tests' work folders).
class SimReadScope {
  /// A scope over [roots]; empty for no limit.
  SimReadScope(List<Confinement> roots)
    : roots = List<Confinement>.unmodifiable(roots);

  /// No limit.
  SimReadScope.unlimited() : roots = const <Confinement>[];

  /// The confinements a read must pass one of.
  final List<Confinement> roots;

  /// Whether [path] may be read.
  bool allows(String path) {
    if (roots.isEmpty) return true;
    return roots.any((c) => c.confine(path) is ConfinedPath);
  }
}

/// The log a row points at: its stdout, or its stderr when there is no
/// stdout or it is empty. Null when neither is recorded.
String? logPathOf(StreamingResultRow row, SimReadScope scope) {
  final out = row.stdoutPath;
  final err = row.stderrPath;
  if (out == null) return err;
  if (err == null) return out;
  if (!scope.allows(out)) return out;
  final stat = FileStat.statSync(out);
  if (stat.type == FileSystemEntityType.file && stat.size == 0) return err;
  return out;
}

/// The line of [logPath] the failure message [message] came from: the
/// first line holding the message's first line, counted from 1. Null when
/// the message is empty, the log cannot be read in [scope], or no line in
/// its first [kFailureLineScanBytes] bytes holds it.
Future<int?> firstFailureLine(
  String? logPath,
  String? message,
  SimReadScope scope,
) async {
  if (logPath == null || message == null) return null;
  final needle = const LineSplitter().convert(message.trim()).firstOrNull;
  if (needle == null || needle.trim().isEmpty) return null;
  if (!scope.allows(logPath) ||
      FileSystemEntity.typeSync(logPath) != FileSystemEntityType.file) {
    return null;
  }
  var number = 0;
  try {
    final lines = File(logPath)
        .openRead(0, kFailureLineScanBytes)
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      number++;
      if (line.contains(needle.trim())) return number;
    }
  } on FileSystemException {
    return null;
  }
  return null;
}

/// The tail of a log: its last [lines] lines, at most [kMaxLogTailBytes]
/// bytes of them.
class LogTail {
  /// A tail starting at [fromLine] (from 1) holding [lines].
  const LogTail({
    required this.path,
    required this.fromLine,
    required this.lines,
    required this.truncated,
  });

  /// The log.
  final String path;

  /// The line number of the first line in [lines], from 1.
  final int fromLine;

  /// The lines, oldest first.
  final List<String> lines;

  /// Whether lines before [fromLine] were left out.
  final bool truncated;

  /// The `log` member of a `test` body.
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'from_line': fromLine,
    'lines': lines,
    'truncated': truncated,
  };
}

/// The last [count] lines of [path], cut from the front to at most
/// [kMaxLogTailBytes] bytes; a single line longer than that keeps its
/// first [kMaxLogTailBytes] bytes' worth of characters.
Future<LogTail> readLogTail(String path, int count) async {
  final kept = <String>[];
  var total = 0;
  final lines = File(path)
      .openRead()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());
  await for (final line in lines) {
    total++;
    kept.add(line);
    if (kept.length > count) kept.removeAt(0);
  }
  var bytes = 0;
  for (final l in kept) {
    bytes += utf8.encode(l).length + 1;
  }
  while (kept.length > 1 && bytes > kMaxLogTailBytes) {
    bytes -= utf8.encode(kept.removeAt(0)).length + 1;
  }
  if (kept.length == 1 && utf8.encode(kept.single).length > kMaxLogTailBytes) {
    final out = StringBuffer();
    var used = 0;
    for (final rune in kept.single.runes) {
      final size = utf8.encode(String.fromCharCode(rune)).length;
      if (used + size > kMaxLogTailBytes) break;
      used += size;
      out.writeCharCode(rune);
    }
    kept[0] = out.toString();
  }
  final from = total - kept.length + 1;
  return LogTail(
    path: path,
    fromLine: from,
    lines: List<String>.unmodifiable(kept),
    truncated: from > 1,
  );
}

String _date(DateTime t) => t.toUtc().toIso8601String();

/// The `TestRow` of [row] in run [runId]: the `--export json` version 1
/// test row, with `metrics` always present (null when empty), plus
/// `did_execute`, `location` (the test, its log, and the line its failure
/// message came from when known) and `waveform` (a place at the start of
/// its waveform, when it has an absolute one).
Future<Map<String, Object?>> testRowJson(
  StreamingResultRow row, {
  required String runId,
  required SimReadScope scope,
}) async {
  final log = logPathOf(row, scope);
  final failing = kGateFailures.contains(row.status);
  final line = failing
      ? await firstFailureLine(log, row.failureMessage, scope)
      : null;
  final wave = row.waveformPath;
  return <String, Object?>{
    'id': row.testId,
    'name': row.testName ?? row.testId,
    'suite': row.suiteName ?? '',
    'simulator': row.simulatorId ?? 'unknown',
    'status': row.status.name,
    'runtime_ms': row.runtime.inMilliseconds,
    'started_at': _date(row.startedAt),
    'finished_at': row.finishedAt == null ? null : _date(row.finishedAt!),
    'exit_code': row.exitCode,
    'waveform_path': wave,
    'stdout_path': row.stdoutPath,
    'stderr_path': row.stderrPath,
    'failure_message': row.failureMessage,
    'metrics': row.metrics.isEmpty
        ? null
        : <String, Object?>{
            for (final k in row.metrics.keys.toList()..sort())
              k: row.metrics[k],
          },
    'did_execute': row.didExecute,
    'location': McpTestLocation(
      test: row.testId,
      run: runId,
      file: log,
      line: log == null ? null : line,
    ).toJson(),
    'waveform': wave != null && mcpIsAbsoluteText(wave)
        ? McpPlaceLocation(file: wave, time: McpTime.ticks(0)).toJson()
        : null,
  };
}

/// [rows] in the order a document lists them: failures first (by
/// [kRowOrder]), then by id, then by start time.
List<StreamingResultRow> orderRows(Iterable<StreamingResultRow> rows) {
  return rows.toList()..sort((a, b) {
    final byStatus = kRowOrder
        .indexOf(a.status)
        .compareTo(kRowOrder.indexOf(b.status));
    if (byStatus != 0) return byStatus;
    final byId = a.testId.compareTo(b.testId);
    if (byId != 0) return byId;
    return a.startedAt.compareTo(b.startedAt);
  });
}

/// The body of `run` and of `results`: the run, its totals, and up to
/// [limit] of its rows (those whose status is in [statuses], when given),
/// failures first.
Future<Map<String, Object?>> runBody({
  required String? configPath,
  required String runId,
  required DateTime startedAt,
  required DateTime? finishedAt,
  required List<StreamingResultRow> rows,
  required String? resultsPath,
  required int limit,
  required SimReadScope scope,
  Set<TestStatus>? statuses,
}) async {
  final totals = <TestStatus, int>{};
  for (final r in rows) {
    totals.update(r.status, (n) => n + 1, ifAbsent: () => 1);
  }
  final listed = orderRows(
    statuses == null ? rows : rows.where((r) => statuses.contains(r.status)),
  );
  final returned = listed.take(limit).toList();
  return <String, Object?>{
    'version': 1,
    'config_path': configPath,
    'run': <String, Object?>{
      'id': runId,
      'started_at': _date(startedAt),
      'finished_at': finishedAt == null ? null : _date(finishedAt),
      'total': rows.length,
    },
    'totals': <String, Object?>{
      for (final s in kTotalsOrder) s.name: totals[s] ?? 0,
    },
    'results_path': resultsPath,
    'returned': returned.length,
    'truncated': listed.length > returned.length,
    'tests': <Object?>[
      for (final r in returned)
        await testRowJson(r, runId: runId, scope: scope),
    ],
  };
}

/// A `results.ndjson` read for a document: its run id, times, config and
/// rows, or the diagnostic that says why it cannot be used.
class SimResultsFile {
  SimResultsFile._({
    required this.path,
    required this.runId,
    required this.startedAt,
    required this.finishedAt,
    required this.configPath,
    required this.rows,
    required this.warnings,
  });

  /// The file read.
  final String path;

  /// Its run id.
  final String runId;

  /// When its run started.
  final DateTime startedAt;

  /// When its run finished, or null when it has no `summary` line.
  final DateTime? finishedAt;

  /// The config its run was started from, as recorded.
  final String? configPath;

  /// Its rows.
  final List<StreamingResultRow> rows;

  /// What a reader should know: a run that did not finish, rows that could
  /// not be read.
  final List<McpDiagnostic> warnings;

  /// Reads [path] without changing it. Returns the file, or the
  /// `input_error` diagnostic that says why it cannot be read.
  static Future<Object> read(String path) async {
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return McpDiagnostic.error(
        'input.unreadable',
        '$path is not a file.',
        fix:
            'Give the results.ndjson a run wrote; simcrux run names it as '
            'results_path.',
      );
    }
    final List<String> lines;
    try {
      lines = await File(path)
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .toList();
    } on FileSystemException catch (e) {
      return McpDiagnostic.error(
        'input.unreadable',
        '$path could not be read: ${e.osError?.message ?? e.message}.',
      );
    }
    Map<String, Object?>? meta;
    Map<String, Object?>? summary;
    final raw = <Map<String, Object?>>[];
    var unreadable = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } on FormatException {
        unreadable++;
        continue;
      }
      if (decoded is! Map<String, Object?>) {
        unreadable++;
        continue;
      }
      switch (decoded['type']) {
        case 'meta':
          meta ??= decoded;
        case 'result':
          raw.add(decoded);
        case 'summary':
          summary = decoded;
      }
    }
    final runId = meta?['run_id'];
    final started = meta?['started_at'] is String
        ? DateTime.tryParse(meta!['started_at']! as String)
        : null;
    if (meta == null || runId is! String || runId.isEmpty || started == null) {
      return McpDiagnostic.error(
        'results.not_results',
        '$path is not a SimCrux results.ndjson: it has no meta line naming '
            'its run.',
      );
    }
    final version = meta['version'];
    if (version is int && version > 1) {
      return McpDiagnostic.error(
        'results.version',
        '$path is results format version $version; this SimCrux reads '
            'version 1.',
        fix: 'Read it with the SimCrux that wrote it, or a later one.',
      );
    }
    final rows = <StreamingResultRow>[];
    for (final r in raw) {
      final row = StreamingResultRow.parse(r);
      if (row == null) {
        unreadable++;
      } else {
        rows.add(row);
      }
    }
    final finished = summary?['finished_at'] is String
        ? DateTime.tryParse(summary!['finished_at']! as String)
        : null;
    final warnings = <McpDiagnostic>[
      if (summary == null)
        const McpDiagnostic.warning(
          'results.incomplete',
          'The file has no summary line: its run did not finish, so tests '
              'may be missing from it.',
        ),
      if (unreadable > 0)
        McpDiagnostic.warning(
          'results.unreadable_lines',
          '$unreadable lines of the file could not be read as results and '
              'were left out.',
        ),
      if (summary != null &&
          summary['total'] is int &&
          summary['total'] != rows.length)
        McpDiagnostic.warning(
          'results.rows_missing',
          'The summary counts ${summary['total']} tests and the file holds '
              '${rows.length} readable rows.',
        ),
    ];
    return SimResultsFile._(
      path: path,
      runId: runId,
      startedAt: started.toUtc(),
      finishedAt: finished?.toUtc(),
      configPath: meta['config_path'] as String?,
      rows: rows,
      warnings: warnings,
    );
  }
}

/// The `test` body for the row [id] of [file].
Future<(Map<String, Object?>, List<McpDiagnostic>)> testBody({
  required SimResultsFile file,
  required StreamingResultRow row,
  required int lines,
  required SimReadScope scope,
}) async {
  final warnings = <McpDiagnostic>[];
  final log = logPathOf(row, scope);
  LogTail? tail;
  int? failureLine;
  if (log == null) {
    warnings.add(
      const McpDiagnostic.warning(
        'log.none',
        'The run recorded no log for this test.',
      ),
    );
  } else if (!scope.allows(log)) {
    warnings.add(
      McpDiagnostic.warning(
        'log.outside',
        'The log $log is outside the root and outside SimCrux scratch, so it '
            'was not read.',
      ),
    );
  } else if (FileSystemEntity.typeSync(log) != FileSystemEntityType.file) {
    warnings.add(
      McpDiagnostic.warning(
        'log.missing',
        'The log $log is not there any more: SimCrux keeps the work folders '
            'of failing tests only, and removes the oldest past its '
            '--keep-failures count.',
      ),
    );
  } else {
    try {
      tail = await readLogTail(log, lines);
      if (kGateFailures.contains(row.status)) {
        failureLine = await firstFailureLine(log, row.failureMessage, scope);
      }
    } on FileSystemException catch (e) {
      warnings.add(
        McpDiagnostic.warning(
          'log.unreadable',
          'The log $log could not be read: '
              '${e.osError?.message ?? e.message}.',
        ),
      );
    }
  }
  final testRow = await testRowJson(row, runId: file.runId, scope: scope);
  return (
    <String, Object?>{
      'test': testRow,
      'seed': row.seed,
      'parameters': row.parameters == null
          ? null
          : <String, Object?>{
              for (final k in row.parameters!.keys.toList()..sort())
                k: row.parameters![k],
            },
      'kill_signal': row.killSignal?.wireName,
      'first_failure': failureLine == null || log == null
          ? null
          : McpSourceLocation(file: log, line: failureLine).toJson(),
      'log': tail?.toJson(),
    },
    warnings,
  );
}

/// What a build that scores flakiness says about test [id]'s [history]
/// (newest first): the `flakiness` member of a `trend` body and the
/// diagnostics that go with it. Open core has none, and its `trend` says the
/// class was withheld.
typedef SimTrendFlakiness =
    FutureOr<SimFlakinessAnswer> Function(
      String id,
      List<SimTrendPoint> history,
    );

/// A [SimTrendFlakiness] answer.
class SimFlakinessAnswer {
  /// The `flakiness` member [flakiness] (null when there is no class to
  /// give) and the [diagnostics] that say why or how.
  const SimFlakinessAnswer(
    this.flakiness, {
    this.diagnostics = const <McpDiagnostic>[],
  });

  /// `{class, score, flips, window}`, or null.
  final Map<String, Object?>? flakiness;

  /// A `licence.withheld` warning when the licence did not admit the class,
  /// or a note when the history holds nothing to classify.
  final List<McpDiagnostic> diagnostics;
}

/// One run of a test in its history.
class SimTrendPoint {
  /// The test's result in run [run].
  const SimTrendPoint({
    required this.run,
    required this.startedAt,
    required this.status,
    required this.runtime,
  });

  /// The run id.
  final String run;

  /// When the test started.
  final DateTime startedAt;

  /// How it ended.
  final TestStatus status;

  /// How long it ran.
  final Duration runtime;

  /// A `history` entry.
  Map<String, Object?> toJson() => <String, Object?>{
    'run': run,
    'started_at': _date(startedAt),
    'status': status.name,
    'runtime_ms': runtime.inMilliseconds,
  };
}

/// [id]'s history in [files], newest first: its last row in each file
/// whose simulator ran. Also the count of rows left out because their
/// simulator never ran.
(List<SimTrendPoint>, int) trendHistory(
  String id,
  List<SimResultsFile> files,
) {
  final points = <SimTrendPoint>[];
  var notRun = 0;
  for (final f in files) {
    StreamingResultRow? last;
    for (final r in f.rows) {
      if (r.testId == id) last = r;
    }
    if (last == null) continue;
    if (!last.didExecute) {
      notRun++;
      continue;
    }
    points.add(
      SimTrendPoint(
        run: f.runId,
        startedAt: last.startedAt,
        status: last.status,
        runtime: last.runtime,
      ),
    );
  }
  points.sort((a, b) {
    final byTime = b.startedAt.compareTo(a.startedAt);
    return byTime != 0 ? byTime : b.run.compareTo(a.run);
  });
  return (points, notRun);
}

/// The absolute, normalized spelling of [path] against the working
/// directory, as documents write paths.
String absolutePath(String path) => p.normalize(p.absolute(path));
