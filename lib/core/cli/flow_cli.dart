// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:crux_yosys/crux_yosys.dart' show ProcessRegistry;
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/core/cli/flow_exit_code.dart';
import 'package:simcrux/core/cli/flow_signal_reaper.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/flow/flow_export.dart';
import 'package:simcrux/services/flow/flow_gate.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_org_gate.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/gate_level/gls_export.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/flow/gate_level/gls_run_info.dart';
import 'package:simcrux/services/flow/gate_level/gls_runner.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// `simcrux flow run|ingest|gate|export`: the implementation-flow command
/// family of the headless binary.
///
/// - Help first: `-h` or `--help` anywhere prints usage to stdout and exits
///   0 before any engine, file or licence work.
/// - `--version` prints `<name-as-typed> <semver>`.
/// - Results to stdout, diagnostics to stderr.
/// - Exit codes are [FlowExitCode]'s; the usage code is 64 for every
///   subcommand.
/// - Never gated: a flow verdict and the CI gate are correctness and free.
/// - Headless never transmits telemetry.
class FlowCli {
  /// Creates the command.
  FlowCli({
    required this.stdoutSink,
    required this.stderrSink,
    required this.driverRegistry,
    this.programName = 'simcrux',
    ConfigLoader Function({required bool allowTooling})? loaderFactory,
    this.ingestor = const FlowRunIngestor(),
    this.schedulerFactory,
    this.orgGate,
    FlowSignalReaper Function()? signalReaper,
    String Function()? currentDirectory,
    Map<String, String> Function()? environment,
    String? Function()? glsScratchRoot,
  }) : _loaderFactory = loaderFactory ?? _defaultLoader,
       _signalReaper = signalReaper ?? FlowSignalReaper.new,
       _cwd = currentDirectory ?? (() => Directory.current.path),
       _environment = environment ?? (() => Platform.environment),
       _glsScratchRoot = glsScratchRoot ?? (() => null);

  /// Receives one call per stdout line.
  final void Function(String line) stdoutSink;

  /// Receives one call per stderr line.
  final void Function(String line) stderrSink;

  /// The drivers `flow run` runs entries with.
  final SimulatorDriverRegistry driverRegistry;

  /// The binary's name as typed, for `--version`.
  final String programName;

  /// Reads runs for `ingest`, `gate` and `export`.
  final FlowRunIngestor ingestor;

  /// The scheduler `flow run` submits to; a [LocalJobScheduler] over
  /// [driverRegistry] when null.
  final JobScheduler Function(RegressionConfig config)? schedulerFactory;

  /// The organization's thresholds `flow gate` evaluates beside the user's,
  /// or null. This binary resolves none: it reads no organization policy, so
  /// it never exits [FlowExitCode.orgThresholdViolated]. An edition that
  /// honours the policy passes one in.
  final FlowOrgGate? orgGate;

  final ConfigLoader Function({required bool allowTooling}) _loaderFactory;
  final FlowSignalReaper Function() _signalReaper;
  final String Function() _cwd;
  final Map<String, String> Function() _environment;
  final String? Function() _glsScratchRoot;

  static ConfigLoader _defaultLoader({required bool allowTooling}) =>
      ConfigLoader(allowProjectDefinedTooling: allowTooling);

  /// The subcommand words.
  static const List<String> kSubcommands = <String>[
    'run',
    'ingest',
    'gate',
    'export',
    'gls',
  ];

  /// The `flow` usage block.
  String get usage => <String>[
    'Usage: $programName flow <subcommand> [options]',
    '',
    'Implementation flows (LibreLane, nextpnr).',
    'Results are findings, not signoff.',
    '',
    '  run    [--entry <name>]... [--allow-project-tooling] [--json]',
    '         [<project>]',
    "         Run the project's flow: entries (simcrux.yaml by default).",
    '  ingest <run-dir|report.json>... [--json]',
    '         Read runs SimCrux did not launch. Writes nothing.',
    '  gate   <run-dir|report.json> [--fail-on-wns <ns>]',
    '         [--fail-on-hold-wns <ns>] [--fail-on-fmax-below <MHz>]',
    "         [--fail-on '<metric><op><value>']... [--baseline <file>]",
    '         [--sarif <out>] [--junit <out>] [--json]',
    '  export <run-dir|report.json> --format json|junit|sarif|html',
    '         --out <file>',
    '  gls    <run-dir> [--entry <name>] [--test <name>]...',
    '         [--netlist nl|pnl] [--strict-x] [--clock <port>]',
    '         [--project <simcrux.yaml>] [--allow-project-tooling]',
    '         [--junit <out>] [--json]',
    "         Rerun regression tests against a LibreLane run's netlist:",
    '         functional gate-level simulation under Icarus, unit delays.',
    '',
    'Exit codes: 0 met, 1 violated, 2 could not evaluate,',
    '3 organization threshold violated, 64 usage, 65 unreadable input,',
    '130 or 143 interrupted. For gls: 0 equal or X-asymmetry only,',
    '1 differs (or X-asymmetry only with --strict-x), 2 no test could run.',
    'nextpnr WNS is derived per clock as 1000/constraint - 1000/achieved ns.',
  ].join('\n');

  /// Runs `flow` with [args] (the words after `flow`) and returns the exit
  /// code.
  Future<int> run(List<String> args) async {
    if (args.contains('-h') || args.contains('--help')) {
      stdoutSink(usage);
      return FlowExitCode.met;
    }
    if (args.isEmpty) {
      stdoutSink(usage);
      return FlowExitCode.met;
    }
    if (args.first == '--version') {
      stdoutSink('$programName ${SimCruxBuildInfo.productVersion}');
      return FlowExitCode.met;
    }
    final rest = args.skip(1).toList(growable: false);
    try {
      return switch (args.first) {
        'run' => await _run(rest),
        'ingest' => await _ingest(rest),
        'gate' => await _gate(rest),
        'export' => await _export(rest),
        'gls' => await _gls(rest),
        _ => _usageError('unknown subcommand "${args.first}"'),
      };
    } on _UsageException catch (e) {
      return _usageError(e.message);
    }
  }

  int _usageError(String message) {
    stderrSink('$programName flow: $message');
    stderrSink('');
    stderrSink(usage);
    return FlowExitCode.usage;
  }

  ArgResults _parse(ArgParser parser, List<String> args) {
    try {
      return parser.parse(args);
    } on FormatException catch (e) {
      throw _UsageException(e.message);
    }
  }

  double _number(ArgResults results, String option) {
    final raw = results.option(option)!;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite) {
      throw _UsageException('--$option expects a number, got "$raw"');
    }
    return value;
  }

  // ── run ──────────────────────────────────────────────────────────────

  Future<int> _run(List<String> args) async {
    final parser = ArgParser()
      ..addMultiOption('entry', help: 'Run only this entry.')
      ..addFlag('allow-project-tooling', negatable: false)
      ..addFlag('json', negatable: false);
    final results = _parse(parser, args);
    if (results.rest.length > 1) {
      throw const _UsageException('flow run takes one project');
    }
    final project = results.rest.isEmpty
        ? p.join(_cwd(), 'simcrux.yaml')
        : results.rest.first;
    if (!File(project).existsSync()) {
      throw _UsageException('no project file at $project');
    }
    final RegressionConfig config;
    try {
      config = await _loaderFactory(
        allowTooling: results.flag('allow-project-tooling'),
      ).load(project);
    } on ConfigLoaderException catch (e) {
      stderrSink('$programName flow run: the project did not load:');
      for (final error in e.errors) {
        stderrSink('  $error');
      }
      return FlowExitCode.dataErr;
    }
    for (final warning in config.loadWarnings) {
      stderrSink('warning: $warning');
    }
    final flowSuite = config.suites.where(
      (s) => s.name == FlowRunImporter.kFlowSuiteName,
    );
    final specs = flowSuite.isEmpty
        ? const <TestSpec>[]
        : flowSuite.first.tests;
    if (specs.isEmpty) {
      throw const _UsageException('the project declares no flow: entries');
    }
    final wanted = results.multiOption('entry');
    final unknown = <String>[
      for (final name in wanted)
        if (!specs.any((s) => s.name == name)) name,
    ];
    if (unknown.isNotEmpty) {
      throw _UsageException('no flow entry named ${unknown.join(', ')}');
    }
    final selected = specs
        .where((s) => wanted.isEmpty || wanted.contains(s.name))
        .toList(growable: false);

    final scheduler =
        schedulerFactory?.call(config) ??
        LocalJobScheduler(
          driverRegistry: driverRegistry,
          config: config,
          dumpRetentionPolicy: DumpRetentionPolicy.defaultPolicy,
        );
    final runId = 'flow-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final reaper = _signalReaper()
      ..install((_) {
        unawaited(scheduler.cancel(runId));
        ProcessRegistry.instance.killAll();
      });
    final finished = <TestResult>[];
    try {
      await for (final event in scheduler.submit(
        RegressionRequest(
          runId: runId,
          tests: selected,
          concurrency: selected.length.clamp(1, 4),
          defaultTimeout: FlowRunImporter.kFlowTimeout,
        ),
      )) {
        switch (event) {
          case TestLog(:final line, :final fromStderr):
            if (fromStderr) stderrSink(line);
          case TestFinished(:final result):
            finished.add(result);
          default:
            break;
        }
      }
    } finally {
      await reaper.dispose();
    }

    final signalCode = reaper.exitCode;
    final code = signalCode ?? _codeForResults(finished);
    if (results.flag('json')) {
      stdoutSink(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'schema': 'simcrux-flow-run/1',
          'entries': <Object?>[
            for (final r in finished)
              <String, Object?>{
                'test_id': r.testId,
                'status': r.status.name,
                'failure': ?r.failureMessage,
                'metrics': r.metrics,
              },
          ],
          'exit_code': code,
          'exit_label': FlowExitCode.labelFor(code),
          'note': kFlowFindingsNote,
        }),
      );
    } else {
      for (final r in finished) {
        final verdict = r.metrics[FlowMetricKeys.verdict] ?? 'not_run';
        final runDir = r.metrics[FlowMetricKeys.runDir] ?? '';
        stdoutSink('${r.testId}: $verdict${runDir.isEmpty ? '' : '  $runDir'}');
        if (r.failureMessage != null) stdoutSink('  ${r.failureMessage}');
      }
      stdoutSink('$programName flow: ${FlowExitCode.labelFor(code)}');
    }
    return code;
  }

  int _codeForResults(List<TestResult> results) {
    var violated = false;
    var unevaluable = results.isEmpty;
    for (final r in results) {
      switch (r.metrics[FlowMetricKeys.verdict]) {
        case 'met':
          break;
        case 'violated':
          violated = true;
        default:
          unevaluable = true;
      }
    }
    if (unevaluable) return FlowExitCode.couldNotEvaluate;
    return violated ? FlowExitCode.violated : FlowExitCode.met;
  }

  // ── ingest, gate, export: reading one run ──────────────────────────────

  /// Reads the run at [path], or returns the exit code that ends the
  /// command: 64 for a missing path, 65 for input that exists but cannot be
  /// converted.
  Future<({FlowReading? reading, int? code})> _readOne(String path) async {
    final absolute = p.normalize(p.absolute(path));
    if (FileSystemEntity.typeSync(absolute) == FileSystemEntityType.notFound) {
      throw _UsageException('nothing exists at $path');
    }
    final root = FileSystemEntity.isDirectorySync(absolute)
        ? absolute
        : p.dirname(absolute);
    final items = await ingestor.ingest(
      <String>[absolute],
      allowedRoots: <String>[root],
    );
    final reading = items.isEmpty ? null : items.first.reading;
    if (reading == null) {
      stderrSink(
        '$programName flow: $path: '
        '${items.isEmpty ? 'no run' : items.first.message}',
      );
      return (reading: null, code: FlowExitCode.dataErr);
    }
    if (items.length > 1) {
      throw _UsageException(
        '$path holds ${items.length} runs; name one run directory',
      );
    }
    if (_unconvertible(reading)) {
      stderrSink('$programName flow: $path: ${reading.problem}');
      return (reading: reading, code: FlowExitCode.dataErr);
    }
    return (reading: reading, code: null);
  }

  /// A report or metrics file exists but could not be converted.
  static bool _unconvertible(FlowReading reading) =>
      reading.verdict == FlowVerdict.unrecognised &&
      reading.problem != null &&
      reading.run.metrics.isEmpty;

  Future<int> _ingest(List<String> args) async {
    final parser = ArgParser()..addFlag('json', negatable: false);
    final results = _parse(parser, args);
    if (results.rest.isEmpty) {
      throw const _UsageException(
        'flow ingest needs a run directory or report',
      );
    }
    for (final path in results.rest) {
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        throw _UsageException('nothing exists at $path');
      }
    }
    final items = await ingestor.ingest(
      results.rest,
      allowedRoots: results.rest.map(_rootOf).toList(growable: false),
    );
    var dataErr = false;
    final readings = <FlowReading>[];
    for (final item in items) {
      final reading = item.reading;
      if (reading == null) {
        stderrSink('$programName flow ingest: ${item.path}: ${item.message}');
        dataErr = true;
      } else if (_unconvertible(reading)) {
        stderrSink(
          '$programName flow ingest: ${item.path}: ${reading.problem}',
        );
        dataErr = true;
      } else {
        readings.add(reading);
      }
    }
    final code = dataErr
        ? FlowExitCode.dataErr
        : _codeForVerdicts(readings.map((r) => r.verdict));
    if (results.flag('json')) {
      stdoutSink(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'schema': 'simcrux-flow-ingest/1',
          'runs': <Object?>[for (final r in readings) flowRunJson(r)],
          'exit_code': code,
          'exit_label': FlowExitCode.labelFor(code),
        }),
      );
    } else {
      for (final r in readings) {
        stdoutSink(
          '${r.run.ref.kind.wireName} ${r.run.ref.tag}: ${r.verdict.wireName}'
          '${r.run.ref.verified ? '' : ' (reader not verified)'}  '
          '${r.run.ref.root}',
        );
      }
    }
    return code;
  }

  /// The directory a path the user named may be read within: itself, or the
  /// directory holding the file.
  static String _rootOf(String path) {
    final absolute = p.normalize(p.absolute(path));
    return FileSystemEntity.isDirectorySync(absolute)
        ? absolute
        : p.dirname(absolute);
  }

  static int _codeForVerdicts(Iterable<FlowVerdict> verdicts) {
    var violated = false;
    var unevaluable = verdicts.isEmpty;
    for (final v in verdicts) {
      if (v == FlowVerdict.violated) {
        violated = true;
      } else if (v != FlowVerdict.met) {
        unevaluable = true;
      }
    }
    if (unevaluable) return FlowExitCode.couldNotEvaluate;
    return violated ? FlowExitCode.violated : FlowExitCode.met;
  }

  Future<int> _gate(List<String> args) async {
    final parser = ArgParser()
      ..addOption('fail-on-wns')
      ..addOption('fail-on-hold-wns')
      ..addOption('fail-on-fmax-below')
      ..addMultiOption('fail-on', splitCommas: false)
      ..addOption('baseline')
      ..addOption('sarif')
      ..addOption('junit')
      ..addFlag('json', negatable: false);
    final results = _parse(parser, args);
    if (results.rest.length != 1) {
      throw const _UsageException(
        'flow gate needs exactly one run directory or report',
      );
    }
    final thresholds = <FlowThreshold>[
      if (results.wasParsed('fail-on-wns'))
        FlowThreshold.wns(_number(results, 'fail-on-wns')),
      if (results.wasParsed('fail-on-hold-wns'))
        FlowThreshold.holdWns(_number(results, 'fail-on-hold-wns')),
      if (results.wasParsed('fail-on-fmax-below'))
        FlowThreshold.fmaxBelow(_number(results, 'fail-on-fmax-below')),
    ];
    for (final spec in results.multiOption('fail-on')) {
      try {
        thresholds.add(FlowThreshold.parse(spec));
      } on FormatException catch (e) {
        throw _UsageException(e.message);
      }
    }
    Map<String, Object?>? baseline;
    final baselinePath = results.option('baseline');
    if (baselinePath != null) {
      if (!File(baselinePath).existsSync()) {
        throw _UsageException('no baseline file at $baselinePath');
      }
      baseline = await _readBaseline(baselinePath);
      if (baseline == null) {
        stderrSink(
          '$programName flow gate: the baseline is not a metrics JSON object',
        );
        return FlowExitCode.dataErr;
      }
    }
    final read = await _readOne(results.rest.first);
    final reading = read.reading;
    if (read.code != null || reading == null) {
      return read.code ?? FlowExitCode.dataErr;
    }
    final outcome = evaluateFlowGate(reading, thresholds, baseline: baseline);
    final userCode = switch (outcome.decision) {
      FlowGateDecision.met => FlowExitCode.met,
      FlowGateDecision.violated => FlowExitCode.violated,
      FlowGateDecision.couldNotEvaluate => FlowExitCode.couldNotEvaluate,
    };
    // The organization's thresholds, evaluated beside the user's and never
    // in place of them.
    final org = orgGate;
    final orgOutcome = org == null || org.isEmpty
        ? null
        : org.evaluate(reading, subject: reading.run.ref.tag);
    final code = FlowOrgGate.combineExitCode(userCode, orgOutcome?.decision);
    final sarif = results.option('sarif');
    if (sarif != null) {
      await File(sarif).writeAsString(await flowSarifWithPaths(reading));
    }
    final junit = results.option('junit');
    if (junit != null) {
      await File(junit).writeAsString(
        flowJunit(<FlowReading>[reading], outcome: outcome),
      );
    }
    if (results.flag('json')) {
      stdoutSink(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          ...flowGateJson(
            reading,
            outcome,
            exitCode: code,
            exitLabel: FlowExitCode.labelFor(code),
          ),
          if (orgOutcome != null) 'org_gate': FlowOrgGate.json(orgOutcome),
        }),
      );
    } else {
      stdoutSink(
        '${reading.run.ref.kind.wireName} ${reading.run.ref.tag}: '
        '${reading.verdict.wireName}',
      );
      if (reading.problem != null) stdoutSink('  ${reading.problem}');
      if (reading.wnsNs != null) {
        stdoutSink(
          '  WNS ${reading.wnsNs!.toStringAsFixed(3)} ns'
          '${reading.wnsDerivation == null ? '' : ' (${reading.wnsDerivation})'}',
        );
      }
      for (final r in outcome.thresholds) {
        stdoutSink(
          '  ${r.threshold.expression}: '
          '${r.missing ? 'missing' : (r.failed ? 'failed (${r.value})' : 'met (${r.value})')}',
        );
      }
      for (final c in outcome.baselineWorse) {
        stdoutSink(
          '  ${c.metricName}: worse than the baseline '
          '(${c.formattedGold} to ${c.formattedCurrent})',
        );
      }
      if (orgOutcome != null) {
        for (final r in orgOutcome.thresholds) {
          stdoutSink(
            '  organization ${r.threshold.expression}: '
            '${r.missing ? 'missing' : (r.failed ? 'failed (${r.value})' : 'met (${r.value})')}',
          );
        }
      }
      stdoutSink('$programName flow gate: ${FlowExitCode.labelFor(code)}');
    }
    return code;
  }

  /// A baseline: a flat METRICS2.1 document (LibreLane's
  /// `final/metrics.json`), or a `flow export --format json` document whose
  /// `metrics` object is used. Bounded by crux_flow's input limits.
  static Future<Map<String, Object?>?> _readBaseline(String path) async {
    try {
      final document = await MetricsDocument.readFile(path);
      if (document.values.containsKey('schema')) {
        // An export: its metrics are one level down, which the flat reader
        // drops, so read that object with the same limits.
        final json = MetricsDocument.parse(
          jsonEncode(
            (jsonDecode(await File(path).readAsString())
                as Map<String, Object?>)['metrics'],
          ),
        );
        return json.values;
      }
      return document.values;
    } on Object {
      return null;
    }
  }

  Future<int> _export(List<String> args) async {
    final parser = ArgParser()
      ..addOption('format', allowed: FlowExportFormat.values.map((f) => f.name))
      ..addOption('out');
    final results = _parse(parser, args);
    if (results.rest.length != 1) {
      throw const _UsageException(
        'flow export needs exactly one run directory or report',
      );
    }
    final formatName = results.option('format');
    final out = results.option('out');
    if (formatName == null) throw const _UsageException('--format is required');
    if (out == null) throw const _UsageException('--out is required');
    final read = await _readOne(results.rest.first);
    final reading = read.reading;
    if (read.code != null || reading == null) {
      return read.code ?? FlowExitCode.dataErr;
    }
    final text = switch (FlowExportFormat.fromName(formatName)!) {
      FlowExportFormat.json => const JsonEncoder.withIndent(
        '  ',
      ).convert(flowRunJson(reading)),
      FlowExportFormat.junit => flowJunit(<FlowReading>[reading]),
      FlowExportFormat.sarif => await flowSarifWithPaths(reading),
      FlowExportFormat.html => flowHtml(reading),
    };
    await File(out).writeAsString(text);
    stdoutSink('$programName flow export: wrote $out');
    return FlowExitCode.met;
  }

  // ── gls: functional gate-level simulation of a run's netlist ───────────

  Future<int> _gls(List<String> args) async {
    final parser = ArgParser()
      ..addOption('entry')
      ..addMultiOption('test', splitCommas: false)
      ..addOption('netlist', allowed: FlowGlsConfig.kNetlists)
      ..addFlag('strict-x', negatable: false)
      ..addOption('clock')
      ..addOption('project')
      ..addFlag('allow-project-tooling', negatable: false)
      ..addOption('junit')
      ..addFlag('json', negatable: false);
    final results = _parse(parser, args);
    if (results.rest.length != 1) {
      throw const _UsageException('flow gls needs exactly one run directory');
    }
    final runDir = results.rest.first;
    if (!Directory(runDir).existsSync()) {
      throw _UsageException('no run directory at $runDir');
    }
    final project = results.option('project') ?? p.join(_cwd(), 'simcrux.yaml');
    if (!File(project).existsSync()) {
      throw _UsageException('no project file at $project');
    }
    final RegressionConfig config;
    try {
      config = await _loaderFactory(
        allowTooling: results.flag('allow-project-tooling'),
      ).load(project);
    } on ConfigLoaderException catch (e) {
      stderrSink('$programName flow gls: the project did not load:');
      for (final error in e.errors) {
        stderrSink('  $error');
      }
      return FlowExitCode.dataErr;
    }
    for (final warning in config.loadWarnings) {
      stderrSink('warning: $warning');
    }

    // The entry whose `gls:` block supplies the defaults: the one named, else
    // the project's only LibreLane entry.
    final entries = <FlowEntry>[
      for (final e in config.flow?.entries ?? const <FlowEntry>[])
        if (e.kind == FlowKind.librelane) e,
    ];
    FlowEntry? entry;
    final named = results.option('entry');
    if (named != null) {
      for (final e in entries) {
        if (e.name == named) entry = e;
      }
      if (entry == null) {
        throw _UsageException('no LibreLane flow entry named $named');
      }
    } else if (entries.length == 1) {
      entry = entries.single;
    }
    final defaults = entry?.gls;
    final typed = results.multiOption('test');
    final options = GlsOptions(
      netlist: results.option('netlist') ?? defaults?.netlist ?? 'nl',
      strictX: results.flag('strict-x') || (defaults?.strictX ?? false),
      clock: results.option('clock') ?? defaults?.clock,
      tests: typed.isNotEmpty ? typed : (defaults?.tests ?? const <String>[]),
    );
    if (options.tests.isEmpty) {
      throw const _UsageException(
        "no tests selected: name them with --test, or in the entry's "
        'gls: tests',
      );
    }
    final candidates = <TestSpec>[
      for (final suite in config.suites)
        if (suite.name != FlowRunImporter.kFlowSuiteName) ...suite.tests,
    ];
    final selection = GlsPlanner.select(candidates, options.tests);
    if (selection.unmatched.isNotEmpty) {
      throw _UsageException(
        'no test named ${selection.unmatched.join(', ')}',
      );
    }

    final env = _environment();
    final read = await GlsRunInfo.read(
      runRoot: runDir,
      netlist: options.netlist,
      pdkRootFallback: env['PDK_ROOT'],
      home: env['HOME'] ?? env['USERPROFILE'],
    );
    final info = read.info;
    if (info == null) {
      final reason = read.problem ?? GlsNotRunReason.runUnreadable;
      stderrSink(
        '$programName flow gls: $runDir: cannot be simulated '
        '(${reason.wireName})',
      );
      return reason == GlsNotRunReason.runUnreadable
          ? FlowExitCode.dataErr
          : FlowExitCode.couldNotEvaluate;
    }

    final scratch = GlsScratch(root: _glsScratchRoot());
    final runId = 'gls-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final planSet = await GlsPlanner.plan(
      info: info,
      options: options,
      selected: selection.selected,
      runDir: await scratch.allocateRun(runId),
      scratch: scratch,
    );
    final scheduler = GlsScheduler(
      inner:
          schedulerFactory?.call(config) ??
          LocalJobScheduler(
            driverRegistry: driverRegistry,
            config: config,
            dumpRetentionPolicy: DumpRetentionPolicy.defaultPolicy,
          ),
      plans: planSet.plans,
      info: info,
      options: options,
    );
    final reaper = _signalReaper()
      ..install((_) {
        unawaited(scheduler.cancel(runId));
        ProcessRegistry.instance.killAll();
      });
    final finished = <TestResult>[];
    try {
      await for (final event in scheduler.submit(
        RegressionRequest(
          runId: runId,
          tests: <TestSpec>[for (final plan in planSet.plans) plan.submitSpec],
          concurrency: planSet.plans.length.clamp(1, 4),
        ),
      )) {
        switch (event) {
          case TestLog(:final line, :final fromStderr):
            if (fromStderr) stderrSink(line);
          case TestFinished(:final result):
            finished.add(result);
          default:
            break;
        }
      }
    } finally {
      await reaper.dispose();
    }

    final views = <GlsResultView>[
      for (final r in finished) ?GlsResultView.of(r),
    ];
    final code = reaper.exitCode ?? _glsCode(views);
    final label = FlowExitCode.labelFor(code);
    final junit = results.option('junit');
    if (junit != null) await File(junit).writeAsString(glsJunit(views));
    for (final v in views) {
      if (v.bannered) {
        stderrSink(
          'warning: gate-level simulation of this PDK is not yet measured on '
          'a design Icarus can judge; read the result as unmeasured.',
        );
        break;
      }
    }
    for (final v in views) {
      if (v.versionDiffers) {
        stderrSink(
          "warning: the PDK version installed here differs from the run's.",
        );
        break;
      }
    }
    if (results.flag('json')) {
      stdoutSink(
        const JsonEncoder.withIndent('  ').convert(
          glsJson(
            views,
            runDir: info.runRoot,
            exitCode: code,
            exitLabel: label,
            note: kGlsFindingsNote,
          ),
        ),
      );
    } else {
      for (final v in views) {
        final reason = v.reason == null ? '' : ' (${v.reason!.wireName})';
        final counts = v.outcome == GlsOutcome.notRun
            ? ''
            : '  real ${v.realDiffs ?? 0}, x-asymmetry ${v.xDiffs ?? 0}';
        stdoutSink('${v.testId}: ${v.outcome.wireName}$reason$counts');
      }
      stdoutSink('$programName flow gls: $label');
    }
    return code;
  }

  /// 0 when every test that ran is equal (or X-only without strict x), 1 when
  /// one differs (or is X-only under strict x), 2 when none could run, 65
  /// when what stopped them was an unreadable port dump.
  static int _glsCode(List<GlsResultView> views) {
    final ran = views.where((v) => v.outcome != GlsOutcome.notRun);
    if (ran.isEmpty) {
      final dumps = views.any(
        (v) =>
            v.reason == GlsNotRunReason.vcdUnreadable ||
            v.reason == GlsNotRunReason.vcdTooLarge,
      );
      return dumps ? FlowExitCode.dataErr : FlowExitCode.couldNotEvaluate;
    }
    return ran.any((v) => !v.passes) ? FlowExitCode.violated : FlowExitCode.met;
  }
}

class _UsageException implements Exception {
  const _UsageException(this.message);

  final String message;
}
