// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Checks the formal fixture corpus (verification/fixtures/formal/) against
// its hand-written expectations.
//
// The same checks run twice: over the committed captures on every CI run,
// and over a fresh run of the real tools in the live test when an OSS CAD
// Suite is available. They read tool output with their own small parsers,
// deliberately independent of SimCrux's production readers: the question
// here is whether the tools still behave the way the properties' meaning
// says, not whether our reader agrees with itself.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const String kFormalFixtureRoot = 'verification/fixtures/formal';

/// Every sby case. Spelled out so a deleted case fails instead of
/// quietly shrinking the corpus.
const List<String> kFormalSbyCases = <String>[
  'handshake_imm',
  'handshake_slang',
  'fifo_slang',
  'handshake_temporal',
  'pretrace',
  'vacuity',
];

/// Every EQY run, one `.eqy` file each.
const List<String> kFormalEqyRuns = <String>[
  'alu_pass',
  'alu_pass2',
  'alu_fail',
  'alu_fail2',
];

/// The number of SVA construct probes in `sva_matrix/probes/`.
const int kFormalSvaProbeCount = 51;

const List<String> kFormalSvaFrontends = <String>['builtin', 'slang'];

Map<String, Object?> readJsonObject(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> objectList(Object? raw) =>
    (raw as List<Object?>? ?? const <Object?>[])
        .cast<Map<String, Object?>>()
        .toList();

// ---------------------------------------------------------------------------
// VCD
// ---------------------------------------------------------------------------

/// The value of every signal at every `smt_step` of a Yosys-SMTBMC VCD.
/// A value with an `x` or `z` bit is null. When a step appears twice (the
/// writer repeats the last step), the first occurrence wins.
Map<int, Map<String, int?>> vcdSteps(String text) {
  final namesById = <String, List<String>>{};
  final values = <String, int?>{};
  final steps = <int, Map<String, int?>>{};
  int? step;
  void snapshot() {
    if (step != null) steps.putIfAbsent(step!, () => Map.of(values));
  }

  void assign(String id, String bits) {
    final names = namesById[id];
    if (names == null) return;
    final value = RegExp(r'^[01]+$').hasMatch(bits)
        ? int.parse(bits, radix: 2)
        : null;
    for (final name in names) {
      values[name] = value;
      if (name == 'smt_step' && value != null) step = value;
    }
  }

  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final tokens = line.split(RegExp(r'\s+'));
    if (tokens.first == r'$var' && tokens.length >= 5) {
      namesById.putIfAbsent(tokens[3], () => <String>[]).add(tokens[4]);
    } else if (line.startsWith('#')) {
      snapshot();
    } else if (line.startsWith('b') && tokens.length == 2) {
      assign(tokens[1], tokens[0].substring(1));
    } else if (tokens.length == 1 && '01xzXZ'.contains(line[0])) {
      assign(line.substring(1), line[0]);
    }
  }
  snapshot();
  return steps;
}

/// Problems with [trace] against a hand-written `trace_check`.
List<String> checkTrace(Map<String, Object?> check, String trace) {
  final signal = check['signal']! as String;
  final steps = vcdSteps(trace);
  if (steps.isEmpty) return ['trace has no smt_step values'];
  final seen = steps.values.where((v) => v.containsKey(signal)).toList();
  if (seen.isEmpty) return ['trace does not carry $signal'];
  if (check.containsKey('equals')) {
    final at = check['at_step']! as int;
    final actual = steps[at]?[signal];
    return actual == check['equals']
        ? const []
        : ['$signal at step $at is $actual, expected ${check['equals']}'];
  }
  if (check.containsKey('above')) {
    final bound = check['above']! as int;
    return seen.any((v) => (v[signal] ?? -1) > bound)
        ? const []
        : ['$signal never exceeds $bound in the trace'];
  }
  if (check.containsKey('never')) {
    final banned = check['never'];
    return seen.any((v) => v[signal] == banned)
        ? ['$signal takes $banned at some step; the trace must never show it']
        : const [];
  }
  return ['unknown trace_check shape: $check'];
}

// ---------------------------------------------------------------------------
// sby
// ---------------------------------------------------------------------------

class SbySummaryProperty {
  SbySummaryProperty({
    required this.kind,
    required this.name,
    required this.file,
    required this.line,
    required this.step,
    required this.trace,
  });

  /// `assert` or `cover`.
  final String kind;
  final String name;
  final String file;
  final int line;

  /// Null for an induction counterexample, which is NOT a real trace of
  /// the design and carries no step.
  final int? step;

  /// The trace path relative to the task directory, or null.
  final String? trace;
}

class SbyTaskLog {
  SbyTaskLog._(this.done, this.properties, this.errorLines);

  factory SbyTaskLog.parse(String text) {
    String? done;
    String? trace;
    final properties = <SbySummaryProperty>[];
    final errorLines = <int>[];
    final doneRe = RegExp(r'DONE \((\w+), rc=\d+\)');
    final traceRe = RegExp(
      r'summary: (?:counterexample|cover) trace(?: \[\w+\])?: (\S+)',
    );
    final propRe = RegExp(
      r'summary:\s+(failed assertion|reached cover statement) (\S+) at '
      r'([^\s:]+):(\d+)\.\S*(?: step (\d+))?\s*$',
    );
    final errorRe = RegExp(r'([\w.]+\.s?v):(\d+)(?::\d+)?: (?:ERROR|error)');
    for (final line in const LineSplitter().convert(text)) {
      final d = doneRe.firstMatch(line);
      if (d != null) done = d.group(1);
      final t = traceRe.firstMatch(line);
      if (t != null) {
        // `<job>_<task>/engine_0/trace.vcd`: drop the task directory.
        final parts = p.posix.split(t.group(1)!);
        trace = p.posix.joinAll(parts.skip(1));
      }
      final m = propRe.firstMatch(line);
      if (m != null) {
        properties.add(
          SbySummaryProperty(
            kind: m.group(1)!.startsWith('failed') ? 'assert' : 'cover',
            name: m.group(2)!,
            file: m.group(3)!,
            line: int.parse(m.group(4)!),
            step: m.group(5) == null ? null : int.parse(m.group(5)!),
            trace: trace,
          ),
        );
      }
      final e = errorRe.firstMatch(line);
      if (e != null) errorLines.add(int.parse(e.group(2)!));
    }
    return SbyTaskLog._(done, properties, errorLines);
  }

  /// The `DONE (<TOKEN>, …)` token, or null when there is none.
  final String? done;
  final List<SbySummaryProperty> properties;
  final List<int> errorLines;

  /// Real counterexamples: failed assertions that carry a step. The
  /// induction summary repeats the property without a step and must
  /// never count as one.
  Iterable<SbySummaryProperty> get counterexamples =>
      properties.where((s) => s.kind == 'assert' && s.step != null);

  Iterable<SbySummaryProperty> get reached =>
      properties.where((s) => s.kind == 'cover');
}

/// Final per-property statuses from `sby --statusfmt jsonl`, keyed by
/// `<task>:<line>`.
Map<String, String> statusByTaskLine(String jsonl) {
  final out = <String, String>{};
  for (final line in const LineSplitter().convert(jsonl)) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('{')) continue;
    final rec = jsonDecode(trimmed) as Map<String, Object?>;
    final location = rec['location'] as String?;
    final match = RegExp(r':(\d+)\.').firstMatch(location ?? '');
    if (match == null) continue;
    out['${rec['task_name']}:${match.group(1)}'] = rec['status']! as String;
  }
  return out;
}

/// Problems with one sby case against its `.expected.json`.
///
/// [taskLog] returns a task's log text or null; [taskFile] returns a file
/// under a task's directory (a trace) or null.
List<String> checkSbyCase({
  required Map<String, Object?> expected,
  required String? Function(String task) taskLog,
  required String? Function(String task, String relative) taskFile,
  required String statusJsonl,
}) {
  final problems = <String>[];
  final status = statusByTaskLine(statusJsonl);
  final refused = objectList(
    expected['refused_constructs'],
  ).map((r) => r['line']! as int).toSet();
  final tasks = expected['tasks']! as Map<String, Object?>;
  for (final MapEntry(key: task, value: raw) in tasks.entries) {
    final spec = raw! as Map<String, Object?>;
    final text = taskLog(task);
    if (text == null) {
      problems.add('$task: no task log');
      continue;
    }
    final log = SbyTaskLog.parse(text);
    if (log.done != spec['verdict']) {
      problems.add('$task: DONE ${log.done}, expected ${spec['verdict']}');
    }
    // The frontend's own error: newer sby builds repeat it in the task log;
    // older ones keep it only in the Yosys log (captured as design.log,
    // model/design.log in a live work dir).
    final errorLines = <int>{
      ...log.errorLines,
      for (final rel in ['design.log', 'model/design.log'])
        ...SbyTaskLog.parse(taskFile(task, rel) ?? '').errorLines,
    };
    if (spec['error_line'] case final int line) {
      if (!errorLines.contains(line)) {
        problems.add('$task: no ERROR at line $line (saw $errorLines)');
      }
    }
    if (spec['error_line_in'] == 'refused_constructs' &&
        !errorLines.any(refused.contains)) {
      problems.add(
        '$task: no ERROR on a refused construct line '
        '(saw $errorLines, refused $refused)',
      );
    }
    for (final prop in objectList(spec['properties'])) {
      problems.addAll(
        _checkProperty(task, prop, log, status, taskFile).map(
          (m) => '$task line ${prop['line']}: $m',
        ),
      );
    }
  }
  return problems;
}

List<String> _checkProperty(
  String task,
  Map<String, Object?> prop,
  SbyTaskLog log,
  Map<String, String> status,
  String? Function(String task, String relative) taskFile,
) {
  final line = prop['line']! as int;
  final label = prop['label'] as String?;
  final failed = log.counterexamples.where((s) => s.line == line).toList();
  final problems = <String>[];
  List<String> traceProblems(SbySummaryProperty summary) {
    final check = prop['trace_check'] as Map<String, Object?>?;
    if (check == null) return const [];
    if (summary.trace == null) return ['no trace named for it'];
    final text = taskFile(task, summary.trace!);
    if (text == null) return ['trace ${summary.trace} is missing'];
    return checkTrace(check, text);
  }

  switch (prop['result']) {
    case 'proved':
      if (failed.isNotEmpty) {
        problems.add('expected proved, has a counterexample');
      }
      if (status['$task:$line'] != 'PASS') {
        problems.add('final status ${status['$task:$line']}, expected PASS');
      }
    case 'not_failed':
      if (failed.isNotEmpty) {
        problems.add('must not fail, but has a counterexample');
      }
    case 'counterexample':
      if (failed.isEmpty) return ['expected a counterexample, found none'];
      final cex = failed.first;
      if (label != null && !cex.name.endsWith('.$label')) {
        problems.add('name ${cex.name} does not carry label $label');
      }
      if (prop['step'] case final int step when cex.step != step) {
        problems.add('step ${cex.step}, expected $step');
      }
      if (prop['step_at_least'] case final int min when cex.step! < min) {
        problems.add('step ${cex.step}, expected at least $min');
      }
      problems.addAll(traceProblems(cex));
    case 'reached':
      final hits = log.reached.where((s) => s.line == line).toList();
      if (hits.isEmpty) return ['expected reached, no reached summary'];
      final hit = hits.first;
      if (label != null && !hit.name.endsWith('.$label')) {
        problems.add('name ${hit.name} does not carry label $label');
      }
      if (prop['step'] case final int step when hit.step != step) {
        problems.add('reached at step ${hit.step}, expected $step');
      }
      problems.addAll(traceProblems(hit));
    default:
      problems.add('unknown expected result ${prop['result']}');
  }
  return problems;
}

// ---------------------------------------------------------------------------
// EQY
// ---------------------------------------------------------------------------

/// Problems with one EQY run's log against its expectation.
List<String> checkEqyRun(Map<String, Object?> run, String log) {
  final problems = <String>[];
  final done = RegExp(r'DONE \((\w+), rc=\d+\)').firstMatch(log)?.group(1);
  if (done != run['verdict']) {
    problems.add('DONE $done, expected ${run['verdict']}');
  }
  final failed = RegExp(
    r'Failed to prove equivalence of partition (\S+)\s*$',
    multiLine: true,
  ).allMatches(log).map((m) => m.group(1)!.split('.').last).toSet();
  if (run['verdict'] == 'PASS') {
    if (failed.isNotEmpty) {
      problems.add('PASS run lists failed partitions $failed');
    }
    if (!log.contains('Successfully proved designs equivalent')) {
      problems.add('PASS run never says the designs were proved equivalent');
    }
  }
  if (run['failing_outputs'] case final List<Object?> outputs) {
    final want = outputs.cast<String>().toSet();
    if (failed.length != want.length || !failed.containsAll(want)) {
      problems.add('failing partitions $failed, expected $want');
    }
  }
  return problems;
}

// ---------------------------------------------------------------------------
// SVA matrix
// ---------------------------------------------------------------------------

/// Problems with one probe run through one frontend.
List<String> checkSvaProbe({
  required Map<String, Object?> probe,
  required String frontend,
  required int exitCode,
  required int? cells,
  required String log,
}) {
  final problems = <String>[];
  final expectedCells = probe['cells']! as int;
  final accepted = exitCode == 0;
  if (accepted && cells != expectedCells) {
    problems.add(
      'accepted with $cells formal cells, expected $expectedCells: '
      'a silently dropped property',
    );
  }
  if (!accepted && !log.contains('ERROR')) {
    problems.add('refused (exit $exitCode) without an ERROR line');
  }
  switch (probe[frontend]) {
    case 'accept' when !accepted:
      problems.add('documented as accepted, but refused');
    case 'refuse' when accepted:
      problems.add('documented as refused, but accepted');
  }
  return problems;
}
