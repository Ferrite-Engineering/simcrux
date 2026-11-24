// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The four commands outside the goldens: `run` and `results` describe the
// same run the same way, the log tail's bounds, the read scope, the command
// lines' help and plain text, and the outcome rule's cases one by one.
// (`--ci --json` is unchanged, contracts decision 7: its `{"totals": ...}`
// stays held by test/core/cli/simcrux_cli_test.dart and
// test/services/ci/ci_runner_test.dart.)

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/headless/sim_commands.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';

import 'support/spec_cases.dart';

StreamingResultRow _row(
  String id,
  TestStatus status, {
  bool didExecute = true,
}) => StreamingResultRow(
  testId: id,
  status: status,
  runtime: Duration.zero,
  startedAt: DateTime.utc(2026, 11, 20),
  didExecute: didExecute,
);

void main() {
  final spec = SpecCases.load();
  tearDownAll(spec.dispose);

  Future<(List<String>, List<String>, int)> run(
    List<String> args, {
    SimcruxCli? cli,
  }) async {
    final out = <String>[];
    final err = <String>[];
    final code = await (cli ?? spec.cli()).run(
      args,
      stdoutSink: out.add,
      stderrSink: err.add,
    );
    return (out, err, code);
  }

  test('run and results describe the same run in the same words', () async {
    final config = p.join(spec.root, 'design', 'simcrux.yaml');
    final (runOut, _, runCode) = await run(<String>['run', config, '--json']);
    final runDoc = jsonDecode(runOut.join('\n')) as Map<String, Object?>;
    final body = runDoc['body']! as Map<String, Object?>;
    final resultsPath = body['results_path']! as String;
    final (resultsOut, _, resultsCode) = await run(<String>[
      'results',
      resultsPath,
      '--json',
    ]);
    final resultsDoc =
        jsonDecode(resultsOut.join('\n')) as Map<String, Object?>;
    expect(resultsDoc['body'], body);
    expect(resultsDoc['outcome'], runDoc['outcome']);
    expect(resultsDoc['diagnostics'], runDoc['diagnostics']);
    expect(resultsCode, runCode);
  });

  group('the command lines', () {
    test('--help names each command and its usage', () async {
      for (final name in SimCommands.names) {
        final (out, _, code) = await run(<String>[name, '--help']);
        expect(code, 0);
        expect(out.join('\n'), contains('Usage: simcrux $name'));
        expect(out.join('\n'), isNot(contains('--root')));
      }
      final (out, _, _) = await run(<String>['--help']);
      expect(out.join('\n'), contains('mcp [--root <dir>]'));
    });

    test(
      'without --json a person gets short text and the same exit code',
      () async {
        final (out, err, code) = await run(<String>[
          'results',
          p.join(spec.root, 'runs', 'run_b.ndjson'),
        ]);
        expect(code, 1);
        expect(out.first, startsWith('simcrux: 5 tests'));
        expect(out.join('\n'), contains('fail  alu/sub_fail'));
        expect(out.join('\n'), isNot(contains('"schema_version"')));
        expect(err.join('\n'), contains('simcrux results: error:'));
      },
    );

    test(
      'a usage error is the usage document with --json, and exit 64',
      () async {
        final (out, _, code) = await run(<String>['test', '--json']);
        expect(code, 64);
        expect(
          (jsonDecode(out.join('\n')) as Map<String, Object?>)['outcome'],
          'usage_error',
        );
      },
    );

    test('run refuses a missing config as input_error', () async {
      final (out, _, code) = await run(<String>[
        'run',
        p.join(spec.root, 'nothing.yaml'),
        '--json',
      ]);
      expect(code, 65);
      expect(out.join('\n'), contains('input.unreadable'));
    });
  });

  group('the log', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('simcrux_log_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test(
      'the tail counts its lines from 1 and says what it left out',
      () async {
        final log = File(p.join(dir.path, 'a.txt'))
          ..writeAsStringSync(
            '${List<String>.generate(10, (i) => 'line ${i + 1}').join('\n')}\n',
          );
        final tail = await readLogTail(log.path, 3);
        expect(tail.lines, <String>['line 8', 'line 9', 'line 10']);
        expect(tail.fromLine, 8);
        expect(tail.truncated, isTrue);
        final whole = await readLogTail(log.path, 100);
        expect(whole.fromLine, 1);
        expect(whole.truncated, isFalse);
        expect(whole.lines, hasLength(10));
      },
    );

    test('the tail is at most 64 KiB whatever the line count', () async {
      final line = 'x' * 1000;
      final log = File(p.join(dir.path, 'big.txt'))
        ..writeAsStringSync('${List<String>.filled(200, line).join('\n')}\n');
      final tail = await readLogTail(log.path, 1000);
      final bytes = tail.lines.fold<int>(0, (n, l) => n + l.length + 1);
      expect(bytes, lessThanOrEqualTo(kMaxLogTailBytes));
      expect(tail.lines.length, 65);
      expect(tail.fromLine, 200 - 65 + 1);
      final one = File(p.join(dir.path, 'one.txt'))
        ..writeAsStringSync('${'y' * 100000}\n');
      final cut = await readLogTail(one.path, 10);
      expect(cut.lines.single.length, kMaxLogTailBytes);
    });

    test('the failing line is found only inside the read scope', () async {
      final log = File(p.join(dir.path, 'f.txt'))
        ..writeAsStringSync('start\nERROR: x went wrong\nend\n');
      expect(
        await firstFailureLine(
          log.path,
          'ERROR: x went wrong\nmore detail',
          SimReadScope.unlimited(),
        ),
        2,
      );
      expect(
        await firstFailureLine(log.path, 'nowhere', SimReadScope.unlimited()),
        isNull,
      );
      final elsewhere = Directory.systemTemp.createTempSync('simcrux_root_');
      addTearDown(() => elsewhere.deleteSync(recursive: true));
      expect(
        await firstFailureLine(
          log.path,
          'ERROR: x went wrong',
          SimReadScope(<Confinement>[Confinement(elsewhere.path)]),
        ),
        isNull,
      );
    });
  });

  group('the outcome rule, case by case', () {
    SimRunVerdict classify(
      List<StreamingResultRow> rows, {
      int? selected,
      bool cancelled = false,
      bool finished = true,
    }) => classifySimRun(
      SimRunFacts(
        rows: rows,
        selected: selected,
        cancelled: cancelled,
        finished: finished,
      ),
    );

    String codes(SimRunVerdict v) => v.diagnostics.map((d) => d.code).join();

    test('every test passing is completed; vacuous does not fail it', () {
      final v = classify(<StreamingResultRow>[
        _row('a', TestStatus.pass),
        _row('b', TestStatus.vacuous),
      ]);
      expect(v.outcome, McpOutcome.completed);
      expect(v.diagnostics, isEmpty);
    });

    test('a fail, a timeout or an unknown test fails the gate', () {
      for (final s in kGateFailures) {
        final v = classify(<StreamingResultRow>[
          _row('a', TestStatus.pass),
          _row('b', s),
        ]);
        expect(v.outcome, McpOutcome.failedGate, reason: s.name);
        expect(codes(v), 'gate.failed');
      }
    });

    test('no result at all is engine_error', () {
      for (final rows in <List<StreamingResultRow>>[
        <StreamingResultRow>[_row('a', TestStatus.unknown)],
        <StreamingResultRow>[_row('a', TestStatus.fail, didExecute: false)],
        <StreamingResultRow>[_row('a', TestStatus.cancelled)],
        <StreamingResultRow>[_row('a', TestStatus.skipped)],
      ]) {
        expect(classify(rows).outcome, McpOutcome.engineError);
        expect(codes(classify(rows)), 'run.no_results');
      }
      expect(
        classify(const <StreamingResultRow>[], finished: false).outcome,
        McpOutcome.engineError,
      );
    });

    test('a cancelled run, or a test that never reported, is engine_error', () {
      expect(
        codes(
          classify(<StreamingResultRow>[
            _row('a', TestStatus.pass),
          ], cancelled: true),
        ),
        'run.cancelled',
      );
      final v = classify(<StreamingResultRow>[
        _row('a', TestStatus.pass),
      ], selected: 2);
      expect(v.outcome, McpOutcome.engineError);
      expect(codes(v), 'run.unreported');
    });

    test('nothing selected is input_error', () {
      final v = classify(const <StreamingResultRow>[], selected: 0);
      expect(v.outcome, McpOutcome.inputError);
      expect(codes(v), 'run.no_tests');
    });

    test('a simulator that never ran beside ones that did is a warning, and '
        'its test fails the gate', () {
      final v = classify(<StreamingResultRow>[
        _row('a', TestStatus.pass),
        _row('b', TestStatus.fail, didExecute: false),
      ]);
      expect(v.outcome, McpOutcome.failedGate);
      expect(
        v.diagnostics.map((d) => d.code),
        <String>['gate.failed', 'engine.missing'],
      );
    });

    test('every verdict keeps the document contract', () {
      for (final v in <SimRunVerdict>[
        classify(<StreamingResultRow>[_row('a', TestStatus.pass)]),
        classify(<StreamingResultRow>[_row('a', TestStatus.fail)]),
        classify(<StreamingResultRow>[_row('a', TestStatus.unknown)]),
        classify(const <StreamingResultRow>[], selected: 0),
      ]) {
        final doc = McpDocument(
          tool: const McpProgram(name: 'simcrux', version: '0.0.0'),
          command: 'run',
          outcome: v.outcome,
          diagnostics: v.diagnostics,
        );
        expect(doc.contractProblems(), isEmpty);
      }
    });
  });
}
