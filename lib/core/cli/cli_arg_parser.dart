// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:args/args.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/services/export/result_exporter.dart';

/// The `--export` format ids, in `ExportFormat` order, for help and errors.
final String _exportFormatIds = ExportFormat.values.map((f) => f.id).join(', ');

/// Thrown by [CliArgParser.parse] when the user passes arguments the
/// parser cannot interpret. Carries the usage block so the caller can
/// print `'$exception'` directly to stderr and exit non-zero.
class CliArgsException implements Exception {
  /// Creates a [CliArgsException].
  CliArgsException(this.message, this.usage);

  /// Human-readable description of what went wrong.
  final String message;

  /// The usage block (as produced by [ArgParser.usage]).
  final String usage;

  @override
  String toString() => 'simcrux: $message\n\n$usage';
}

/// Pure-Dart parser that turns `main(args)` into a [CliArgs].
class CliArgParser {
  /// Creates a [CliArgParser].
  CliArgParser() {
    _parser = ArgParser()
      ..addOption(
        'filter',
        abbr: 'f',
        help:
            'In --ci mode, run only tests whose id (suite/test) contains '
            'this literal substring (not a glob); others are skipped.',
        valueHelp: 'pattern',
      )
      ..addOption(
        'max-parallel',
        abbr: 'j',
        help:
            'In --ci mode, the maximum number of tests to run '
            'concurrently (default 4). The app always runs 4.',
        valueHelp: 'n',
      )
      ..addFlag(
        'json',
        help:
            'Print the results as one JSON document on stdout, and nothing '
            'else there: export confirmations, warnings and errors go to '
            'stderr. Implies --ci.',
        negatable: false,
      )
      ..addFlag(
        'ci',
        help:
            'Run non-interactively. Process exit code reflects the '
            'regression outcome (0 = all passed, non-zero otherwise).',
        negatable: false,
      )
      ..addMultiOption(
        'export',
        help:
            'Write results to <path> in the given format: '
            '$_exportFormatIds. May be supplied multiple times. An unknown '
            'format is a usage error. Examples: '
            '--export junit=report.xml --export html=dashboard.html',
        valueHelp: 'format=path',
      )
      ..addOption(
        'fail-threshold',
        help:
            'In --ci mode, exit non-zero when the number of failed '
            'tests >= <n>. Defaults to 1 (any failure fails the run).',
        valueHelp: 'n',
        defaultsTo: '1',
      )
      ..addOption(
        'session',
        help:
            'Desktop app only; --ci ignores it. Opens <path> in one more '
            'tab, loaded as a project file. No session state is restored: '
            'the .simcrux-session format is not read, so pass the project '
            'file the session was saved from.',
        valueHelp: 'path',
      )
      ..addOption(
        'workspace',
        help:
            'Path to a .simcrux-workspace document to load before '
            'opening any positional configs as additional tabs.',
        valueHelp: 'path',
      )
      ..addOption(
        'import-fusesoc',
        help:
            'Read the given CAPI2 .core file and write a '
            'simcrux.yaml next to it. Prints the output path and any '
            'warnings to stdout and exits without launching the UI or '
            'starting a regression.',
        valueHelp: 'core-file',
      )
      ..addFlag(
        'fail-on-regression',
        help:
            'In --ci mode, exit non-zero when the completed run '
            'regresses relative to the baseline supplied via '
            '--baseline. Open-core builds always succeed (the '
            'regression comparison engine is a Pro feature). The Pro '
            'build runs the engine and exits with code 1 by default '
            'on regression — override via SIMCRUX_REGRESSION_EXIT_CODE '
            'env var when your CI system requires a specific code — '
            'and exits 2 when the --baseline file is missing, unreadable '
            'or empty.',
        negatable: false,
      )
      ..addFlag(
        'fail-on-vacuous',
        help:
            'Count tests classified `vacuous` (the testbench '
            'completed without exercising its checks) as failures for '
            'the --fail-threshold gate. Off by default so existing '
            'pipelines keep their current exit codes; turn it on for '
            'nightly gates that must not pass on an unexercised '
            'testbench. Tests classified `unknown` always count as '
            'failures and are unaffected by this flag.',
        negatable: false,
      )
      ..addOption(
        'baseline',
        help:
            'Path to a results.ndjson snapshot from a prior --ci '
            'run (with streaming enabled). Used as the comparison '
            'baseline by --fail-on-regression. When --fail-on-regression '
            'is set without --baseline, the CI runner emits a warning '
            'and proceeds with exitCode=0.',
        valueHelp: 'path',
      )
      ..addOption(
        'license-file',
        help:
            'In --ci mode, a SimCrux license file to run under (validated '
            'offline). Without it, --ci reads SIMCRUX_LICENSE_FILE, then '
            'the license in the organization policy file; otherwise it '
            'runs as Open Core. An unreadable file exits 2.',
        valueHelp: 'path',
      )
      ..addFlag(
        'reset-telemetry-consent',
        help:
            "Testing aid. Forget this installation's telemetry answer so "
            'the one-time first-launch disclosure appears again. The '
            'installation ID is kept. The desktop app forgets the answer '
            'at startup whatever else is on the command line, --ci '
            'included; the standalone simcrux binary accepts the flag and '
            'does nothing with it. The dialog only appears at all on a '
            'build where telemetry is live '
            '(--dart-define=TELEMETRY_DEV=true, or BETA_PERIOD=false).',
        negatable: false,
      )
      ..addFlag(
        'reset-eula',
        help:
            "Testing aid. Forget this installation's acceptance of the "
            'licence agreement so it is presented again at launch. The '
            'desktop app forgets the acceptance at startup whatever else is '
            'on the command line, --ci included; the standalone simcrux '
            'binary accepts the flag and does nothing with it. With '
            '--reset-telemetry-consent, the agreement comes first.',
        negatable: false,
      )
      ..addFlag(
        'allow-project-tooling',
        help:
            "Honor the project file's tooling keys: simulators.<id>.path "
            'and .env; the riscv target/riscof/compile/formal command '
            'lists; and riscv reference.path, toolchain.path and .prefix, '
            'riscof.binary and formal.sby_binary. Each chooses what this '
            'run executes or its environment, so without this flag a '
            'command fails the load and the rest are ignored with a '
            'warning. Pass it only for project files you trust. The app '
            'has the same decision in Settings > Simulators.',
        negatable: false,
      )
      ..addFlag(
        'help',
        abbr: 'h',
        help: 'Show this usage and exit.',
        negatable: false,
      );
  }

  late final ArgParser _parser;

  /// Multi-line usage block for `--help`. Stable across phases — UI
  /// authors compose this with a header/footer for the in-app help.
  String get usage => _parser.usage;

  /// Stable id of the `export-dashboard` sub-command.
  static const String kExportDashboardSubcommand = 'export-dashboard';

  /// Every sub-command word this parser recognizes.
  ///
  /// A sub-command owns its own `ArgParser` (`DashboardBundleWriter` for
  /// `export-dashboard`, `RiscvImportCli` for the two RISC-V imports), so
  /// the words are matched *before* the primary option parser runs and
  /// everything after one is forwarded verbatim.
  static List<String> get kSubcommands => <String>[
    kExportDashboardSubcommand,
    ...RiscvImportKind.subcommands,
  ];

  /// Whether [args] opens with a sub-command word.
  ///
  /// The bootstrap consults this before stripping the suite-shared launch
  /// recovery flags, because a sub-command's arguments are its own and must
  /// not be pre-chewed by a parser that does not know them.
  static bool startsWithSubcommand(List<String> args) =>
      args.isNotEmpty && kSubcommands.contains(args.first);

  /// Parses [args] into a [CliArgs]. Throws [CliArgsException] when
  /// the arguments are malformed or when an option value cannot be
  /// coerced (e.g. `--max-parallel notANumber`).
  CliArgs parse(List<String> args) {
    // Sub-commands come *before* the option parser because args
    // following the sub-command word are forwarded verbatim to that
    // sub-command's handler (e.g. `simcrux export-dashboard ./out`,
    // `simcrux import-riscv-arch-test ~/riscv-arch-test --extensions I,M`).
    if (startsWithSubcommand(args)) {
      return CliArgs(
        subcommand: args.first,
        subcommandArgs: List<String>.unmodifiable(args.skip(1)),
      );
    }
    final ArgResults results;
    try {
      results = _parser.parse(args);
    } on FormatException catch (e) {
      throw CliArgsException(e.message, _parser.usage);
    }

    if (results.flag('help')) {
      return const _HelpCliArgs();
    }

    final positional = results.rest;
    // Any number of positional `simcrux.yaml` configs
    // is permitted; each one opens as a tab under the workspace
    // shell. The CI mode is single-project — it picks the first
    // positional via CliArgs.projectPath.

    int? maxParallel;
    final maxParallelStr = results.option('max-parallel');
    if (maxParallelStr != null) {
      final parsed = int.tryParse(maxParallelStr);
      if (parsed == null || parsed <= 0) {
        throw CliArgsException(
          '--max-parallel expects a positive integer, got '
          '"$maxParallelStr".',
          _parser.usage,
        );
      }
      maxParallel = parsed;
    }

    final exportTargets = <CliExportTarget>[];
    final rawTargets =
        (results['export'] as List<dynamic>?)?.cast<String>() ?? const [];
    for (final raw in rawTargets) {
      final eq = raw.indexOf('=');
      if (eq <= 0 || eq == raw.length - 1) {
        throw CliArgsException(
          '--export expects <format>=<path>, got "$raw".',
          _parser.usage,
        );
      }
      final formatId = raw.substring(0, eq).trim();
      // Refused here, before an hours-long regression, rather than skipped
      // after it: a skipped report used to leave a green job with the file
      // missing.
      if (ExportFormat.fromId(formatId) == null) {
        throw CliArgsException(
          '--export: unknown format "$formatId" in "$raw". Valid formats: '
          '$_exportFormatIds.',
          _parser.usage,
        );
      }
      exportTargets.add(
        CliExportTarget(
          formatId: formatId,
          outputPath: raw.substring(eq + 1).trim(),
        ),
      );
    }

    final thresholdStr = results.option('fail-threshold');
    final threshold = int.tryParse(thresholdStr ?? '1');
    if (threshold == null || threshold < 0) {
      throw CliArgsException(
        '--fail-threshold expects a non-negative integer, got '
        '"$thresholdStr".',
        _parser.usage,
      );
    }

    final jsonOutput = results.flag('json');
    final ciMode = results.flag('ci') || jsonOutput;

    return CliArgs(
      projectPaths: List<String>.unmodifiable(positional),
      filter: results.option('filter'),
      maxParallel: maxParallel,
      jsonOutput: jsonOutput,
      ciMode: ciMode,
      exportTargets: List<CliExportTarget>.unmodifiable(exportTargets),
      failThreshold: threshold,
      sessionPath: results.option('session'),
      workspacePath: results.option('workspace'),
      importFusesoc: results.option('import-fusesoc'),
      failOnRegression: results.flag('fail-on-regression'),
      failOnVacuous: results.flag('fail-on-vacuous'),
      allowProjectTooling: results.flag('allow-project-tooling'),
      baselineRunPath: results.option('baseline'),
      licenseFile: results.option('license-file'),
    );
  }
}

/// Sentinel subclass returned by [CliArgParser.parse] when the user
/// passed `--help`. Carries no project state. The bootstrap checks
/// `args is HelpCliArgs` to print the usage block and exit cleanly.
class _HelpCliArgs extends CliArgs implements HelpCliArgs {
  const _HelpCliArgs();
}

/// Marker interface that the bootstrap checks via `args is HelpCliArgs`.
abstract class HelpCliArgs implements CliArgs {}
