// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/output_config.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart'
    show FailOnRegressionDecision, FailOnRegressionPolicy;
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

class _InMemorySink implements IOSink {
  final StringBuffer buffer = StringBuffer();
  @override
  Encoding encoding = const Utf8Codec();
  @override
  void add(List<int> data) => buffer.write(String.fromCharCodes(data));
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(add);
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) => buffer.write(object);
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {
    buffer.writeAll(objects, separator);
  }

  @override
  void writeCharCode(int charCode) =>
      buffer.write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => buffer.writeln(object);
}

CiStreamingWriterFactory _testStreamingFactory() {
  return ({
    required resultsPath,
    required summaryPath,
    required containWithin,
  }) => StreamingResultsWriter(
    resultsPath: resultsPath,
    summaryPath: summaryPath,
    containWithin: containWithin,
    openSink: (_) async => _InMemorySink(),
    writeSummary: (_, _) async {},
  );
}

class _FakeScheduler implements JobScheduler {
  _FakeScheduler(
    this._statusFor, {
    this.drop = const <String>{},
    this.cancelled = false,
  });
  final TestStatus Function(TestSpec) _statusFor;

  /// Test ids this scheduler starts but never reports — the shape of a
  /// backend that loses a job and still finishes the run.
  final Set<String> drop;

  /// What the closing [RegressionFinished] says.
  final bool cancelled;

  @override
  Map<String, ResourceLock> get heldLocks => const {};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: true,
  );

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) {
    return Stream<RegressionEvent>.multi((controller) async {
      final started = DateTime.now().toUtc();
      for (final spec in request.tests) {
        controller.add(TestStarted(runId: request.runId, testId: spec.id));
        if (drop.contains(spec.id)) continue;
        final result = TestResult(
          testId: spec.id,
          runId: request.runId,
          status: _statusFor(spec),
          startedAt: started,
          finishedAt: started.add(const Duration(milliseconds: 5)),
          exitCode: _statusFor(spec) == TestStatus.pass ? 0 : 1,
        );
        controller.add(TestFinished(runId: request.runId, result: result));
      }
      controller.add(
        RegressionFinished(runId: request.runId, cancelled: cancelled),
      );
      await controller.close();
    });
  }

  @override
  Future<void> cancel(String runId) async {}
}

/// Scheduler whose event stream errors mid-run — stands in for a
/// driver crash or an unhandled scheduler exception.
class _ErroringScheduler implements JobScheduler {
  @override
  Map<String, ResourceLock> get heldLocks => const {};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: false,
  );

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) {
    return Stream<RegressionEvent>.multi((controller) async {
      controller.addError(StateError('driver crashed mid-run'));
      await controller.close();
    });
  }

  @override
  Future<void> cancel(String runId) async {}
}

TestSpec _spec(String suiteName, String name, {String simulatorId = 'icarus'}) {
  return TestSpec(
    id: '$suiteName/$name',
    name: name,
    suiteName: suiteName,
    simulatorId: simulatorId,
    top: name,
    sources: const <String>[],
  );
}

RegressionConfig _config(List<TestSpec> tests) {
  return RegressionConfig(
    projectFilePath: '/p/simcrux.yaml',
    schemaVersion: '1',
    suites: <Suite>[
      Suite(
        name: 'unit',
        tests: tests,
      ),
    ],
    simulatorBinaries: const {},
    defaultPassFail: const ExitCodePassFailConfig(),
  );
}

void main() {
  group('CiRunner', () {
    test(
      'completes the run, writes exports, and reports exit code 0 on pass',
      () async {
        final writes = <String, String>{};
        final stdoutLines = <String>[];
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (path, contents) async => writes[path] = contents,
          stdoutWriter: stdoutLines.add,
          streamingWriterFactory: _testStreamingFactory(),
        );
        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            exportTargets: [
              CliExportTarget(formatId: 'junit', outputPath: '/o/report.xml'),
              CliExportTarget(formatId: 'json', outputPath: '/o/r.json'),
            ],
          ),
          config: _config([
            _spec('unit', 'one'),
            _spec('unit', 'two'),
          ]),
        );
        expect(outcome.exitCode, 0);
        expect(outcome.totalsByStatus[TestStatus.pass], 2);
        expect(writes.keys.toSet(), equals({'/o/report.xml', '/o/r.json'}));
        final junit = writes['/o/report.xml'];
        final json = writes['/o/r.json'];
        expect(junit, contains('<testsuites'));
        expect(json, contains('"status": "pass"'));
        expect(
          stdoutLines,
          contains(
            allOf(contains('2 tests'), contains('2 passed')),
          ),
        );
      },
    );

    test(
      'unknown results raise the exit code and appear in the summary',
      () async {
        // A scheduler-level error (no driver registered for the
        // simulatorId, or an exception escaping the per-test path)
        // surfaces as TestStatus.unknown. Counting only fail+timeout
        // exited 0 on a run that never determined whether anything
        // passed — a green CI build over a broken regression.
        final stdoutLines = <String>[];
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler(
            (s) => s.name == 'crashed' ? TestStatus.unknown : TestStatus.pass,
          ),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: stdoutLines.add,
          streamingWriterFactory: _testStreamingFactory(),
        );

        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
          ),
          config: _config([
            _spec('unit', 'ok'),
            _spec('unit', 'crashed'),
          ]),
        );

        expect(outcome.exitCode, 1);
        expect(outcome.totalsByStatus[TestStatus.unknown], 1);
        expect(outcome.failureCount, 1);
        expect(
          stdoutLines,
          contains(
            allOf(contains('2 tests'), contains('1 unknown')),
          ),
        );
      },
    );

    test('the summary components sum to the printed total', () async {
      final stdoutLines = <String>[];
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler(
          (s) => switch (s.name) {
            'a' => TestStatus.pass,
            'b' => TestStatus.vacuous,
            'c' => TestStatus.cover,
            'd' => TestStatus.cancelled,
            _ => TestStatus.unknown,
          },
        ),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: stdoutLines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );

      await runner.run(
        args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
        config: _config([
          _spec('unit', 'a'),
          _spec('unit', 'b'),
          _spec('unit', 'c'),
          _spec('unit', 'd'),
          _spec('unit', 'e'),
        ]),
      );

      final summary = stdoutLines.firstWhere((l) => l.contains('tests'));
      final counts = RegExp(
        r'(\d+) (?!tests)',
      ).allMatches(summary).map((m) => int.parse(m.group(1)!)).toList();
      expect(
        counts.fold<int>(0, (a, b) => a + b),
        5,
        reason: 'printed components must account for every result: $summary',
      );
      expect(summary, contains('1 vacuous'));
      expect(summary, contains('1 cover'));
      expect(summary, contains('1 cancelled'));
      expect(summary, contains('1 unknown'));
    });

    test('vacuous counts as a failure only under --fail-on-vacuous', () async {
      CiRunner build() => CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.vacuous),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: (_) {},
        streamingWriterFactory: _testStreamingFactory(),
      );
      final config = _config([_spec('unit', 'unexercised')]);

      final permissive = await build().run(
        args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
        config: config,
      );
      expect(
        permissive.exitCode,
        0,
        reason: 'default preserves vacuous-as-success-equivalent',
      );

      final strict = await build().run(
        args: const CliArgs(
          projectPaths: ['/p/simcrux.yaml'],
          ciMode: true,
          failOnVacuous: true,
        ),
        config: config,
      );
      expect(strict.exitCode, 1);
      expect(strict.countFailures(failOnVacuous: true), 1);
    });

    test(
      'a mid-run scheduler error aborts the streaming writer without a '
      'summary line',
      () async {
        // Crash path: the run errors before recordRunCompletion. The
        // NDJSON must still be flushed and closed so the partial file
        // is a readable prefix the recovery/reader path reports as
        // "did not complete cleanly" — not a leaked handle whose
        // buffered rows never reached disk.
        final sink = _InMemorySink();
        StreamingResultsWriter? created;
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _ErroringScheduler(),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          streamingWriterFactory:
              ({
                required resultsPath,
                required summaryPath,
                required containWithin,
              }) {
                return created = StreamingResultsWriter(
                  resultsPath: resultsPath,
                  summaryPath: summaryPath,
                  containWithin: containWithin,
                  openSink: (_) async => sink,
                  writeSummary: (_, _) async =>
                      fail('no summary may be written on the crash path'),
                );
              },
        );

        await expectLater(
          runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
            ),
            config: _config([_spec('unit', 'one')]),
          ),
          throwsA(isA<StateError>()),
        );

        expect(created, isNotNull);
        expect(
          created!.isClosed,
          isTrue,
          reason: 'abortWithoutSummary must have closed the writer',
        );
        final written = sink.buffer.toString();
        expect(written, contains('"type":"meta"'));
        expect(
          written,
          isNot(contains('"type":"summary"')),
          reason: 'an interrupted run must not claim a clean completion',
        );
      },
    );

    group('streaming output paths', () {
      // Where a `--ci` run's streaming files go, and the writer-side half of
      // the rule that keeps them inside the project. The loader's half is in
      // `config_loader_output_paths_test.dart`.
      final projectDir = p.dirname(p.normalize(p.absolute('/p/simcrux.yaml')));

      Future<({String results, String summary, String? containWithin})>
      captured({
        required CliArgs args,
        required RegressionConfig config,
      }) async {
        late ({String results, String summary, String? containWithin}) seen;
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          streamingWriterFactory:
              ({
                required resultsPath,
                required summaryPath,
                required containWithin,
              }) {
                seen = (
                  results: resultsPath,
                  summary: summaryPath,
                  containWithin: containWithin,
                );
                return _testStreamingFactory()(
                  resultsPath: resultsPath,
                  summaryPath: summaryPath,
                  containWithin: containWithin,
                );
              },
        );
        await runner.run(args: args, config: config);
        return seen;
      }

      test('a relative path resolves against the project directory, not '
          'the directory the run started in', () async {
        final seen = await captured(
          args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
          config: _config([_spec('unit', 'one')]).copyWith(
            output: const OutputConfig(
              streamingResultsPath: 'build/results.ndjson',
              streamingSummaryPath: 'build/results.summary.json',
            ),
          ),
        );
        expect(seen.results, p.join(projectDir, 'build', 'results.ndjson'));
        expect(
          seen.summary,
          p.join(projectDir, 'build', 'results.summary.json'),
        );
        expect(seen.containWithin, projectDir);
      });

      test('the defaults sit next to the project file', () async {
        final seen = await captured(
          args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
          config: _config([_spec('unit', 'one')]),
        );
        expect(seen.results, p.join(projectDir, 'results.ndjson'));
        expect(seen.summary, p.join(projectDir, 'results.summary.json'));
      });

      test('--allow-project-tooling lifts the writer check', () async {
        final seen = await captured(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            allowProjectTooling: true,
          ),
          config: _config([_spec('unit', 'one')]),
        );
        expect(seen.containWithin, isNull);
      });

      group('on the real disk', () {
        late Directory tmp;
        late String project;
        late File victim;

        setUp(() {
          tmp = Directory(
            Directory.systemTemp
                .createTempSync('simcrux_ci_output_')
                .resolveSymbolicLinksSync(),
          );
          project = p.join(tmp.path, 'project');
          Directory(project).createSync();
          victim = File(p.join(tmp.path, 'victim.txt'))
            ..writeAsStringSync('keep me');
        });

        tearDown(() {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        });

        // A config built in code, so the loader never saw it: only the
        // writer stands between the run and the file.
        RegressionConfig escaping() => RegressionConfig(
          projectFilePath: p.join(project, 'simcrux.yaml'),
          schemaVersion: '1',
          suites: <Suite>[
            Suite(name: 'unit', tests: [_spec('unit', 'one')]),
          ],
          simulatorBinaries: const {},
          defaultPassFail: const ExitCodePassFailConfig(),
          output: const OutputConfig(streamingResultsPath: '../victim.txt'),
        );

        CiRunner realWriterRunner() => CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          stderrWriter: (_) {},
        );

        test('a path that leads out fails the run and truncates nothing', () {
          expect(
            () => realWriterRunner().run(
              args: CliArgs(
                projectPaths: [p.join(project, 'simcrux.yaml')],
                ciMode: true,
              ),
              config: escaping(),
            ),
            throwsA(isA<ProjectOutputPathException>()),
          );
          expect(victim.readAsStringSync(), 'keep me');
        });

        test('with --allow-project-tooling the run writes there', () async {
          await realWriterRunner().run(
            args: CliArgs(
              projectPaths: [p.join(project, 'simcrux.yaml')],
              ciMode: true,
              allowProjectTooling: true,
            ),
            config: escaping(),
          );
          expect(victim.readAsStringSync(), contains('"type":"summary"'));
        });
      });
    });

    test('exit code is 1 when failures reach the threshold', () async {
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler(
          (s) => s.name == 'fail' ? TestStatus.fail : TestStatus.pass,
        ),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: (_) {},
        streamingWriterFactory: _testStreamingFactory(),
      );
      final outcome = await runner.run(
        args: const CliArgs(
          projectPaths: ['/p/simcrux.yaml'],
          ciMode: true,
        ),
        config: _config([_spec('unit', 'pass'), _spec('unit', 'fail')]),
      );
      expect(outcome.exitCode, 1);
      expect(outcome.failureCount, 1);
    });

    test(
      'exit code is 0 when failures < threshold (e.g. failThreshold=2 and 1 fail)',
      () async {
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler(
            (s) => s.name == 'fail' ? TestStatus.fail : TestStatus.pass,
          ),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          streamingWriterFactory: _testStreamingFactory(),
        );
        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            failThreshold: 2,
          ),
          config: _config([_spec('unit', 'pass'), _spec('unit', 'fail')]),
        );
        expect(outcome.exitCode, 0);
      },
    );

    group('a submitted test that never reports', () {
      // The totals count only what the scheduler reported, and the exit code
      // is computed from the totals. A cluster scheduler that lost jobs and
      // still ended its stream let `--ci` exit 0 with tests unrun.
      CiRunner build({
        required _FakeScheduler scheduler,
        required List<String> stdoutLines,
        required List<String> stderrLines,
      }) => CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => scheduler,
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: stdoutLines.add,
        stderrWriter: stderrLines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );

      test('fails the run with exit 2 and names the test on stderr', () async {
        final stdoutLines = <String>[];
        final stderrLines = <String>[];
        final outcome =
            await build(
              scheduler: _FakeScheduler(
                (_) => TestStatus.pass,
                drop: {'unit/two'},
              ),
              stdoutLines: stdoutLines,
              stderrLines: stderrLines,
            ).run(
              args: const CliArgs(
                projectPaths: ['/p/simcrux.yaml'],
                ciMode: true,
              ),
              config: _config([
                _spec('unit', 'one'),
                _spec('unit', 'two'),
                _spec('unit', 'three'),
              ]),
            );

        expect(
          outcome.exitCode,
          2,
          reason:
              'every reported test passed, but one of three never came back; '
              'exit 2 is "SimCrux could not do what was asked"',
        );
        expect(
          stderrLines.single,
          allOf(
            startsWith('error: 1 of 3 submitted tests reported no result'),
            contains('the scheduler finished without them'),
            endsWith('unit/two'),
          ),
        );
        expect(
          stdoutLines,
          contains(allOf(contains('2 tests'), contains('2 passed'))),
          reason: 'the summary still says how the reported tests did',
        );
      });

      test('outranks a threshold failure', () async {
        final outcome =
            await build(
              scheduler: _FakeScheduler(
                (_) => TestStatus.fail,
                drop: {'unit/two'},
              ),
              stdoutLines: <String>[],
              stderrLines: <String>[],
            ).run(
              args: const CliArgs(
                projectPaths: ['/p/simcrux.yaml'],
                ciMode: true,
              ),
              config: _config([_spec('unit', 'one'), _spec('unit', 'two')]),
            );
        expect(outcome.exitCode, 2);
      });

      test('a cancelled run says it was cancelled', () async {
        final stderrLines = <String>[];
        final outcome =
            await build(
              scheduler: _FakeScheduler(
                (_) => TestStatus.pass,
                drop: {'unit/two'},
                cancelled: true,
              ),
              stdoutLines: <String>[],
              stderrLines: stderrLines,
            ).run(
              args: const CliArgs(
                projectPaths: ['/p/simcrux.yaml'],
                ciMode: true,
              ),
              config: _config([_spec('unit', 'one'), _spec('unit', 'two')]),
            );
        expect(outcome.exitCode, 2);
        expect(
          stderrLines.single,
          contains('the run was cancelled before they finished'),
        );
      });

      test('a long list is cut off with a count', () async {
        final stderrLines = <String>[];
        final specs = [for (var i = 0; i < 13; i++) _spec('unit', 't$i')];
        await build(
          scheduler: _FakeScheduler(
            (_) => TestStatus.pass,
            drop: {for (final s in specs) s.id},
          ),
          stdoutLines: <String>[],
          stderrLines: stderrLines,
        ).run(
          args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
          config: _config(specs),
        );
        expect(
          stderrLines.single,
          allOf(
            contains('13 of 13'),
            contains('unit/t9'),
            isNot(contains('unit/t10')),
            endsWith('and 3 more'),
          ),
        );
      });

      test('a fully reported run writes nothing to stderr', () async {
        final stderrLines = <String>[];
        final outcome =
            await build(
              scheduler: _FakeScheduler((_) => TestStatus.pass),
              stdoutLines: <String>[],
              stderrLines: stderrLines,
            ).run(
              args: const CliArgs(
                projectPaths: ['/p/simcrux.yaml'],
                ciMode: true,
              ),
              config: _config([_spec('unit', 'one'), _spec('unit', 'two')]),
            );
        expect(outcome.exitCode, 0);
        expect(stderrLines, isEmpty);
      });
    });

    test('--json prints a compact totals summary on stdout', () async {
      final lines = <String>[];
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: lines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );
      await runner.run(
        args: const CliArgs(
          projectPaths: ['/p/simcrux.yaml'],
          ciMode: true,
          jsonOutput: true,
        ),
        config: _config([_spec('unit', 'a'), _spec('unit', 'b')]),
      );
      expect(lines.single, contains('"totals":{"pass":2}'));
    });

    group('exports', () {
      test('--export creates missing parent directories', () async {
        final tmp = Directory.systemTemp.createTempSync('simcrux_ci_export_');
        addTearDown(() => tmp.deleteSync(recursive: true));
        final report = '${tmp.path}/build/reports/junit.xml';
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
          exporterRegistry: const ExporterRegistry(),
          stdoutWriter: (_) {},
          stderrWriter: (_) {},
          streamingWriterFactory: _testStreamingFactory(),
        );
        final outcome = await runner.run(
          args: CliArgs(
            projectPaths: const ['/p/simcrux.yaml'],
            ciMode: true,
            exportTargets: [
              CliExportTarget(formatId: 'junit', outputPath: report),
            ],
          ),
          config: _config([_spec('unit', 'a')]),
        );
        expect(outcome.exitCode, 0);
        expect(File(report).readAsStringSync(), contains('<testsuites'));
      });

      test('a failed export keeps the summary, writes the other targets and '
          'exits 2', () async {
        final stdoutLines = <String>[];
        final stderrLines = <String>[];
        final writes = <String, String>{};
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler(
            (s) => s.name == 'bad' ? TestStatus.fail : TestStatus.pass,
          ),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (path, contents) async {
            if (path.startsWith('/read-only/')) {
              throw FileSystemException('Permission denied', path);
            }
            writes[path] = contents;
          },
          stdoutWriter: stdoutLines.add,
          stderrWriter: stderrLines.add,
          streamingWriterFactory: _testStreamingFactory(),
        );
        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            exportTargets: [
              CliExportTarget(
                formatId: 'junit',
                outputPath: '/read-only/report.xml',
              ),
              CliExportTarget(formatId: 'csv', outputPath: '/o/r.csv'),
            ],
          ),
          config: _config([_spec('unit', 'ok'), _spec('unit', 'bad')]),
        );
        expect(
          stdoutLines.first,
          allOf(contains('2 tests'), contains('1 failed')),
          reason: 'the verdict is printed before any export is attempted',
        );
        expect(writes.keys, ['/o/r.csv']);
        expect(stderrLines, [
          allOf(startsWith('error: '), contains('/read-only/report.xml')),
          'wrote csv → /o/r.csv',
        ]);
        expect(outcome.exitCode, 2);
      });
    });

    test('load advisories are printed as warnings on stderr', () async {
      final stderrLines = <String>[];
      final runner = CiRunner(
        configLoader: ConfigLoader(
          // Pinned, not defaulted: this tests post-beta behaviour on purpose.
          // ignore: avoid_redundant_argument_values
          betaPeriod: false,
          readFile: (_) async => '''
version: "1"
suites:
  unit:
    simulator: icarus
    tests:
      - name: sweep
        top: tb
        seeds: [1, 2, 3]
''',
        ),
        schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
        exporterRegistry: const ExporterRegistry(),
        stdoutWriter: (_) {},
        stderrWriter: stderrLines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );
      final outcome = await runner.run(
        args: const CliArgs(projectPaths: ['/p/simcrux.yaml'], ciMode: true),
      );
      expect(outcome.run.testIds, hasLength(1), reason: 'the sweep ran once');
      expect(stderrLines, hasLength(1));
      expect(stderrLines.single, startsWith('warning: '));
      // The loader names the project as it absolutised it: on the working
      // drive, on Windows.
      final projectFile = p.normalize(p.absolute('/p/simcrux.yaml'));
      expect(stderrLines.single, contains('$projectFile:'));
      expect(stderrLines.single, contains('requires SimCrux Pro'));
    });

    // `CliArgParser` refuses an unknown format at parse time; this is the
    // runner's backstop for a `CliArgs` built in code.
    test('an unknown export format fails the run with exit 2, on stderr, '
        'and the other targets are still written', () async {
      final stdoutLines = <String>[];
      final stderrLines = <String>[];
      final writes = <String, String>{};
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (path, contents) async => writes[path] = contents,
        stdoutWriter: stdoutLines.add,
        stderrWriter: stderrLines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );
      final outcome = await runner.run(
        args: const CliArgs(
          projectPaths: ['/p/simcrux.yaml'],
          ciMode: true,
          exportTargets: [
            CliExportTarget(formatId: 'unknown', outputPath: '/o/foo'),
            CliExportTarget(formatId: 'csv', outputPath: '/o/foo.csv'),
          ],
        ),
        config: _config([_spec('unit', 'a')]),
      );
      expect(writes.keys, ['/o/foo.csv']);
      expect(outcome.exitCode, 2);
      expect(
        stderrLines,
        anyElement(
          allOf(
            contains('unknown export format "unknown"'),
            contains('/o/foo was not written'),
          ),
        ),
      );
      expect(stdoutLines, hasLength(1), reason: 'stdout carries the verdict');
    });

    test('--json: stdout carries the JSON document and nothing else', () async {
      final stdoutLines = <String>[];
      final stderrLines = <String>[];
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FakeScheduler(
          (s) => s.name == 'bad' ? TestStatus.fail : TestStatus.pass,
        ),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: stdoutLines.add,
        stderrWriter: stderrLines.add,
        streamingWriterFactory: _testStreamingFactory(),
      );
      await runner.run(
        args: const CliArgs(
          projectPaths: ['/p/simcrux.yaml'],
          ciMode: true,
          jsonOutput: true,
          failOnRegression: true,
          exportTargets: [
            CliExportTarget(formatId: 'junit', outputPath: '/o/r.xml'),
            CliExportTarget(formatId: 'html', outputPath: '/o/r.html'),
          ],
        ),
        config: _config([_spec('unit', 'ok'), _spec('unit', 'bad')]),
      );
      expect(jsonDecode(stdoutLines.join('\n')), <String, Object?>{
        'totals': <String, Object?>{'pass': 1, 'fail': 1},
      });
      expect(stderrLines, contains('wrote junit → /o/r.xml'));
      expect(stderrLines, contains('wrote html → /o/r.html'));
    });

    group('--fail-on-regression', () {
      test('open-core default (NoopFailOnRegressionPolicy): exit 0 even with '
          '--fail-on-regression set', () async {
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          streamingWriterFactory: _testStreamingFactory(),
          // Defaults to NoopFailOnRegressionPolicy.
        );
        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            failOnRegression: true,
            baselineRunPath: '/dev/null/ignored.ndjson',
          ),
          config: _config([_spec('unit', 'a')]),
        );
        expect(outcome.exitCode, 0);
      });

      test(
        '--fail-on-regression without --baseline warns on stderr and exits 0',
        () async {
          final lines = <String>[];
          final stdoutLines = <String>[];
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: stdoutLines.add,
            stderrWriter: lines.add,
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: _RecordingPolicy(),
          );
          final outcome = await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
              failOnRegression: true,
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(outcome.exitCode, 0);
          expect(
            lines.any((l) => l.contains('--fail-on-regression set without')),
            isTrue,
          );
          expect(
            stdoutLines,
            isNot(anyElement(contains('--fail-on-regression'))),
            reason: 'stdout carries the verdict only',
          );
        },
      );

      test(
        'policy returning (failed:true, exitCode:1) lifts exit to 1',
        () async {
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: (_) {},
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: _ConstantPolicy(
              decision: const FailOnRegressionDecision(
                failed: true,
                exitCode: 1,
              ),
            ),
          );
          final outcome = await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
              failOnRegression: true,
              baselineRunPath: '/snapshots/baseline.ndjson',
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(outcome.exitCode, 1);
        },
      );

      test(
        'policy exit code wins when higher than failure-threshold exit code',
        () async {
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: (_) {},
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: _ConstantPolicy(
              decision: const FailOnRegressionDecision(
                failed: true,
                exitCode: 5,
              ),
            ),
          );
          final outcome = await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
              failOnRegression: true,
              baselineRunPath: '/snapshots/baseline.ndjson',
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(outcome.exitCode, 5);
        },
      );

      test('policy returning pass leaves exit code unchanged', () async {
        final runner = CiRunner(
          configLoader: ConfigLoader(),
          schedulerFactory: (_) => _FakeScheduler(
            (s) => s.name == 'fail' ? TestStatus.fail : TestStatus.pass,
          ),
          exporterRegistry: const ExporterRegistry(),
          fileWriter: (_, _) async {},
          stdoutWriter: (_) {},
          streamingWriterFactory: _testStreamingFactory(),
          failOnRegressionPolicy: _ConstantPolicy(
            decision: FailOnRegressionDecision.pass,
          ),
        );
        // Run has one failure → failure-threshold-driven exit = 1.
        final outcome = await runner.run(
          args: const CliArgs(
            projectPaths: ['/p/simcrux.yaml'],
            ciMode: true,
            failOnRegression: true,
            baselineRunPath: '/snapshots/baseline.ndjson',
          ),
          config: _config([_spec('unit', 'pass'), _spec('unit', 'fail')]),
        );
        expect(outcome.exitCode, 1);
      });

      test('the policy is handed the tier the run resolved', () async {
        // The regression engine is a paid capability and decides for itself
        // whether this run may use it, so the runner must pass on the tier it
        // was built with rather than let the policy guess.
        for (final tier in LicenseTier.values) {
          final recording = _RecordingPolicy();
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: (_) {},
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: recording,
            licenseTier: tier,
          );
          await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
              failOnRegression: true,
              baselineRunPath: '/snapshots/baseline.ndjson',
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(recording.tiers, [tier]);
        }
      });

      test(
        'a runner built without a tier hands the policy Open Core',
        () async {
          final recording = _RecordingPolicy();
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: (_) {},
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: recording,
          );
          await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
              failOnRegression: true,
              baselineRunPath: '/snapshots/baseline.ndjson',
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(recording.tiers, [LicenseTier.openCore]);
        },
      );

      test(
        'policy is not consulted when --fail-on-regression is false',
        () async {
          final recording = _RecordingPolicy();
          final runner = CiRunner(
            configLoader: ConfigLoader(),
            schedulerFactory: (_) => _FakeScheduler((_) => TestStatus.pass),
            exporterRegistry: const ExporterRegistry(),
            fileWriter: (_, _) async {},
            stdoutWriter: (_) {},
            streamingWriterFactory: _testStreamingFactory(),
            failOnRegressionPolicy: recording,
          );
          await runner.run(
            args: const CliArgs(
              projectPaths: ['/p/simcrux.yaml'],
              ciMode: true,
            ),
            config: _config([_spec('unit', 'a')]),
          );
          expect(recording.callCount, 0);
        },
      );
    });
  });
}

/// Returns a constant [FailOnRegressionDecision].
class _ConstantPolicy implements FailOnRegressionPolicy {
  _ConstantPolicy({required this.decision});
  final FailOnRegressionDecision decision;
  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    return decision;
  }
}

/// Records every invocation so tests can assert the policy was (or
/// wasn't) consulted.
class _RecordingPolicy implements FailOnRegressionPolicy {
  int callCount = 0;

  /// The tier each call was handed, in call order.
  final List<LicenseTier> tiers = <LicenseTier>[];

  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    callCount++;
    tiers.add(licenseTier);
    return FailOnRegressionDecision.pass;
  }
}
