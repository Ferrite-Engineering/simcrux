// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The mutation proof for the code that maps a run to its outcome
// (`classifySimRun`; 2.0 rule 8, contracts 2.4 and 11).
//
// The oracle runs `run` and `results` through both doors (the `simcrux mcp`
// tool and the `simcrux ... --json` command line with its exit code) on
// runs whose outcome is derived by hand from contracts 2.4 and 6.1:
//
// - a run with a passing test and an `unknown` one is `failed_gate` (exit 1):
//   "an unknown test is a failed test";
// - a run in which no test produced a result (one never ran its simulator,
//   one is `unknown`) is `engine_error` (exit 3), and so is a results file
//   whose only test never ran;
// - a run whose tests all pass is `completed` (exit 0).
//
// The real mapping keeps every expectation. Two deliberately broken
// mappings must each break at least one: one that reads `unknown` as a pass,
// and one that calls a run with no results completed.

@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';

import 'support/spec_cases.dart';

/// A row like [r] whose status is [status].
StreamingResultRow _withStatus(StreamingResultRow r, TestStatus status) =>
    StreamingResultRow(
      testId: r.testId,
      status: status,
      runtime: r.runtime,
      startedAt: r.startedAt,
      testName: r.testName,
      suiteName: r.suiteName,
      simulatorId: r.simulatorId,
      finishedAt: r.finishedAt,
      exitCode: r.exitCode,
      waveformPath: r.waveformPath,
      stdoutPath: r.stdoutPath,
      stderrPath: r.stderrPath,
      failureMessage: r.failureMessage,
      killSignal: r.killSignal,
      didExecute: r.didExecute,
      metrics: r.metrics,
      seed: r.seed,
      parameters: r.parameters,
    );

/// Broken: an `unknown` test is read as a pass.
SimRunVerdict _unknownAsPassed(SimRunFacts facts) => classifySimRun(
  SimRunFacts(
    rows: <StreamingResultRow>[
      for (final r in facts.rows)
        if (r.status == TestStatus.unknown)
          _withStatus(r, TestStatus.pass)
        else
          r,
    ],
    selected: facts.selected,
    cancelled: facts.cancelled,
    finished: facts.finished,
  ),
);

/// Broken: a run in which no test produced a result is completed.
SimRunVerdict _noResultsCompleted(SimRunFacts facts) =>
    facts.rows.any(producedResult)
    ? classifySimRun(facts)
    : const SimRunVerdict(McpOutcome.completed, <McpDiagnostic>[]);

void main() {
  final spec = SpecCases.load();
  tearDownAll(spec.dispose);
  File(p.join(spec.root, 'unknown_only', 'simcrux.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      File(
        p.join(spec.root, 'allpass', 'simcrux.yaml'),
      ).readAsStringSync().replaceFirst('name: b', 'name: b_unknown'),
    );

  /// Each hand-derived expectation the mapping [classify] breaks, at either
  /// door.
  Future<List<String>> oracleProblems(SimRunClassifier classify) async {
    final problems = <String>[];
    final cli = spec.cli(classify: classify);
    for (final (tool, arguments, outcome)
        in <(String, Map<String, Object?>, McpOutcome)>[
          (
            'run',
            <String, Object?>{'config': 'unknown_only/simcrux.yaml'},
            McpOutcome.failedGate,
          ),
          (
            'run',
            <String, Object?>{'config': 'design/simcrux.yaml'},
            McpOutcome.failedGate,
          ),
          (
            'run',
            <String, Object?>{'config': 'nores/simcrux.yaml'},
            McpOutcome.engineError,
          ),
          (
            'results',
            <String, Object?>{'results': 'runs/run_d.ndjson'},
            McpOutcome.engineError,
          ),
          (
            'run',
            <String, Object?>{'config': 'allpass/simcrux.yaml'},
            McpOutcome.completed,
          ),
        ]) {
      final c = SpecCaseForTest(tool, arguments);
      final Map<String, Object?> result;
      try {
        result = await spec.callTool(cli, c.asCase);
      } on Object catch (e) {
        problems.add('$tool $arguments: the tool failed: $e');
        continue;
      }
      final text = SpecCases.text(result);
      final got = (jsonDecode(text) as Map<String, Object?>)['outcome'];
      if (got != outcome.wireName) {
        problems.add(
          '$tool $arguments: tool said $got, not ${outcome.wireName}',
        );
      }
      final (_, code) = await spec.runCommandLine(cli, spec.argv(c.asCase));
      final want = McpExitCodes.suite.exitCodeFor(outcome);
      if (code != want) {
        problems.add('$tool $arguments: command line exited $code, not $want');
      }
    }
    return problems;
  }

  test('the real mapping keeps every hand-derived outcome', () async {
    expect(await oracleProblems(classifySimRun), isEmpty);
  });

  test('a mapping that reads unknown as a pass is caught', () async {
    final problems = await oracleProblems(_unknownAsPassed);
    expect(
      problems.where((m) => m.contains('unknown_only')),
      hasLength(2),
      reason: '$problems',
    );
  });

  test(
    'a mapping that calls a run with no results completed is caught',
    () async {
      final problems = await oracleProblems(_noResultsCompleted);
      expect(
        problems.where((m) => m.contains('nores')),
        hasLength(2),
        reason: '$problems',
      );
      expect(
        problems.where((m) => m.contains('run_d')),
        hasLength(2),
        reason: '$problems',
      );
    },
  );
}

/// A [SpecCase] made in code rather than read from `cases.json`.
class SpecCaseForTest {
  SpecCaseForTest(this.tool, this.arguments);

  final String tool;
  final Map<String, Object?> arguments;

  SpecCase get asCase => SpecCase.of(
    golden: '-',
    tool: tool,
    arguments: arguments,
  );
}
