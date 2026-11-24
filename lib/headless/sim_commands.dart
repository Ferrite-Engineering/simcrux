// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// `simcrux run`, `results`, `test` and `trend`: each parses its command
/// line and answers with one `crux_mcp` document. The command line writes
/// it with `--json`; `simcrux mcp` returns it as the tool's text. One code
/// path for both doors.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crux_mcp/crux_mcp.dart' hide HeadlessTelemetry;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/config/project_output_path.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';
import 'package:simcrux/services/result_store/streaming_result_row.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';

/// What `run` asks the regression runner for.
class SimRunRequest {
  /// A run of [configPath] (absolute).
  const SimRunRequest({
    required this.configPath,
    this.filter,
    this.maxParallel,
    this.licenseFile,
    this.cancel,
    this.onProgress,
  });

  /// The `simcrux.yaml`.
  final String configPath;

  /// `--filter`.
  final String? filter;

  /// `--max-parallel`.
  final int? maxParallel;

  /// `--license-file`.
  final String? licenseFile;

  /// Completes when the run must stop.
  final Future<void>? cancel;

  /// Tests finished out of tests submitted, after each one.
  final void Function(int finished, int submitted)? onProgress;
}

/// A finished run and the project's load advisories.
typedef SimRunExecution = ({CiRunResult result, List<String> loadWarnings});

/// Runs a regression the way `--ci` does, from the same `CiRunner`.
/// Throws what the run throws: a [HeadlessLicenseException], a
/// [ConfigLoaderException], a [ProjectOutputPathException], or anything
/// else for a run that broke.
typedef SimRunExecutor = Future<SimRunExecution> Function(SimRunRequest r);

/// The four commands.
class SimCommands {
  /// Commands writing documents as [program], running regressions with
  /// [execute], deciding outcomes with [classify]. [trendFlakiness] gives
  /// `trend` its flakiness class; without it the class is withheld, and the
  /// document says so. [scratchRuns] is SimCrux's own `runs/` folder, where
  /// a `--root` run may still read a failing test's log.
  SimCommands({
    required this.program,
    required this.execute,
    required this.scratchRuns,
    this.classify = classifySimRun,
    this.trendFlakiness,
  });

  /// The program every document names.
  final McpProgram program;

  /// Runs a regression.
  final SimRunExecutor execute;

  /// SimCrux's `runs/` scratch folder.
  final String Function() scratchRuns;

  /// Maps a run to its outcome.
  final SimRunClassifier classify;

  /// The flakiness class, when this build computes one.
  final SimTrendFlakiness? trendFlakiness;

  /// The command names, in the order help lists them.
  static const List<String> names = <String>[
    kRunCommand,
    kResultsCommand,
    kTestCommand,
    kTrendCommand,
  ];

  /// The one-line purpose and the usage line of [command].
  static String usageOf(String command) => switch (command) {
    kRunCommand =>
      'Run a regression from its simcrux.yaml and describe each test, '
          'failures first. Writes what simcrux --ci writes for the config.\n\n'
          'Usage: simcrux run <simcrux.yaml> [--filter <s>] '
          '[--max-parallel <n>] [--limit <n>] [--license-file <path>] --json',
    kResultsCommand =>
      'The results of a run, read from its results.ndjson. Runs nothing.\n\n'
          'Usage: simcrux results <results.ndjson> [--status <s>]... '
          '[--limit <n>] --json',
    kTestCommand =>
      'One test of a run: its row, seed, parameters and the end of its log.'
          '\n\nUsage: simcrux test <results.ndjson> <suite/test> '
          '[--lines <n>] --json',
    _ =>
      "A test's history across runs, newest first.\n\n"
          'Usage: simcrux trend <suite/test> <results.ndjson>... --json',
  };

  /// The parser of [command]'s flags.
  static ArgParser parserFor(String command) {
    final parser = ArgParser()
      ..addFlag('json', negatable: false, help: 'Write the JSON document.')
      ..addFlag('help', abbr: 'h', negatable: false, help: 'This text.')
      ..addOption(
        'root',
        hide: true,
        help: 'Read logs only inside this directory or SimCrux scratch.',
      );
    switch (command) {
      case kRunCommand:
        parser
          ..addOption(
            'filter',
            abbr: 'f',
            valueHelp: 's',
            help: 'Only tests whose id (suite/test) contains this text.',
          )
          ..addOption(
            'max-parallel',
            abbr: 'j',
            valueHelp: 'n',
            help: 'Tests run at once (default 4).',
          )
          ..addOption(
            'limit',
            valueHelp: 'n',
            help:
                'Tests listed, default $kDefaultRowLimit, at most '
                '$kMaxRowLimit.',
          )
          ..addOption(
            'license-file',
            valueHelp: 'path',
            help: 'A SimCrux licence file, as for --ci.',
          );
      case kResultsCommand:
        parser
          ..addMultiOption(
            'status',
            valueHelp: 's',
            help:
                'Only tests with this status (pass, fail, timeout, '
                'vacuous, cover, skipped, cancelled, unknown).',
          )
          ..addOption(
            'limit',
            valueHelp: 'n',
            help:
                'Tests listed, default $kDefaultRowLimit, at most '
                '$kMaxRowLimit.',
          );
      case kTestCommand:
        parser.addOption(
          'lines',
          valueHelp: 'n',
          help: 'Log lines, default $kDefaultLogLines, at most $kMaxLogLines.',
        );
    }
    return parser;
  }

  McpDocument _usage(String command, String message) =>
      McpDocument.usage(tool: program, command: command, message: message);

  McpDocument _fail(String command, McpOutcome outcome, McpDiagnostic d) =>
      McpDocument(
        tool: program,
        command: command,
        outcome: outcome,
        diagnostics: <McpDiagnostic>[d],
      );

  /// A whole number of [option] from 1 to [max], [fallback] when absent, or
  /// a usage message.
  static Object _count(ArgResults a, String option, int fallback, int max) {
    final raw = a.option(option);
    if (raw == null) return fallback;
    final n = int.tryParse(raw);
    if (n == null || n < 1 || n > max) {
      return '--$option is a whole number from 1 to $max, not "$raw".';
    }
    return n;
  }

  SimReadScope _scope(ArgResults a) {
    final root = a.option('root');
    if (root == null) return SimReadScope.unlimited();
    return SimReadScope(<Confinement>[
      Confinement(root),
      Confinement(scratchRuns()),
    ]);
  }

  /// The document `simcrux <command> <args>` writes with `--json`. A
  /// cancelled run completes [cancel]; [onProgress] hears each finished
  /// test.
  Future<McpDocument> document(
    String command,
    List<String> args, {
    Future<void>? cancel,
    void Function(int finished, int submitted)? onProgress,
  }) async {
    final ArgResults a;
    try {
      a = parserFor(command).parse(args);
    } on FormatException catch (e) {
      return _usage(command, e.message);
    }
    final rest = a.rest;
    switch (command) {
      case kRunCommand:
        if (rest.length != 1) {
          return _usage(command, '`run` takes one simcrux.yaml.');
        }
        final limit = _count(a, 'limit', kDefaultRowLimit, kMaxRowLimit);
        if (limit is String) return _usage(command, limit);
        final parallel = _count(a, 'max-parallel', 4, 1 << 16);
        if (parallel is String) return _usage(command, parallel);
        return await _run(
          a,
          absolutePath(rest.single),
          limit: limit as int,
          parallel: a.option('max-parallel') == null ? null : parallel as int,
          cancel: cancel,
          onProgress: onProgress,
        );
      case kResultsCommand:
        if (rest.length != 1) {
          return _usage(command, '`results` takes one results.ndjson.');
        }
        final limit = _count(a, 'limit', kDefaultRowLimit, kMaxRowLimit);
        if (limit is String) return _usage(command, limit);
        final statuses = <TestStatus>{};
        for (final s in a.multiOption('status')) {
          final status = kTotalsOrder.where((t) => t.name == s).firstOrNull;
          if (status == null) {
            return _usage(
              command,
              '--status "$s" is not one of '
              '${kTotalsOrder.map((t) => t.name).join(', ')}.',
            );
          }
          statuses.add(status);
        }
        return await _results(
          a,
          absolutePath(rest.single),
          limit: limit as int,
          statuses: statuses.isEmpty ? null : statuses,
        );
      case kTestCommand:
        if (rest.length != 2) {
          return _usage(
            command,
            '`test` takes a results.ndjson and a test id (suite/test).',
          );
        }
        final lines = _count(a, 'lines', kDefaultLogLines, kMaxLogLines);
        if (lines is String) return _usage(command, lines);
        return await _test(
          a,
          absolutePath(rest[0]),
          rest[1],
          lines: lines as int,
        );
      default:
        if (rest.length < 2) {
          return _usage(
            command,
            '`trend` takes a test id (suite/test) and at least one '
            'results.ndjson.',
          );
        }
        if (rest.length - 1 > kMaxTrendRuns) {
          return _usage(
            command,
            '`trend` reads at most $kMaxTrendRuns runs; '
            '${rest.length - 1} were given.',
          );
        }
        return await _trend(rest.first, <String>[
          for (final r in rest.skip(1)) absolutePath(r),
        ]);
    }
  }

  Future<McpDocument> _run(
    ArgResults a,
    String config, {
    required int limit,
    required int? parallel,
    required Future<void>? cancel,
    required void Function(int, int)? onProgress,
  }) async {
    if (FileSystemEntity.typeSync(config) != FileSystemEntityType.file) {
      return _fail(
        kRunCommand,
        McpOutcome.inputError,
        McpDiagnostic.error('input.unreadable', '$config is not a file.'),
      );
    }
    final SimRunExecution execution;
    try {
      execution = await execute(
        SimRunRequest(
          configPath: config,
          filter: a.option('filter'),
          maxParallel: parallel,
          licenseFile: a.option('license-file'),
          cancel: cancel,
          onProgress: onProgress,
        ),
      );
    } on HeadlessLicenseException catch (e) {
      return _fail(
        kRunCommand,
        McpOutcome.licenceError,
        McpDiagnostic.error(
          'licence.unreadable',
          e.message,
          fix: const McpTierGate(environmentVariable: kSimcruxLicenseEnv).fix,
        ),
      );
    } on ConfigLoaderException catch (e) {
      return McpDocument(
        tool: program,
        command: kRunCommand,
        outcome: McpOutcome.inputError,
        diagnostics: <McpDiagnostic>[
          for (final error in e.errors) _configError(error),
        ],
      );
    } on ProjectOutputPathException catch (e) {
      return _fail(
        kRunCommand,
        McpOutcome.inputError,
        McpDiagnostic.error(
          'input.output_path',
          'The config puts its results at ${e.path}, outside the project '
              'directory ${e.projectDir}: ${e.problem}.',
        ),
      );
    } on Object catch (e) {
      return _fail(
        kRunCommand,
        McpOutcome.engineError,
        McpDiagnostic.error('engine.failed', 'The run failed: $e'),
      );
    }
    final result = execution.result;
    final rows = <StreamingResultRow>[
      for (final row in result.rows)
        ?StreamingResultRow.parse(StreamingResultsWriter.encodeRow(row)),
    ];
    final verdict = classify(
      SimRunFacts(
        rows: rows,
        selected: result.run.testIds.toSet().length,
        cancelled: result.cancelled,
      ),
    );
    final body = await runBody(
      configPath: config,
      runId: result.run.id,
      startedAt: result.run.startedAt,
      finishedAt: result.run.finishedAt,
      rows: rows,
      resultsPath: result.resultsPath,
      limit: limit,
      scope: _scope(a),
    );
    return McpDocument(
      tool: program,
      command: kRunCommand,
      outcome: verdict.outcome,
      body: body,
      diagnostics: <McpDiagnostic>[
        ...verdict.diagnostics,
        for (final w in execution.loadWarnings)
          McpDiagnostic.warning('config.warning', w),
      ],
    );
  }

  McpDiagnostic _configError(ConfigLoaderError error) {
    final line = error.line;
    return McpDiagnostic.error(
      'input.config',
      error.message,
      fix: error.message.contains('--allow-project-tooling')
          ? 'Over MCP a project never runs what its file names. If you trust '
                'it, run it from the command line: simcrux --ci <config> '
                '--allow-project-tooling.'
          : null,
      location: line != null && line >= 1 && p.isAbsolute(error.path)
          ? McpSourceLocation(
              file: error.path,
              line: line,
              column: error.column,
            )
          : null,
    );
  }

  Future<McpDocument> _results(
    ArgResults a,
    String path, {
    required int limit,
    required Set<TestStatus>? statuses,
  }) async {
    final read = await SimResultsFile.read(path);
    if (read is McpDiagnostic) {
      return _fail(kResultsCommand, McpOutcome.inputError, read);
    }
    final file = read as SimResultsFile;
    final verdict = classify(
      SimRunFacts(
        rows: file.rows,
        selected: null,
        cancelled: false,
        finished: file.finishedAt != null,
      ),
    );
    final body = await runBody(
      configPath: file.configPath,
      runId: file.runId,
      startedAt: file.startedAt,
      finishedAt: file.finishedAt,
      rows: file.rows,
      resultsPath: path,
      limit: limit,
      scope: _scope(a),
      statuses: statuses,
    );
    return McpDocument(
      tool: program,
      command: kResultsCommand,
      outcome: verdict.outcome,
      body: body,
      diagnostics: <McpDiagnostic>[...verdict.diagnostics, ...file.warnings],
    );
  }

  Future<McpDocument> _test(
    ArgResults a,
    String path,
    String id, {
    required int lines,
  }) async {
    final read = await SimResultsFile.read(path);
    if (read is McpDiagnostic) {
      return _fail(kTestCommand, McpOutcome.inputError, read);
    }
    final file = read as SimResultsFile;
    final matches = file.rows.where((r) => r.testId == id).toList();
    if (matches.isEmpty) {
      return _fail(
        kTestCommand,
        McpOutcome.inputError,
        McpDiagnostic.error(
          'test.not_found',
          'The run in $path has no test `$id`.',
          fix: 'List its tests with simcrux results; an id is suite/test.',
        ),
      );
    }
    final (body, warnings) = await testBody(
      file: file,
      row: matches.last,
      lines: lines,
      scope: _scope(a),
    );
    return McpDocument(
      tool: program,
      command: kTestCommand,
      outcome: McpOutcome.completed,
      body: body,
      diagnostics: <McpDiagnostic>[
        if (matches.length > 1)
          McpDiagnostic.warning(
            'test.repeated',
            'The run holds ${matches.length} rows for `$id`; this is the '
                'last.',
          ),
        ...file.warnings,
        ...warnings,
      ],
    );
  }

  Future<McpDocument> _trend(String id, List<String> paths) async {
    final files = <SimResultsFile>[];
    for (final path in paths) {
      final read = await SimResultsFile.read(path);
      if (read is McpDiagnostic) {
        return _fail(kTrendCommand, McpOutcome.inputError, read);
      }
      files.add(read as SimResultsFile);
    }
    final (history, notRun) = trendHistory(id, files);
    if (history.isEmpty && notRun == 0) {
      return _fail(
        kTrendCommand,
        McpOutcome.inputError,
        McpDiagnostic.error(
          'trend.not_found',
          'None of the ${paths.length} runs has a test `$id`.',
          fix:
              "List a run's tests with simcrux results; an id is "
              'suite/test.',
        ),
      );
    }
    final scorer = trendFlakiness;
    final flakiness = scorer == null ? null : await scorer(history);
    return McpDocument(
      tool: program,
      command: kTrendCommand,
      outcome: McpOutcome.completed,
      body: <String, Object?>{
        'id': id,
        'history': <Object?>[for (final h in history) h.toJson()],
        'flakiness': flakiness,
      },
      diagnostics: <McpDiagnostic>[
        if (notRun > 0)
          McpDiagnostic.warning(
            'trend.not_executed',
            'In $notRun of the ${paths.length} runs the test never ran its '
                'simulator; those runs are left out of the history.',
          ),
        if (scorer == null) withheldFlakiness(),
      ],
    );
  }

  /// The `licence.withheld` warning of a `trend` answered without a
  /// flakiness class.
  static McpDiagnostic withheldFlakiness() {
    final d = const McpTierGate(
      environmentVariable: kSimcruxLicenseEnv,
    ).withhold('The flakiness class', tier: 'Pro');
    return McpDiagnostic.warning(
      d.code,
      d.message,
      fix:
          'SimCrux Pro gives it under a Pro licence; this command line '
          'holds no flakiness scoring.',
    );
  }

  /// A short plain-text form of [document], for a person at a terminal.
  static List<String> describe(McpDocument document) {
    final body = document.body;
    if (body == null) return const <String>[];
    switch (document.command) {
      case kRunCommand || kResultsCommand:
        final run = body['run']! as Map<String, Object?>;
        final totals = body['totals']! as Map<String, Object?>;
        final parts = <String>[
          for (final e in totals.entries)
            if (e.value != 0) '${e.value} ${e.key}',
        ];
        final summary = parts.isEmpty ? 'no results' : parts.join(' · ');
        final outcome = document.outcome.wireName;
        return <String>[
          'simcrux: ${run['total']} tests · $summary · $outcome',
          for (final t
              in (body['tests']! as List<Object?>).cast<Map<String, Object?>>())
            if (kGateFailures.any((s) => s.name == t['status']))
              _failingLine(t),
          if (body['results_path'] != null) 'results: ${body['results_path']}',
        ];
      case kTestCommand:
        final test = body['test']! as Map<String, Object?>;
        final log = body['log'] as Map<String, Object?>?;
        return <String>[
          '${test['id']}: ${test['status']}',
          if (test['failure_message'] != null) '${test['failure_message']}',
          if (log != null) ...<String>[
            '--- ${log['path']} from line ${log['from_line']}',
            ...(log['lines']! as List<Object?>).cast<String>(),
          ],
        ];
      default:
        return <String>[
          for (final h
              in (body['history']! as List<Object?>)
                  .cast<Map<String, Object?>>())
            _historyLine(h),
        ];
    }
  }

  static String _failingLine(Map<String, Object?> t) {
    final message = t['failure_message'];
    return '  ${t['status']}  ${t['id']}${message == null ? '' : '  $message'}';
  }

  static String _historyLine(Map<String, Object?> h) =>
      '${h['started_at']}  ${h['status']}  ${h['runtime_ms']} ms  ${h['run']}';
}
