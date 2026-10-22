// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration', 'oss-cad-live'])
library;

// The eqy driver against a real EQY: every EQY run of the corpus, run by
// EqyDriver exactly as the app runs it (`eqy -f -d <work dir> <file.eqy>`),
// checked against the hand expectations: the row verdict, each partition's
// result, a counterexample trace inside the work directory for each
// partition that is not equivalent and none for one that is. Then the
// import-load-run round trip: `simcrux import-eqy`, the config loader and the
// scheduler.
//
// Needs an OSS CAD Suite build: set OSS_CAD_SUITE to the directory holding
// its bin/, or put that bin/ on PATH. Without one every test is skipped,
// unless FORMAL_LIVE_REQUIRED=1, which turns a missing tool into a failure.
// A disagreement means the tool changed or an expectation was wrong; read
// the corpus PROVENANCE.md, and never copy the tool's answer into an
// expectation.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`
// so these tool-gated skips do not count against its skip ceiling; the engine
// canary runs them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/formal_import_cli.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

import '../support/eqy_workdir_fixture.dart';
import '../support/formal_fixture_checks.dart';

bool get _required => Platform.environment['FORMAL_LIVE_REQUIRED'] == '1';

final String? _eqy = () {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) {
    final eqy = p.join(suite, 'bin', 'eqy');
    return File(eqy).existsSync() ? eqy : null;
  }
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'eqy',
  ]);
  if (which.exitCode != 0) return null;
  final first = (which.stdout as String).split('\n').first.trim();
  return first.isEmpty ? null : first;
}();

/// The real eqy, or null after skipping (or failing under
/// FORMAL_LIVE_REQUIRED=1).
String? _eqyOrSkip() {
  final eqy = _eqy;
  if (eqy != null) return eqy;
  const reason = 'eqy not found; set OSS_CAD_SUITE or put it on PATH';
  if (_required) fail('FORMAL_LIVE_REQUIRED=1 and $reason');
  markTestSkipped(reason);
  return null;
}

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('eqy_driver_live_'));
  tearDown(() => root.deleteSync(recursive: true));

  String copyCorpus() {
    final project = Directory(p.join(root.path, 'project'))..createSync();
    for (final f in Directory(eqyCorpus).listSync().whereType<File>()) {
      if (f.path.endsWith('.eqy') || f.path.endsWith('.v')) {
        f.copySync(p.join(project.path, p.basename(f.path)));
      }
    }
    return project.path;
  }

  final expected =
      readJsonObject('$kFormalFixtureRoot/eqy/eqy.expected.json')['runs']!
          as Map<String, Object?>;

  for (final run in kFormalEqyRuns) {
    test(
      '$run: the row and every partition through EqyDriver match the '
      'expectation',
      () async {
        final eqy = _eqyOrSkip();
        if (eqy == null) return;
        final project = copyCorpus();
        final work = Directory(p.join(root.path, 'work'))..createSync();
        final finished =
            (await EqyDriver()
                    .execute(
                      ExecuteRequest(
                        test: TestSpec(
                          id: 'eqy/$run',
                          name: run,
                          suiteName: 'eqy',
                          simulatorId: EqyDriver.kId,
                          top: run,
                          formal: FormalConfig(
                            eqyFile: p.join(project, '$run.eqy'),
                            eqyBinary: eqy,
                          ),
                        ),
                        workingDirectory: work.path,
                        compileResult: null,
                        binaryConfig: const SimulatorBinaryConfig(
                          simulatorId: EqyDriver.kId,
                        ),
                      ),
                    )
                    .toList())
                .whereType<TestExecutionFinished>()
                .single;
        final problems = <String>[];
        final metrics = finished.metrics;
        final spec = expected[run]! as Map<String, Object?>;
        if (metrics['formal.verdict'] != spec['verdict']) {
          problems.add(
            'verdict ${metrics['formal.verdict']}, expected '
            '${spec['verdict']}',
          );
        }
        if (metrics['formal.verdict_disagreement'] == '1') {
          problems.add('the log and the work directory disagreed');
        }
        final want = kEqyPartitionExpectations[run]!;
        final seen = <String>{};
        final workDir = p.join(work.path, run);
        for (var n = 0; metrics.containsKey('formal.property.$n.kind'); n++) {
          final name = metrics['formal.property.$n.label']!;
          seen.add(name);
          final status = metrics['formal.property.$n.status'];
          final trace = metrics['formal.property.$n.trace'];
          final equivalent = want[name];
          if (equivalent == null) {
            problems.add('unexpected partition $name');
          } else if (equivalent && status != 'proved') {
            problems.add('$name: $status, expected proved');
          } else if (!equivalent && status != 'counterexample') {
            problems.add('$name: $status, expected counterexample');
          } else if (!equivalent &&
              (trace == null ||
                  !File(p.join(workDir, trace)).existsSync() ||
                  p.basename(trace) != 'trace.vcd')) {
            problems.add('$name: no base-case counterexample ($trace)');
          } else if (equivalent && trace != null) {
            problems.add('$name: a trace on a proved partition');
          }
        }
        if (!seen.containsAll(want.keys) || seen.length != want.length) {
          problems.add('partitions $seen, expected ${want.keys}');
        }
        if (spec['verdict'] == 'PASS' && finished.waveformPath != null) {
          problems.add('a PASS row carries a counterexample');
        }
        if (spec['verdict'] == 'FAIL' && finished.waveformPath == null) {
          problems.add('a FAIL row carries no counterexample');
        }
        expect(problems, isEmpty, reason: problems.join('\n'));
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }

  test(
    'import-eqy, load and run: the round trip a user takes',
    () async {
      final eqy = _eqyOrSkip();
      if (eqy == null) return;
      final project = copyCorpus();
      final out = p.join(project, 'simcrux.yaml');
      await FormalImportCli(stdoutWriter: (_) {}, stderrWriter: (_) {}).run(
        FormalImportKind.eqy,
        [p.join(project, 'alu_fail2.eqy'), '--out', out, '--eqy-binary', eqy],
      );
      final config = await ConfigLoader(
        allowProjectDefinedTooling: true,
      ).load(out);
      final runRoot = Directory(p.join(root.path, 'runs'))..createSync();
      final scheduler = LocalJobScheduler(
        driverRegistry: SimulatorDriverRegistry({EqyDriver.kId: EqyDriver()}),
        config: RegressionConfig(
          projectFilePath: config.projectFilePath,
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        ),
        runRoot: runRoot.path,
        retainSuccessfulWorkDirs: true,
      );
      final events = await scheduler
          .submit(
            RegressionRequest(
              runId: 'r',
              tests: [for (final s in config.suites) ...s.tests],
            ),
          )
          .toList();
      final result = events.whereType<TestFinished>().single.result;
      expect(result.metrics['formal.verdict'], 'FAIL');
      expect(result.metrics['formal.properties_failed'], '2');
      expect(result.waveformPath, isNotNull);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
