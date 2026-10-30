// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Reader for the JSON event stream `dart test` writes with
/// `--reporter json` or `--file-reporter json:<path>`.
///
/// **Why this exists.** A Dart project's tests, and in particular a
/// [ROHD](https://github.com/intel/rohd) testbench (ROHD 0.7 or later, source
/// tracing), are plain `package:test` tests. `dart test` already has a stable
/// machine-readable form (protocol `0.1.1`): one JSON object per line. This
/// file turns that stream into SimCrux's shape for a run: a list of cases, each
/// with a name, a location, a verdict, an error and stack, a duration and the
/// log lines it printed.
///
/// The stream is paired by id. `testStart` opens a case (name, `url`, `line`,
/// `column`), `print` and `error` events attach to it by `testID`, and
/// `testDone` closes it with `result` (`success`, `failure` or `error`) and
/// `skipped`. A `group` event names nothing a case needs, and `suite` /
/// `allSuites` / `start` / `done` only frame the run.
///
/// **ROHD-VF.** A ROHD-VF `Test` does not fail the way `expect` does. After the
/// simulation `Test._checkAll` throws `Exception: Test failed.` when any
/// component logged a SEVERE message, so the event is `result: error` with
/// `isFailure: false`. To the protocol that is a harness error. To the person
/// who wrote the testbench it is a failing check, so [parseDartTestReport]
/// recognises the `Test._checkAll` frame in the stack and reports it as a
/// failure with [DartTestCase.rohdVfFailure] set.
///
/// ROHD-VF logs reach the stream only as `print` events shaped
/// `[SEVERE] @ <sim time> | <logger>: <message>`. [parseRohdVfLogLine] splits
/// those into severity, simulated time, logger and message; any other printed
/// line stays a plain line.
///
/// **Never throws.** A truncated file, a line that is not JSON, an event of a
/// kind this reader does not know and a field of an unexpected type are all
/// skipped. A case that started but never finished (a crashed run) is reported
/// as an error rather than dropped.
library;

import 'dart:convert';

/// How one case ended.
enum DartTestOutcome {
  /// `result: success` and not skipped.
  pass,

  /// A failing check: `result: failure`, or a ROHD-VF `Test failed.`.
  fail,

  /// An uncaught exception, a test file that did not load, or a case that
  /// never finished.
  error,

  /// `skipped: true`.
  skip,
}

/// One log line printed by a case, split when it has the ROHD-VF shape.
class DartTestLogEntry {
  /// Creates an entry.
  const DartTestLogEntry({
    required this.message,
    this.severity,
    this.simTime,
    this.logger,
  });

  /// The text after `<logger>: ` for a ROHD-VF line, else the whole line.
  final String message;

  /// `SEVERE`, `WARNING`, `INFO`, `FINE` and so on, upper case. Null for a line
  /// that is not a ROHD-VF log line.
  final String? severity;

  /// The simulated time the line was logged at, in the simulator's time units.
  final int? simTime;

  /// The logger, in ROHD-VF the component's full name.
  final String? logger;

  /// Whether the line was split into severity, time and logger.
  bool get structured => severity != null;

  /// Whether this is a ROHD-VF warning about objections, such as "Simulation
  /// has ended before all objections were dropped!".
  bool get isObjectionWarning =>
      severity == 'WARNING' && message.toLowerCase().contains('objection');
}

/// A source location named by a stack frame or a `testStart` event.
class DartSourceLocation {
  /// Creates a location.
  const DartSourceLocation({required this.uri, this.line, this.column});

  /// A `file:` URI, a `package:` URI or a path relative to the package root.
  final String uri;

  /// 1-based line, when known.
  final int? line;

  /// 1-based column, when known.
  final int? column;

  @override
  String toString() => '$uri:$line:$column';
}

/// One test, as the stream reported it.
class DartTestCase {
  /// Creates a case.
  const DartTestCase({
    required this.id,
    required this.name,
    required this.outcome,
    this.declared,
    this.durationMs,
    this.message,
    this.stack,
    this.failureFrame,
    this.rohdVfFailure = false,
    this.skipReason,
    this.logs = const <DartTestLogEntry>[],
  });

  /// The runner's id for the case.
  final int id;

  /// The full name, group names first, as the console reporters print it.
  final String name;

  /// How it ended.
  final DartTestOutcome outcome;

  /// Where the test is declared (`test(...)` in the user's test file).
  final DartSourceLocation? declared;

  /// Wall-clock milliseconds from `testStart` to `testDone`.
  final int? durationMs;

  /// The first error event's message.
  final String? message;

  /// The first error event's stack trace.
  final String? stack;

  /// The first frame of [stack] that is the user's own code: not `dart:`, not
  /// the test runner, matcher or ROHD and ROHD-VF libraries.
  final DartSourceLocation? failureFrame;

  /// Whether this is a ROHD-VF `Test failed.` reclassified from a harness
  /// error.
  final bool rohdVfFailure;

  /// The reason given to `skip:`, when there was one.
  final String? skipReason;

  /// Everything the case printed, in order.
  final List<DartTestLogEntry> logs;

  /// ROHD-VF objection warnings among [logs].
  int get objectionWarnings => logs.where((l) => l.isObjectionWarning).length;
}

/// A whole `dart test` run.
class DartTestReport {
  /// Creates a report.
  const DartTestReport({
    required this.cases,
    required this.complete,
    this.passed,
  });

  /// Every case that ran, in the order it started.
  final List<DartTestCase> cases;

  /// Whether the stream ended with the runner's `done` event. False for a
  /// truncated file or a run that was killed.
  final bool complete;

  /// The runner's own verdict from `done.success`, when it gave one.
  final bool? passed;

  /// Cases with the given outcome.
  int count(DartTestOutcome outcome) =>
      cases.where((c) => c.outcome == outcome).length;

  /// Every case failed or errored.
  int get failing => count(DartTestOutcome.fail) + count(DartTestOutcome.error);

  /// Whether nothing failed and nothing errored.
  bool get isClean => failing == 0;

  /// ROHD-VF objection warnings across all cases.
  int get objectionWarnings =>
      cases.fold(0, (sum, c) => sum + c.objectionWarnings);
}

/// Parses a `dart test` JSON reporter stream, or returns `null` when [text]
/// holds no test events at all (empty, not JSON, or some other report).
DartTestReport? parseDartTestReport(String text) {
  final open = <int, _OpenCase>{};
  final order = <int>[];
  final done = <int, DartTestCase>{};
  var sawEvent = false;
  var complete = false;
  bool? passed;

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || !line.startsWith('{')) continue;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, Object?>) continue;
    final type = decoded['type'];
    if (type is! String) continue;
    sawEvent = true;

    switch (type) {
      case 'testStart':
        final test = decoded['test'];
        if (test is! Map<String, Object?>) break;
        final id = _int(test['id']);
        final name = test['name'];
        if (id == null || name is! String) break;
        final metadata = test['metadata'];
        final skipReason = metadata is Map<String, Object?>
            ? metadata['skipReason']
            : null;
        open[id] = _OpenCase(
          id: id,
          name: name,
          declared: _declared(test),
          startedMs: _int(decoded['time']),
          skipReason: skipReason is String ? skipReason : null,
        );
        order.add(id);
      case 'print':
        final c = open[_int(decoded['testID'])];
        final message = decoded['message'];
        if (c != null && message is String) {
          for (final piece in const LineSplitter().convert(message)) {
            c.logs.add(parseRohdVfLogLine(piece));
          }
        }
      case 'error':
        final c = open[_int(decoded['testID'])];
        if (c == null) break;
        // The first error is the cause; later ones (a tearDown failing
        // after the body did) are consequences.
        c.message ??= decoded['error'] is String
            ? decoded['error']! as String
            : null;
        c.stack ??= decoded['stackTrace'] is String
            ? decoded['stackTrace']! as String
            : null;
        c.sawFailureEvent = c.sawFailureEvent || decoded['isFailure'] == true;
      case 'testDone':
        final id = _int(decoded['testID']);
        final c = open.remove(id);
        if (c == null || id == null) break;
        final hidden = decoded['hidden'] == true;
        final result = decoded['result'];
        if (hidden && result == 'success') break;
        done[id] = c.finish(
          result: result is String ? result : 'error',
          skipped: decoded['skipped'] == true,
          endedMs: _int(decoded['time']),
        );
      case 'done':
        complete = true;
        final success = decoded['success'];
        if (success is bool) passed = success;
    }
  }

  if (!sawEvent) return null;

  // A case that never reached testDone: the run died under it.
  for (final c in open.values) {
    done[c.id] = c.finish(
      result: 'unfinished',
      skipped: false,
      endedMs: null,
    );
  }
  final cases = <DartTestCase>[
    for (final id in order)
      if (done[id] case final DartTestCase c) c,
  ];
  if (cases.isEmpty && !complete) return null;
  return DartTestReport(cases: cases, complete: complete, passed: passed);
}

/// Splits one ROHD-VF log line,
/// `[SEVERE] @ 25 | top.monitor: mismatch: 1 + 2 = 4`, into its parts.
///
/// Anything that does not have that shape comes back as a plain entry holding
/// the whole line.
DartTestLogEntry parseRohdVfLogLine(String line) {
  final m = _rohdVfLog.firstMatch(line);
  if (m == null) return DartTestLogEntry(message: line);
  return DartTestLogEntry(
    severity: m.group(1)!.toUpperCase(),
    simTime: int.tryParse(m.group(2)!),
    logger: m.group(3)!.trim(),
    message: m.group(4)!,
  );
}

/// Resolves a [DartSourceLocation.uri] to a file path.
///
/// [packageRoot] is the directory holding `pubspec.yaml`. A `file:` URI becomes
/// its path; a relative path is joined to [packageRoot]; a `package:` URI for
/// [packageName] becomes `lib/<rest>` under [packageRoot]. Anything else (a
/// `dart:` library, a dependency's `package:` URI) returns `null`, because the
/// source for it is not the user's.
String? resolveDartSourcePath(
  String uri, {
  required String packageRoot,
  String? packageName,
}) {
  if (uri.isEmpty || uri.startsWith('dart:')) return null;
  if (uri.startsWith('file:')) {
    try {
      return Uri.parse(uri).toFilePath();
    } on Object {
      return null;
    }
  }
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    if (slash < 0 || packageName == null) return null;
    if (rest.substring(0, slash) != packageName) return null;
    return _join(packageRoot, 'lib/${rest.substring(slash + 1)}');
  }
  if (uri.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(uri)) {
    return uri;
  }
  return _join(packageRoot, uri);
}

String _join(String root, String relative) {
  final sep = root.contains(r'\') && !root.contains('/') ? r'\' : '/';
  final trimmed = root.endsWith('/') || root.endsWith(r'\')
      ? root.substring(0, root.length - 1)
      : root;
  return '$trimmed$sep$relative';
}

final RegExp _rohdVfLog = RegExp(
  r'^\[([A-Za-z]+)\]\s+@\s*(\d+)\s*\|\s*([^:]+?):\s?(.*)$',
);

/// `package:test/src/...  fn`, `test/x_test.dart 76:5  main.<fn>` and
/// `dart:async  _Future.then`: the terse `stack_trace` form the runner writes.
final RegExp _frame = RegExp(r'^(\S+)(?:\s+(\d+):(\d+))?(?:\s{2,}.*)?$');

const List<String> _foreignPrefixes = <String>[
  'dart:',
  'package:test/',
  'package:test_api/',
  'package:test_core/',
  'package:matcher/',
  'package:matcher ',
  'package:stack_trace/',
  'package:async/',
  'package:rohd/',
  'package:rohd_vf/',
  'package:rohd_hierarchy/',
  'package:flutter_test/',
  'package:flutter/',
];

DartSourceLocation? _firstUserFrame(String stack) {
  for (final raw in const LineSplitter().convert(stack)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('=====')) continue;
    final m = _frame.firstMatch(line);
    if (m == null) continue;
    final uri = m.group(1)!;
    if (_foreignPrefixes.any(uri.startsWith)) continue;
    final lineNo = int.tryParse(m.group(2) ?? '');
    if (lineNo == null) continue;
    return DartSourceLocation(
      uri: uri,
      line: lineNo,
      column: int.tryParse(m.group(3) ?? ''),
    );
  }
  return null;
}

DartSourceLocation? _declared(Map<String, Object?> test) {
  // `root_*` is where the test was declared in the user's own test file when a
  // helper elsewhere created it; the plain `url` / `line` is the helper.
  final rootUrl = test['root_url'];
  final url = rootUrl is String ? rootUrl : test['url'];
  if (url is! String || url.isEmpty) return null;
  final line = rootUrl is String ? test['root_line'] : test['line'];
  final column = rootUrl is String ? test['root_column'] : test['column'];
  return DartSourceLocation(uri: url, line: _int(line), column: _int(column));
}

int? _int(Object? value) => value is int ? value : null;

class _OpenCase {
  _OpenCase({
    required this.id,
    required this.name,
    required this.declared,
    required this.startedMs,
    required this.skipReason,
  });

  final int id;
  final String name;
  final DartSourceLocation? declared;
  final int? startedMs;
  final String? skipReason;
  final List<DartTestLogEntry> logs = <DartTestLogEntry>[];
  String? message;
  String? stack;
  bool sawFailureEvent = false;

  DartTestCase finish({
    required String result,
    required bool skipped,
    required int? endedMs,
  }) {
    var rohdVf = false;
    final DartTestOutcome outcome;
    if (skipped) {
      outcome = DartTestOutcome.skip;
    } else if (result == 'success') {
      outcome = DartTestOutcome.pass;
    } else if (result == 'failure') {
      outcome = DartTestOutcome.fail;
    } else if (result != 'unfinished' && _isRohdVfFailure(stack)) {
      // `Test._checkAll` threw after the simulation: a check failed.
      outcome = DartTestOutcome.fail;
      rohdVf = true;
    } else {
      outcome = DartTestOutcome.error;
    }
    final trace = stack;
    return DartTestCase(
      id: id,
      name: name,
      outcome: outcome,
      declared: declared,
      durationMs: (startedMs != null && endedMs != null)
          ? endedMs - startedMs!
          : null,
      message:
          message ??
          (endedMs == null ? 'The run ended before this test finished.' : null),
      stack: trace,
      failureFrame: trace == null ? null : _firstUserFrame(trace),
      rohdVfFailure: rohdVf,
      skipReason: skipReason,
      logs: List<DartTestLogEntry>.unmodifiable(logs),
    );
  }
}

bool _isRohdVfFailure(String? stack) =>
    stack != null &&
    stack.contains('rohd_vf/src/test.dart') &&
    stack.contains('Test._checkAll');
