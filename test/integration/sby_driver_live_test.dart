// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration', 'oss-cad-live'])
library;

// The `sby` driver against a real SymbiYosys: every task of the corpus's
// sby cases, run by SbyDriver exactly as the app runs it (`sby -f -d
// <task dir> --live jsonl`), checked against the hand-written expectations.
// It also checks that reading status.sqlite left nothing beside it.
//
// Needs an OSS CAD Suite build: set OSS_CAD_SUITE to the directory holding
// its bin/, or put that bin/ on PATH. Without one every test is skipped,
// unless FORMAL_LIVE_REQUIRED=1, which turns a missing tool into a failure.
// A disagreement means the tool changed or an expectation was wrong; read
// the corpus PROVENANCE.md, and never copy the tool's answer into an
// expectation.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`
// so these tool-gated skips do not count against its skip ceiling.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../support/formal_fixture_checks.dart';
import '../support/formal_reader_checks.dart';

bool get _required => Platform.environment['FORMAL_LIVE_REQUIRED'] == '1';

final String? _sby = () {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) {
    final sby = p.join(suite, 'bin', 'sby');
    return File(sby).existsSync() ? sby : null;
  }
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'sby',
  ]);
  if (which.exitCode != 0) return null;
  final first = (which.stdout as String).split('\n').first.trim();
  return first.isEmpty ? null : first;
}();

bool _hasSlang(String sby) {
  final yosys = p.join(p.dirname(sby), 'yosys');
  if (!File(yosys).existsSync()) return false;
  return Process.runSync(yosys, [
        '-Q',
        '-q',
        '-p',
        'plugin -i slang',
      ]).exitCode ==
      0;
}

/// The SVA diagnostic and the pre-trace marker against the hand
/// expectation: a refused task names a line and the class of one of the
/// case's `refused_constructs`; a property whose `pretrace` says it depends
/// on state before the trace carries the marker, and one that says it does
/// not carries none.
List<String> _checkAnalysis(
  String task,
  Map<String, Object?> spec,
  Map<String, Object?> expected,
  Map<String, String> metrics,
) {
  final problems = <String>[];
  final refused = <int, String>{
    for (final r in objectList(expected['refused_constructs']))
      r['line']! as int: r['class']! as String,
  };
  if (spec['verdict'] == 'ERROR' && refused.isNotEmpty) {
    final location = metrics['formal.sva.location'] ?? '';
    final line = int.tryParse(
      RegExp(r':(\d+)$').firstMatch(location)?.group(1) ?? '',
    );
    if (metrics['formal.not_run_reason'] != 'sva_unsupported') {
      problems.add('$task: refused, but no SVA diagnostic');
    } else if (line == null || !refused.containsKey(line)) {
      problems.add('$task: diagnostic at "$location", not a refused line');
    } else if (metrics['formal.sva.class'] != refused[line]) {
      problems.add(
        '$task: class ${metrics['formal.sva.class']} at line $line, '
        'expected ${refused[line]}',
      );
    }
  }
  final flaggedLines = <int>{};
  for (var n = 0; metrics.containsKey('formal.property.$n.kind'); n++) {
    if (!metrics.containsKey('formal.property.$n.pretrace')) continue;
    final location = metrics['formal.property.$n.location'] ?? '';
    final line = RegExp(r':(\d+)').firstMatch(location)?.group(1);
    if (line != null) flaggedLines.add(int.parse(line));
  }
  for (final prop in objectList(spec['properties'])) {
    final pretrace = prop['pretrace'] as Map<String, Object?>?;
    if (pretrace == null) continue;
    final line = prop['line']! as int;
    final want = pretrace['depends_on_state_before_trace'] == true;
    if (flaggedLines.contains(line) != want) {
      problems.add(
        '$task line $line: pre-trace marker '
        '${want ? 'missing' : 'set on a correctly constrained property'}',
      );
    }
  }
  return problems;
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('sby_driver_live_'));
  tearDown(() => root.deleteSync(recursive: true));

  for (final name in kFormalSbyCases) {
    test(
      '$name: every task through SbyDriver matches its expectation',
      () async {
        final sby = _sby;
        if (sby == null) {
          const reason = 'sby not found; set OSS_CAD_SUITE or put it on PATH';
          if (_required) fail('FORMAL_LIVE_REQUIRED=1 and $reason');
          markTestSkipped(reason);
          return;
        }
        final caseDir = p.absolute(kFormalFixtureRoot, 'sby', name);
        final expected = readJsonObject(p.join(caseDir, '$name.expected.json'));
        if (expected['frontend'] == 'slang' && !_hasSlang(sby)) {
          if (_required) fail('FORMAL_LIVE_REQUIRED=1 and no yosys-slang');
          markTestSkipped('this build has no yosys-slang plugin');
          return;
        }
        final project = Directory(p.join(root.path, name))..createSync();
        for (final f in Directory(caseDir).listSync().whereType<File>()) {
          if (f.path.endsWith('.sby') ||
              f.path.endsWith('.sv') ||
              f.path.endsWith('.v')) {
            f.copySync(p.join(project.path, p.basename(f.path)));
          }
        }
        final sbyFile = p.join(project.path, '$name.sby');
        final problems = <String>[];
        final tasks = expected['tasks']! as Map<String, Object?>;
        for (final MapEntry(key: task, value: spec) in tasks.entries) {
          final work = Directory(p.join(root.path, 'work', name, task))
            ..createSync(recursive: true);
          final finished =
              (await SbyDriver()
                      .execute(
                        ExecuteRequest(
                          test: TestSpec(
                            id: '$name/$task',
                            name: task,
                            suiteName: name,
                            simulatorId: SbyDriver.kId,
                            top: task,
                            formal: FormalConfig(
                              sbyFile: sbyFile,
                              task: task,
                              sbyBinary: sby,
                              projectRoot: project.path,
                            ),
                          ),
                          workingDirectory: work.path,
                          compileResult: null,
                          binaryConfig: const SimulatorBinaryConfig(
                            simulatorId: SbyDriver.kId,
                          ),
                        ),
                      )
                      .toList())
                  .whereType<TestExecutionFinished>()
                  .single;
          final taskDir = p.join(work.path, task);
          problems.addAll(
            checkReportedTask(
              task: task,
              spec: spec! as Map<String, Object?>,
              verdict: finished.metrics['formal.verdict'] ?? '(none)',
              properties: reportedFromMetrics(finished.metrics),
              taskDirectory: taskDir,
            ),
          );
          if (finished.metrics['formal.verdict_disagreement'] == '1') {
            problems.add('$task: the sources disagreed');
          }
          problems.addAll(
            _checkAnalysis(
              task,
              spec as Map<String, Object?>,
              expected,
              finished.metrics,
            ),
          );
          for (
            var n = 0;
            finished.metrics.containsKey('formal.property.$n.kind');
            n++
          ) {
            final id = finished.metrics['formal.property.$n.id'];
            final labelled = finished.metrics.containsKey(
              'formal.property.$n.label',
            );
            if (!labelled &&
                (id == null || !RegExp(r'^[0-9a-f]{16}$').hasMatch(id))) {
              problems.add('$task: unlabelled property $n has no signature id');
            }
          }
          final db = File(p.join(taskDir, 'status.sqlite'));
          if (db.existsSync()) {
            for (final suffix in ['-shm', '-wal', '-journal']) {
              if (File('${db.path}$suffix').existsSync()) {
                problems.add('$task: status.sqlite$suffix left beside it');
              }
            }
          }
        }
        expect(problems, isEmpty, reason: problems.join('\n'));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
}
