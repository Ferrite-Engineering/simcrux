// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/export/result_exporter.dart';
import 'package:simcrux/services/pass_fail_detector/pass_fail_detector_registry.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';
import 'package:simcrux/services/telemetry/simulator_telemetry_token.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// Outcome of [CiRunner.run]. Carries the resolved completed
/// [TestRun], the rendered dashboard rows, and a recommended process
/// exit code computed from `--fail-threshold`.
class CiRunResult {
  /// Creates a [CiRunResult].
  CiRunResult({
    required this.run,
    required List<DashboardRow> rows,
    required this.exitCode,
    required Map<TestStatus, int> totalsByStatus,
  }) : rows = List<DashboardRow>.unmodifiable(rows),
       totalsByStatus = Map<TestStatus, int>.unmodifiable(totalsByStatus);

  /// Completed [TestRun].
  final TestRun run;

  /// Rendered dashboard rows.
  final List<DashboardRow> rows;

  /// Recommended process exit code (0 = passed under threshold).
  final int exitCode;

  /// Counts by status across the run.
  final Map<TestStatus, int> totalsByStatus;

  /// Convenience: number of tests counted against the
  /// `--fail-threshold` gate under the default (`--fail-on-vacuous`
  /// off) policy — `fail`, `timeout`, and `unknown`.
  int get failureCount => countFailures(failOnVacuous: false);

  /// Number of tests counted as failures for the `--fail-threshold`
  /// gate.
  ///
  /// `unknown` is always included: it is what the scheduler reports
  /// when no driver was registered for a test's `simulatorId` or when
  /// an exception escaped the per-test path
  /// (`LocalJobScheduler._executeAttempt`). A run that could not
  /// determine whether its tests passed has not passed, and silently
  /// exiting zero on it is the CI-honesty defect this closes.
  ///
  /// `vacuous` is included only when [failOnVacuous] is set — see
  /// [CliArgs.failOnVacuous] for why it is opt-in.
  int countFailures({required bool failOnVacuous}) =>
      failuresIn(totalsByStatus, failOnVacuous: failOnVacuous);

  /// The `--fail-threshold` failure tally over a raw status-count map:
  /// `fail` + `timeout` + `unknown`, plus `vacuous` when [failOnVacuous].
  /// The single definition of the count so the pre-construction exit-code
  /// computation in [CiRunner.run] and this result object cannot drift.
  static int failuresIn(
    Map<TestStatus, int> totals, {
    required bool failOnVacuous,
  }) =>
      (totals[TestStatus.fail] ?? 0) +
      (totals[TestStatus.timeout] ?? 0) +
      (totals[TestStatus.unknown] ?? 0) +
      (failOnVacuous ? (totals[TestStatus.vacuous] ?? 0) : 0);
}

/// Writes rendered export bytes to a file. Injectable so tests can
/// capture into memory without touching the disk.
typedef CiFileWriter = Future<void> Function(String path, String contents);

/// Writes one line of summary output. Injectable so tests can capture
/// stdout into a buffer.
typedef CiStdoutWriter = void Function(String line);

/// Builds the [StreamingResultsWriter] for a given run. Injectable so
/// tests can swap in an in-memory implementation that doesn't touch
/// the filesystem.
///
/// `containWithin` is the directory both paths must stay inside, or null
/// when project tooling is allowed and they may be written anywhere; see
/// [StreamingResultsWriter.containWithin].
typedef CiStreamingWriterFactory =
    StreamingResultsWriter Function({
      required String resultsPath,
      required String summaryPath,
      required String? containWithin,
    });

/// Thin orchestrator that drives the existing config loader + job
/// scheduler from a non-interactive CLI invocation. Designed to be
/// callable from the bootstrap without spinning up the Flutter widget
/// tree.
class CiRunner {
  /// Creates a [CiRunner]. All collaborators are injectable so tests
  /// can wire fake implementations.
  CiRunner({
    required this.configLoader,
    required this.schedulerFactory,
    required this.exporterRegistry,
    CiFileWriter? fileWriter,
    CiStdoutWriter? stdoutWriter,
    CiStdoutWriter? stderrWriter,
    CiStreamingWriterFactory? streamingWriterFactory,
    FailOnRegressionPolicy? failOnRegressionPolicy,
    this.licenseTier = LicenseTier.openCore,
    this.telemetry = const NoopTelemetryService(),
  }) : fileWriter = fileWriter ?? _defaultWriter,
       stdoutWriter = stdoutWriter ?? _defaultStdout,
       stderrWriter = stderrWriter ?? _defaultStderr,
       streamingWriterFactory =
           streamingWriterFactory ?? _defaultStreamingWriterFactory,
       failOnRegressionPolicy =
           failOnRegressionPolicy ?? const NoopFailOnRegressionPolicy();

  /// Where this run's counters go.
  ///
  /// Defaults to [NoopTelemetryService] so a `CiRunner` constructed without
  /// one — every test in this repository, and any future embedder — records
  /// nothing rather than reaching for a pipeline it was not given. `bootstrap`
  /// supplies the real one through [resolveHeadlessTelemetry], which is the
  /// single place the `--ci` consent rule is decided.
  final TelemetryService telemetry;

  /// Used to read `simcrux.yaml` from disk.
  final ConfigLoader configLoader;

  /// Builds a [JobScheduler] for a freshly-loaded [RegressionConfig].
  final JobScheduler Function(RegressionConfig) schedulerFactory;

  /// Used to render the configured export formats.
  final ExporterRegistry exporterRegistry;

  /// Writes export bytes to disk.
  final CiFileWriter fileWriter;

  /// Writes the run's verdict to stdout, and nothing else: the one-line
  /// summary, or under `--json` the single JSON document.
  ///
  /// Nothing else, because `--json` stdout is a machine contract:
  /// `simcrux --ci --json … | jq .totals` must parse whatever other flags
  /// are on the line. Progress and diagnostics go to [stderrWriter].
  final CiStdoutWriter stdoutWriter;

  /// Writes everything that is not the verdict to stderr: the project's
  /// load advisories, `wrote <format> → <path>` for each export, exports
  /// that could not be written, flag combinations that did nothing, and
  /// submitted tests that never reported a result.
  final CiStdoutWriter stderrWriter;

  /// Constructs the streaming writer when [_streamingEnabled] is true.
  final CiStreamingWriterFactory streamingWriterFactory;

  /// Policy consulted after the run completes to compute the
  /// regression-comparison exit-code override. Open-core builds use
  /// [NoopFailOnRegressionPolicy] which always returns
  /// [FailOnRegressionDecision.pass]; the Pro overlay registers a
  /// concrete policy via [failOnRegressionPolicyProvider].
  final FailOnRegressionPolicy failOnRegressionPolicy;

  /// The licence tier this run resolved, handed to [failOnRegressionPolicy].
  ///
  /// The regression gate is a paid capability, so the policy that provides it
  /// asks whether this run may use it. Both callers resolve the tier before
  /// they build the runner and load the project at it, so the gate and the
  /// `seeds:` expansion see one answer. Defaults to Open Core, like the
  /// loader's.
  final LicenseTier licenseTier;

  static StreamingResultsWriter _defaultStreamingWriterFactory({
    required String resultsPath,
    required String summaryPath,
    required String? containWithin,
  }) => StreamingResultsWriter(
    resultsPath: resultsPath,
    summaryPath: summaryPath,
    containWithin: containWithin,
  );

  /// Runs the regression at [args.projectPath] (or the supplied
  /// [config] if already loaded), emits any configured exports, and
  /// returns a [CiRunResult].
  Future<CiRunResult> run({
    required CliArgs args,
    RegressionConfig? config,
  }) async {
    config ??= await configLoader.load(args.projectPath!);
    // Load advisories — for example a `seeds:` sweep a tier did not unlock
    // and ran once — are not errors, so the load succeeds; printed here so a
    // CI log says why a sweep did not expand instead of saying nothing.
    for (final warning in config.loadWarnings) {
      stderrWriter('warning: ${warning.format()}');
    }
    final tests = <TestSpec>[
      for (final suite in config.suites)
        ...suite.tests.where((t) => _matchesFilter(t, args.filter)),
    ];
    final runId = DateTime.now().toUtc().millisecondsSinceEpoch.toString();
    final scheduler = schedulerFactory(config);
    final results = <TestResult>[];
    final rows = <DashboardRow>[];
    final specsById = <String, TestSpec>{
      for (final t in tests) t.id: t,
    };
    final completer = Completer<void>();
    var cancelled = false;
    final startedAt = DateTime.now().toUtc();
    // CI mode promotes streaming to `true` regardless of the YAML;
    // interactive runs may opt in via `output: { streaming: true }`.
    final streamingOn = args.ciMode || config.output.streaming;
    StreamingResultsWriter? streamingWriter;
    if (streamingOn) {
      final resolved = _resolveStreamingPath(args, config);
      streamingWriter = streamingWriterFactory(
        resultsPath: resolved.results,
        summaryPath: resolved.summary,
        // The writer's own check, on the paths it is about to open. The
        // loader has already refused a project whose `output:` leads out;
        // this covers a config built in code and a directory that became a
        // link after the load. `--allow-project-tooling` lifts both.
        containWithin: args.allowProjectTooling ? null : resolved.projectDir,
      );
      await streamingWriter.start(
        runId: runId,
        startedAt: startedAt,
        configPath: args.projectPath,
      );
    }
    final totals = <TestStatus, int>{};
    final sub = scheduler
        .submit(
          RegressionRequest(
            runId: runId,
            tests: tests,
            concurrency: args.maxParallel ?? 4,
          ),
        )
        .listen(
          (event) async {
            switch (event) {
              case TestFinished(:final result):
                results.add(result);
                final row = DashboardRow(
                  result: result,
                  suiteName: specsById[result.testId]?.suiteName ?? '',
                  simulatorId:
                      specsById[result.testId]?.simulatorId ?? 'unknown',
                  testName: specsById[result.testId]?.name ?? result.testId,
                );
                rows.add(row);
                totals.update(result.status, (n) => n + 1, ifAbsent: () => 1);
                if (streamingWriter != null) {
                  await streamingWriter.recordRow(row);
                }
              case RegressionFinished(cancelled: final wasCancelled):
                cancelled = wasCancelled;
                if (!completer.isCompleted) completer.complete();
              case TestStarted():
              case TestProgress():
              case TestLog():
                break;
            }
          },
          onError: (Object error, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(error, st);
          },
        );
    try {
      await completer.future;
    } on Object {
      // The run failed before `recordRunCompletion` could write the
      // trailing `summary` line. Flush and close the NDJSON sink so the
      // partial file is a readable prefix (the reader reports
      // `summary == null` = "did not complete cleanly") instead of a
      // leaked file handle with buffered rows never hitting disk.
      await streamingWriter?.abortWithoutSummary();
      rethrow;
    } finally {
      await sub.cancel();
    }
    final finishedAt = DateTime.now().toUtc();
    if (streamingWriter != null) {
      await streamingWriter.recordRunCompletion(finishedAt: finishedAt);
    }
    final run = TestRun(
      id: runId,
      startedAt: startedAt,
      finishedAt: finishedAt,
      testIds: tests.map((t) => t.id).toList(),
      results: results,
    );
    // The summary first: it is the run's verdict, and an export that fails
    // to write must not take it (or the 0/1 exit code) down with it.
    _writeSummary(args, totals);
    final allReported = _checkEveryTestReported(
      submitted: tests,
      results: results,
      cancelled: cancelled,
    );
    final exportsWritten = await _writeExports(
      args,
      run,
      rows,
      configPath: args.projectPath,
    );
    final failures = CiRunResult.failuresIn(
      totals,
      failOnVacuous: args.failOnVacuous,
    );
    _recordRunTelemetry(
      tests: tests,
      results: results,
      specsById: specsById,
      totals: totals,
    );
    var exitCode = failures >= args.failThreshold ? 1 : 0;

    // Regression comparison gate. Only consulted when --ci AND
    // --fail-on-regression are both set. The policy is open-core's
    // NoopFailOnRegressionPolicy by default (always-pass); the Pro
    // overlay registers a concrete policy that diffs against the
    // baseline ndjson referenced by args.baselineRunPath. Layering
    // semantics: a fail-threshold failure already produced exit=1;
    // a regression detection promotes a clean run to non-zero. The
    // higher exit code wins so users see "regression detected"
    // exactly when failures alone would have been 0.
    if (args.failOnRegression && args.ciMode) {
      if (args.baselineRunPath == null) {
        stderrWriter(
          'warning: --fail-on-regression set without --baseline; '
          'skipping regression gate (exit code unchanged).',
        );
      } else {
        final decision = await failOnRegressionPolicy.shouldFailWithExitCode(
          candidate: run,
          args: args,
          licenseTier: licenseTier,
        );
        if (decision.failed && decision.exitCode > exitCode) {
          exitCode = decision.exitCode;
        }
      }
    }

    // An export target that could not be written is "SimCrux could not do
    // what was asked" (exit 2), whatever the tests did; the summary above
    // still says how they did. So is a test that was submitted and never
    // reported: the totals only count what came back.
    if ((!exportsWritten || !allReported) && exitCode < 2) exitCode = 2;

    return CiRunResult(
      run: run,
      rows: rows,
      exitCode: exitCode,
      totalsByStatus: totals,
    );
  }

  /// The most test ids [_checkEveryTestReported] names before it summarises
  /// the rest as a count.
  static const int _maxMissingIdsListed = 10;

  /// Whether every test in [submitted] came back as a result, reporting on
  /// stderr the ones that did not.
  ///
  /// The exit code is computed from the totals, and the totals count only
  /// what the scheduler reported. A scheduler that ends its stream with a
  /// test unaccounted for — a cluster job lost between submission and
  /// polling, a backend that stops early — would otherwise let a run with
  /// tests unrun exit 0.
  bool _checkEveryTestReported({
    required List<TestSpec> submitted,
    required List<TestResult> results,
    required bool cancelled,
  }) {
    final reported = <String>{for (final r in results) r.testId};
    final missing = <String>[
      for (final id in <String>{for (final t in submitted) t.id})
        if (!reported.contains(id)) id,
    ];
    if (missing.isEmpty) return true;
    final total = <String>{for (final t in submitted) t.id}.length;
    final listed = missing.take(_maxMissingIdsListed).join(', ');
    final more = missing.length > _maxMissingIdsListed
        ? ' and ${missing.length - _maxMissingIdsListed} more'
        : '';
    final why = cancelled
        ? 'the run was cancelled before they finished'
        : 'the scheduler finished without them';
    stderrWriter(
      'error: ${missing.length} of $total submitted tests reported no '
      'result ($why), so the totals do not cover the regression: '
      '$listed$more',
    );
    return false;
  }

  /// Where this run's streaming files go, and the project directory they
  /// belong to.
  ///
  /// A configured path is resolved against the directory holding the
  /// project file, like every other path in it — not against the directory
  /// the run was started from, which a project file cannot know and so
  /// could not be checked at load.
  ({String results, String summary, String projectDir}) _resolveStreamingPath(
    CliArgs args,
    RegressionConfig config,
  ) {
    final projectDir = args.projectPath != null
        ? p.dirname(p.normalize(p.absolute(args.projectPath!)))
        : Directory.current.path;
    String resolve(String? configured, String defaultName) =>
        resolveProjectOutputPath(configured ?? defaultName, projectDir);
    return (
      results: resolve(config.output.streamingResultsPath, 'results.ndjson'),
      summary: resolve(
        config.output.streamingSummaryPath,
        'results.summary.json',
      ),
      projectDir: projectDir,
    );
  }

  /// The headless half of the regression counters.
  ///
  /// The same four events the GUI runner records, with `trigger: ci` — so a
  /// dashboard can ask "what fraction of regressions run in CI" without two
  /// vocabularies to reconcile. `regression.cancelled` has no counterpart
  /// here: nothing cancels a `--ci` run from inside SimCrux, and a job killed
  /// by its runner takes this process with it.
  ///
  /// Every property is a count or a token; `tests` and `failed` are clamped by
  /// [telemetryCount] because a headless seed sweep is precisely where a count
  /// can pass the Worker's integer ceiling.
  void _recordRunTelemetry({
    required List<TestSpec> tests,
    required List<TestResult> results,
    required Map<String, TestSpec> specsById,
    required Map<TestStatus, int> totals,
  }) {
    telemetry.record(
      TelemetryEvent(
        'regression.completed',
        properties: <String, Object?>{
          'simulator': ?regressionSimulatorToken(
            tests.map((spec) => spec.simulatorId),
          ),
          'trigger': telemetryEnumToken(RegressionTrigger.ci),
          'tests': telemetryCount(tests.length),
          'failed': telemetryCount(
            CiRunResult.failuresIn(totals, failOnVacuous: false),
          ),
        },
      ),
    );
    // Per distinct kind and per distinct engine, not per test — the GUI
    // runner's reasoning applies with more force here, because a CI run is
    // where the thousand-test suites are.
    final detectorKinds = <String>{
      for (final spec in tests) ...passFailDetectorKindTokens(spec.passFail),
    };
    for (final kind in detectorKinds) {
      telemetry.record(
        TelemetryEvent(
          'detector.matched',
          properties: <String, Object?>{'kind': kind},
        ),
      );
    }
    final missingEngines = <String>{
      for (final result in results)
        if (!result.didExecute && specsById[result.testId] != null)
          simulatorTelemetryToken(specsById[result.testId]!.simulatorId),
    };
    for (final simulator in missingEngines) {
      telemetry.record(
        TelemetryEvent(
          'engine.missing',
          properties: <String, Object?>{'simulator': simulator},
        ),
      );
    }
  }

  /// Writes every export target, returning false when any could not be
  /// written. A failed target is reported on stderr and the rest are still
  /// attempted, so one bad path does not cost the other reports.
  Future<bool> _writeExports(
    CliArgs args,
    TestRun run,
    List<DashboardRow> rows, {
    String? configPath,
  }) async {
    var allWritten = true;
    for (final target in args.exportTargets) {
      final format = ExportFormat.fromId(target.formatId);
      if (format == null) {
        // `CliArgParser` refuses an unknown format before the run starts, so
        // only a programmatically-built `CliArgs` gets here. It is still a
        // report that was asked for and not written: exit 2, not a green
        // job with the file missing.
        allWritten = false;
        stderrWriter(
          'error: unknown export format "${target.formatId}"; '
          '${target.outputPath} was not written. Valid formats: '
          '${ExportFormat.values.map((f) => f.id).join(', ')}.',
        );
        continue;
      }
      final exporter = exporterRegistry.exporterFor(format);
      try {
        final bytes = exporter.encode(
          run: run,
          rows: rows,
          configPath: configPath,
        );
        await fileWriter(target.outputPath, bytes);
      } on Object catch (e) {
        allWritten = false;
        stderrWriter(
          'error: could not write the ${target.formatId} export to '
          '${target.outputPath}: $e',
        );
        continue;
      }
      // After the write, so a failed export is not counted as one. The format
      // id is `ExportFormat`'s own — already lowercase, so it satisfies the
      // Worker's value class as it stands. The output path is not sent.
      telemetry.record(
        TelemetryEvent(
          'export.completed',
          properties: <String, Object?>{'format': format.id},
        ),
      );
      // stderr: see [stdoutWriter] for why stdout carries only the verdict.
      stderrWriter('wrote ${target.formatId} → ${target.outputPath}');
    }
    return allWritten;
  }

  void _writeSummary(CliArgs args, Map<TestStatus, int> totals) {
    if (args.jsonOutput) {
      final summary = totals.map((k, v) => MapEntry(k.name, v));
      stdoutWriter('{"totals":${_jsonOf(summary)}}');
      return;
    }
    // Print a component for every status that occurred, so the printed
    // parts always sum to the printed total. The previous fixed
    // pass/fail/timeout/skipped list silently dropped `unknown`,
    // `vacuous`, `cover`, and `cancelled` — the statuses a user most
    // needs to see, since `unknown` is exactly what a crashed driver
    // or an unregistered simulator produces.
    final total = totals.values.fold<int>(0, (sum, n) => sum + n);
    final parts = <String>[
      for (final status in TestStatus.values)
        if ((totals[status] ?? 0) > 0)
          '${totals[status]} ${_summaryLabel(status)}',
    ];
    final body = parts.isEmpty ? 'no results' : parts.join(' · ');
    stdoutWriter('simcrux: $total tests · $body');
  }

  /// Past-tense label used in the human-readable summary line.
  static String _summaryLabel(TestStatus status) => switch (status) {
    TestStatus.pass => 'passed',
    TestStatus.fail => 'failed',
    TestStatus.timeout => 'timed out',
    TestStatus.skipped => 'skipped',
    TestStatus.cancelled => 'cancelled',
    TestStatus.unknown => 'unknown',
    TestStatus.vacuous => 'vacuous',
    TestStatus.cover => 'cover',
    TestStatus.running => 'running',
  };

  static void _defaultStdout(String line) {
    stdout.writeln(line);
  }

  static void _defaultStderr(String line) {
    stderr.writeln(line);
  }

  static Future<void> _defaultWriter(String path, String contents) async {
    final file = File(path);
    // `--export junit=build/reports/junit.xml` on a fresh checkout names a
    // directory that does not exist yet; create it rather than fail the
    // write after an hours-long regression.
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  static String _jsonOf(Map<String, int> totals) {
    final pairs = totals.entries.map((e) => '"${e.key}":${e.value}').join(',');
    return '{$pairs}';
  }

  static bool _matchesFilter(TestSpec spec, String? filter) {
    if (filter == null || filter.isEmpty) return true;
    return spec.id.contains(filter);
  }
}
