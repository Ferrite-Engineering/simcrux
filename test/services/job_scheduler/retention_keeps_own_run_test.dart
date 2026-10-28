// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/ci_retention.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// A `--ci` run with more failures than the retention cap used to prune its
// own counterexample folders at the end of the run, while its NDJSON, JUnit
// and JSON results still gave a `waveform_path` into them. The run that
// just finished is now protected: it counts toward the cap, and only
// earlier runs' folders make room.

/// Fails every test, writing a counterexample into the work dir first.
class _FailingDriver implements SimulatorDriver {
  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: true,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final started = DateTime.now().toUtc();
    final dumpPath = p.join(request.workingDirectory, 'trace.vcd');
    File(dumpPath).writeAsStringSync('VCD-BODY');
    yield TestExecutionFinished(
      status: TestStatus.fail,
      exitCode: 1,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
      waveformPath: dumpPath,
    );
  }

  @override
  void cancel(String testId) {}
}

RegressionConfig _config() => RegressionConfig(
  projectFilePath: '/fake/simcrux.yaml',
  schemaVersion: '1',
  suites: const [],
  simulatorBinaries: const {},
);

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'fake',
  top: 'tb',
  timeout: const Duration(seconds: 30),
);

void main() {
  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_own_run_');
  });
  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  /// An earlier run's failure folder, older than anything the run makes.
  void earlierFailure(String runId, String testId) {
    final dir = Directory(p.join(runRoot.path, 'runs', runId, testId))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'trace.vcd'))
      ..writeAsStringSync('OLD')
      ..setLastModifiedSync(DateTime.now().subtract(const Duration(days: 1)));
  }

  test('a run with more failures than the cap keeps every one of its '
      'counterexamples, and only earlier runs are pruned', () async {
    earlierFailure('old', 'a');
    earlierFailure('old', 'b');
    final removedLog = <List<String>>[];
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({'fake': _FailingDriver()}),
      config: _config(),
      runRoot: runRoot.path,
      dumpRetentionPolicy: DumpRetentionPolicy(
        keepLastNFailures: 2,
        onPruned: removedLog.add,
      ),
    );
    final events = await scheduler
        .submit(
          RegressionRequest(
            runId: 'now',
            tests: <TestSpec>[for (var i = 0; i < 3; i++) _spec('s/t$i')],
          ),
        )
        .toList();
    final results = events.whereType<TestFinished>().map((e) => e.result);
    expect(results, hasLength(3));
    for (final result in results) {
      expect(result.waveformPath, isNotNull);
      expect(
        File(result.waveformPath!).existsSync(),
        isTrue,
        reason: '${result.testId} points at a counterexample that was pruned',
      );
    }
    expect(
      Directory(p.join(runRoot.path, 'runs', 'old')).existsSync(),
      isFalse,
    );
    expect(removedLog, hasLength(1));
    expect(removedLog.single, hasLength(2));
    expect(
      removedLog.single.map(p.basename).toSet(),
      <String>{'a', 'b'},
    );
  });

  group('pruneRetainedDumpsAcrossRuns protectRunIds', () {
    late Directory runsRoot;
    setUp(() => runsRoot = runsRootFor(runRoot.path));

    void dump(String runId, String testId, int ageSeconds) {
      final dir = Directory(p.join(runsRoot.path, runId, testId))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'dump.vcd'))
        ..writeAsStringSync('X')
        ..setLastModifiedSync(
          DateTime.now().subtract(Duration(seconds: ageSeconds)),
        );
    }

    test('a protected run counts toward the cap and is never deleted', () {
      // The protected run is the OLDEST here, which is what a long formal
      // run looks like: its first failures were written long before the
      // newest folders of a shorter run that finished meanwhile.
      for (var t = 0; t < 4; t++) {
        dump('current', 't$t', 1000 + t);
      }
      for (var t = 0; t < 3; t++) {
        dump('earlier', 't$t', t);
      }
      final removed = <String>[];
      final deleted = pruneRetainedDumpsAcrossRuns(
        runsRoot,
        DumpRetentionPolicy(keepLastNFailures: 5, onPruned: removed.addAll),
        protectRunIds: const {'current'},
      );
      expect(deleted, 2);
      expect(removed, hasLength(2));
      expect(
        Directory(p.join(runsRoot.path, 'current')).listSync(),
        hasLength(4),
      );
      // The newest earlier folder survives in the one remaining slot.
      expect(
        Directory(
          p.join(runsRoot.path, 'earlier'),
        ).listSync().map((e) => p.basename(e.path)),
        <String>['t0'],
      );
    });

    test('no callback when nothing was removed', () {
      dump('current', 't0', 0);
      var called = false;
      pruneRetainedDumpsAcrossRuns(
        runsRoot,
        DumpRetentionPolicy(
          keepLastNFailures: 5,
          onPruned: (_) => called = true,
        ),
        protectRunIds: const {'current'},
      );
      expect(called, isFalse);
    });

    test('the async form protects and reports the same way', () async {
      for (var t = 0; t < 3; t++) {
        dump('current', 't$t', 100 + t);
      }
      dump('earlier', 't0', 0);
      final removed = <String>[];
      final deleted = await pruneRetainedDumpsAcrossRunsAsync(
        runsRoot,
        DumpRetentionPolicy(keepLastNFailures: 1, onPruned: removed.addAll),
        protectRunIds: const {'current'},
      );
      expect(deleted, 1);
      expect(removed.single, p.join(runsRoot.absolute.path, 'earlier', 't0'));
      expect(
        Directory(p.join(runsRoot.path, 'current')).listSync(),
        hasLength(3),
      );
    });
  });

  group('--keep-failures', () {
    test('parses a non-negative count and refuses anything else', () {
      final parser = CliArgParser();
      expect(
        parser.parse(['p.yaml', '--ci', '--keep-failures', '200']).keepFailures,
        200,
      );
      expect(parser.parse(['p.yaml', '--ci']).keepFailures, isNull);
      expect(
        () => parser.parse(['p.yaml', '--ci', '--keep-failures', '-1']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parser.parse(['p.yaml', '--ci', '--keep-failures', 'all']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('the CI policy keeps the default byte ceiling and lists every '
        'removal', () {
      final lines = <String>[];
      final policy = ciDumpRetentionPolicy(keepFailures: 7, log: lines.add);
      expect(policy.keepLastNFailures, 7);
      expect(
        policy.maxTotalBytes,
        DumpRetentionPolicy.defaultPolicy.maxTotalBytes,
      );
      policy.onPruned!(['/tmp/runs/a/x', '/tmp/runs/b/y']);
      expect(lines, hasLength(3));
      expect(lines.first, contains('removed 2 failure folders'));
      expect(lines.first, contains('newest 7'));
      expect(lines.skip(1), [
        'simcrux:   /tmp/runs/a/x',
        'simcrux:   /tmp/runs/b/y',
      ]);
    });

    test('without the flag the CI policy keeps 50', () {
      expect(
        ciDumpRetentionPolicy(
          keepFailures: null,
          log: (_) {},
        ).keepLastNFailures,
        50,
      );
    });
  });
}
