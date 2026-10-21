// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration'])
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
