// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/simulator/dart_test_metrics.dart';
import 'package:simcrux/services/simulator/dart_test_report.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';

/// [SimulatorDriver] for a Dart project's tests: ROHD testbenches and ROHD-VF
/// environments (ROHD 0.7 or later, source tracing), or any `package:test`
/// suite.
///
/// It is shaped like [CocotbDriver]: one SimCrux test is one run of the
/// framework's own runner, and the per-case results come from the runner's
/// machine-readable report, not from scraping its console. The runner here is
/// `dart test --file-reporter json:<path>`, which writes the report to a file
/// and leaves the console output alone, so the run's log is kept as the user
/// would have seen it.
///
/// **Configuration.**
///
/// ```yaml
/// tests:
///   - name: adder_testbench
///     simulator: dart_test
///     top: rohd_adder              # a label; nothing is elaborated from it
///     sources: [test/adder_test.dart]
/// ```
///
/// - `sources` lists the Dart test files to run, resolved against the project
///   file. With none, the package's whole `test/` directory runs.
/// - The package is the nearest directory at or above the first Dart source
///   that holds a `pubspec.yaml`. `parameters.package_dir` (an absolute path)
///   names it explicitly, and is required when there are no sources.
/// - A source ending in `.json` or `.jsonl` is **imported** instead of run: the
///   file is read as a `dart test` JSON report, for a run CI already made or
///   one produced with `dart test --reporter json > results.jsonl`.
///
/// **Verdict.** The report decides: clean when no case failed or errored. A
/// ROHD-VF `Test failed.` arrives from the runner as an error and is reported
/// as a failure (see [parseDartTestReport]). When no report was written (the
/// runner was missing, or died before writing) the exit code decides.
///
/// Metrics are written by [dartTestMetrics]; the inspector lists the cases and
/// Go to Source opens the Dart file at the failing line.
class DartTestDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [DartTestDriver].
  DartTestDriver({
    super.launcher,
    super.reaper,
    this.dartBinary = 'dart',
    super.killGrace,
  });

  /// The driver id, as written in `simulator:`.
  static const String kId = 'dart_test';

  /// Metric key: a runner exit code of **0** withheld from the result because
  /// the report said a case failed.
  static const String kMetricProcessExitCode = 'dart.process_exit_code';

  /// `dart` executable name; resolved through [SimulatorBinaryConfig].
  final String dartBinary;

  @override
  String get id => kId;

  @override
  String get displayName => 'Dart test (ROHD)';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: true,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) =>
      detectVersionOf(resolveBinary(config, dartBinary));

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: null,
        stdout: '',
        stderr: '',
      );

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final sources = request.test.sources;
    final imported = sources.where(_isReportFile).firstOrNull;
    final dartSources = sources.where((s) => s.endsWith('.dart')).toList();

    final packageDir = _packageDir(
      request.test.parameters['package_dir'],
      imported ?? dartSources.firstOrNull,
    );

    if (imported != null) {
      await _import(
        request,
        controller,
        reportPath: imported,
        packageDir: packageDir ?? p.dirname(imported),
        startedAt: startedAt,
      );
      return;
    }

    if (packageDir == null) {
      controller.add(
        TestExecutionFinished(
          status: TestStatus.unknown,
          exitCode: null,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          failureMessage:
              'dart_test needs a package: list a Dart test file under '
              '`sources`, or set `parameters.package_dir` to the directory '
              'that holds pubspec.yaml.',
        ),
      );
      await controller.close();
      return;
    }

    final reportPath = p.join(request.workingDirectory, 'dart-test.json');
    final args = <String>[
      'test',
      '--reporter',
      'expanded',
      '--file-reporter',
      'json:$reportPath',
      for (final s in dartSources)
        if (p.isWithin(packageDir, s)) p.relative(s, from: packageDir) else s,
    ];
    final dart = resolveBinary(request.binaryConfig, dartBinary);

    await runProcessStreaming(
      request: request,
      executable: dart,
      args: args,
      startedAt: startedAt,
      controller: controller,
      workingDirectoryOverride: packageDir,
      unavailableBinaryLabel: dart,
      unavailableMessage:
          '$dart not available (${request.binaryConfig.source})',
      buildFinished: (exitCode, process) async {
        final report = await _readReport(reportPath);
        final metrics = report == null
            ? <String, String>{}
            : _metrics(report, packageDir);
        final TestStatus status;
        if (report != null && report.cases.isNotEmpty) {
          status = _statusOf(report);
        } else {
          status = exitCode == 0 ? TestStatus.pass : TestStatus.fail;
        }
        // Never hand the scheduler an exit code that contradicts the report: the
        // default `exit_code` detector would read 0 as a pass.
        var reported = exitCode;
        if (status == TestStatus.fail && exitCode == 0) {
          metrics[kMetricProcessExitCode] = '0';
          reported = null;
        }
        return TestExecutionFinished(
          status: status,
          exitCode: reported,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          killSignal: process.killSignal,
          failureMessage: report == null ? null : _failureMessage(report),
          metrics: metrics.isEmpty ? null : metrics,
        );
      },
    );
  }

  Future<void> _import(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller, {
    required String reportPath,
    required String packageDir,
    required DateTime startedAt,
  }) async {
    final report = await _readReport(reportPath);
    if (report == null) {
      controller.add(
        TestExecutionFinished(
          status: TestStatus.unknown,
          exitCode: null,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          failureMessage:
              '$reportPath is not a `dart test` JSON report '
              '(expected the output of `dart test --reporter json`).',
        ),
      );
      await controller.close();
      return;
    }
    // The imported run's console, replayed, so the log is kept like a live
    // run's is.
    for (final c in report.cases) {
      for (final log in c.logs) {
        controller.add(
          TestLogLine(
            line: log.structured
                ? '[${log.severity}] @ ${log.simTime} | ${log.logger}: '
                      '${log.message}'
                : log.message,
            fromStderr: false,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      }
      final message = c.message;
      if (c.outcome == DartTestOutcome.fail ||
          c.outcome == DartTestOutcome.error) {
        controller.add(
          TestLogLine(
            line: '${c.name}: ${message ?? 'failed'}',
            fromStderr: true,
            timestamp: DateTime.now().toUtc(),
          ),
        );
      }
    }
    controller.add(
      TestExecutionFinished(
        status: report.cases.isEmpty ? TestStatus.unknown : _statusOf(report),
        exitCode: null,
        startedAt: startedAt,
        finishedAt: DateTime.now().toUtc(),
        failureMessage: _failureMessage(report),
        metrics: _metrics(report, packageDir),
      ),
    );
    await controller.close();
  }

  Map<String, String> _metrics(DartTestReport report, String packageDir) {
    final name = _packageName(packageDir);
    return dartTestMetrics(
      report,
      resolve: (uri) => resolveDartSourcePath(
        uri,
        packageRoot: packageDir,
        packageName: name,
      ),
    );
  }

  TestStatus _statusOf(DartTestReport report) {
    if (!report.isClean || !report.complete) return TestStatus.fail;
    if (report.cases.every((c) => c.outcome == DartTestOutcome.skip)) {
      return TestStatus.skipped;
    }
    return TestStatus.pass;
  }

  String? _failureMessage(DartTestReport report) {
    for (final c in report.cases) {
      if (c.outcome != DartTestOutcome.fail &&
          c.outcome != DartTestOutcome.error) {
        continue;
      }
      final first = (c.message ?? '')
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty, orElse: () => 'failed');
      final more = report.failing - 1;
      return more > 0
          ? '${c.name}: $first (and $more more)'
          : '${c.name}: $first';
    }
    return null;
  }

  static bool _isReportFile(String path) =>
      path.endsWith('.json') || path.endsWith('.jsonl');

  /// The package directory: [explicit] when absolute, else the nearest
  /// ancestor of [anchor] holding a `pubspec.yaml`.
  String? _packageDir(String? explicit, String? anchor) {
    if (explicit != null && explicit.isNotEmpty && p.isAbsolute(explicit)) {
      return explicit;
    }
    if (anchor == null) return null;
    var dir = p.dirname(p.absolute(anchor));
    while (true) {
      if (File(p.join(dir, 'pubspec.yaml')).existsSync()) return dir;
      final parent = p.dirname(dir);
      if (parent == dir) return null;
      dir = parent;
    }
  }

  String? _packageName(String packageDir) {
    try {
      final text = File(p.join(packageDir, 'pubspec.yaml')).readAsStringSync();
      return RegExp(
        r'^name:\s*([A-Za-z0-9_]+)',
        multiLine: true,
      ).firstMatch(text)?.group(1);
    } on Object {
      return null;
    }
  }

  Future<DartTestReport?> _readReport(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return parseDartTestReport(await file.readAsString());
    } on Object {
      // An unreadable report falls back to the exit code; it never fails a run
      // the runner may have completed.
      return null;
    }
  }
}
