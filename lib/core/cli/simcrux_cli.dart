// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crux_license/crux_license_core.dart';
import 'package:crux_license/crux_license_headless.dart';
import 'package:crux_mcp/crux_mcp.dart'
    hide CruxTelemetryProduct, HeadlessTelemetry, TelemetryPolicy;
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/core/cli/ci_retention.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/flow_signal_reaper.dart';
import 'package:simcrux/core/cli/license_cli.dart';
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/headless/sim_commands.dart';
import 'package:simcrux/headless/sim_document.dart';
import 'package:simcrux/headless/simcrux_mcp.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/cli/cli_args.dart' as launch_cli;
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/export/dashboard_bundle_writer.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';
import 'package:simcrux/services/flow/nextpnr_flow_driver.dart';
import 'package:simcrux/services/import/formal_import_cli.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/scratch/simcrux_scratch.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/dart_test_driver.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

/// The whole headless `simcrux` command, minus the two things a `lib/`
/// file must not do: read the real `argv` and call `exit`.
///
/// `bin/simcrux.dart` is a few lines around this class — the Flutter-free
/// twin of the desktop `bootstrap()`, mirroring LintCrux's
/// `LintcruxCli` / `bin/lintcrux.dart` split. It exists because an
/// Edalize/CI node must run without a window, a display server, or the
/// Flutter engine: `bootstrap()` calls
/// `WidgetsFlutterBinding.ensureInitialized()` before it reads a single
/// argument, so even its early-return headless branches (`--ci`,
/// `--import-fusesoc`, the RISC-V imports, `export-dashboard`) need
/// `dart:ui` present. This class reaches the same services those
/// branches use — `CiRunner`, `FuseSoCImporter`, `RiscvImportCli`,
/// `DashboardBundleWriter` — through plain constructor wiring instead of
/// a `ProviderContainer`, and its import closure is Flutter-free.
/// `tool/build_cli.sh` proves that by compiling it with `dart build cli`.
///
/// Differences from the desktop `bootstrap()` invocations, both
/// deliberate:
///
/// * **Telemetry never transmits.** The desktop `--ci` path reads the
///   consent the GUI stored and resolves the live service on an
///   affirmative answer; this binary defaults to [NoopTelemetryService]
///   unconditionally. Recording nothing is always consistent with the
///   `--ci` consent rule —
///   silence is never consent — and it keeps `crux_telemetry`'s
///   Flutter-bound half out of the link. A consent-reading headless
///   telemetry (LintCrux's `HeadlessTelemetry` shape) can replace the
///   default later without touching this class's callers.
/// * **Open-core policy objects by default.** A `--fail-on-regression`
///   engine arrives via [failOnRegressionPolicy]; this binary passes
///   [UnavailableFailOnRegressionPolicy], so `--fail-on-regression
///   --baseline` here fails the run with exit code 2 and a stderr line
///   naming the desktop app's executable, as it does in an open-core
///   desktop `--ci` run. The regression gate runs only from the SimCrux
///   desktop app's `--ci`.
///
/// The license tier is shared with the desktop `--ci`: both resolve it with
/// [HeadlessLicenseTierResolver] (`--license-file`, then
/// `SIMCRUX_LICENSE_FILE`, then the organization policy file) and load the
/// project at that tier, so Pro sweeps expand in CI exactly when the license
/// says they should.
class SimcruxCli {
  /// Creates a [SimcruxCli].
  ///
  /// [driverRegistry] defaults to the built-in simulator set (Icarus,
  /// Verilator, GHDL, cocotb, the two RISC-V drivers) sharing one
  /// platform [ProcessReaper]. No plugin registry is attached by
  /// default; the Pro CLI passes a registry that carries its vendor
  /// drivers and the subprocess plugin host.
  ///
  /// [licenseTierResolver] and [configLoaderFactory] are injectable so tests
  /// can supply a license without a signed credential, and a loader with the
  /// beta period off.
  ///
  /// [program] is the `tool` every `--json` document names. [classify] maps
  /// a run to its outcome and is replaced only by the test that proves a
  /// broken mapping is caught. [trendFlakiness] gives `trend` its flakiness
  /// class; without it (open core) the class is withheld and the document
  /// says so. [mcpTelemetry] makes the `mcp` server's counter (`null`
  /// counts nothing). [runSchedulerFactory], [runRoot] and [now] are seams
  /// for the `run` command's tests: the scheduler a run executes on, the
  /// directory its work folders go under (SimCrux scratch unless given), and
  /// its clock. [installSignalHandlers] makes `run` and `mcp` cancel their
  /// runs on SIGINT or SIGTERM; only `bin/simcrux.dart` turns it on, since
  /// the handlers are process-wide.
  SimcruxCli({
    SimulatorDriverRegistry? driverRegistry,
    this.failOnRegressionPolicy = const UnavailableFailOnRegressionPolicy(),
    this.telemetry = const NoopTelemetryService(),
    HeadlessLicenseTierResolver? licenseTierResolver,
    LicenseCli? licenseCli,
    ConfigLoader Function(LicenseTier tier, {required bool allowTooling})?
    configLoaderFactory,
    this.program = const McpProgram(
      name: kSimcruxProgramName,
      version: SimCruxBuildInfo.productVersion,
    ),
    this.classify = classifySimRun,
    this.trendFlakiness,
    McpTelemetry? Function()? mcpTelemetry,
    this.runSchedulerFactory,
    this.runRoot,
    this.now,
    this.installSignalHandlers = false,
  }) : driverRegistry = driverRegistry ?? defaultDriverRegistry(),
       licenseTierResolver =
           licenseTierResolver ??
           HeadlessLicenseTierResolver(product: CruxProduct.simCrux),
       licenseCli = licenseCli ?? LicenseCli(),
       configLoaderFactory = configLoaderFactory ?? _defaultConfigLoader,
       _mcpTelemetry = mcpTelemetry ?? simcruxMcpTelemetry;

  /// The program every `--json` document and the `mcp` server name.
  final McpProgram program;

  /// Maps a run to its outcome.
  final SimRunClassifier classify;

  /// The flakiness class `trend` gives, when this build computes one.
  final SimTrendFlakiness? trendFlakiness;

  final McpTelemetry? Function() _mcpTelemetry;

  /// The scheduler `run` executes on; [ciSchedulerFor] when null.
  final JobScheduler Function(RegressionConfig config)? runSchedulerFactory;

  /// Where `run`'s work folders go; SimCrux scratch when null.
  final String? runRoot;

  /// `run`'s clock; the wall clock when null.
  final DateTime Function()? now;

  /// Whether `run` and `mcp` watch SIGINT and SIGTERM.
  final bool installSignalHandlers;

  /// Simulator drivers available to `--ci` runs.
  final SimulatorDriverRegistry driverRegistry;

  /// The `--fail-on-regression` decision engine. Open-core default is
  /// [UnavailableFailOnRegressionPolicy] (the comparison engine is a Pro
  /// feature): the gate is refused with exit code 2, exactly as it is in
  /// a desktop open-core `--ci` run.
  final FailOnRegressionPolicy failOnRegressionPolicy;

  /// Where run counters go. Defaults to the no-op service — this
  /// binary never transmits telemetry (see the class doc).
  final TelemetryService telemetry;

  /// Resolves the license tier a `--ci` run loads its project at.
  final HeadlessLicenseTierResolver licenseTierResolver;

  /// Handles the `license` sub-command: the install fingerprint and the
  /// offline activation request a dedicated build agent needs to be issued
  /// a machine file without the desktop app.
  final LicenseCli licenseCli;

  /// Builds the project loader for the license tier a `--ci` run resolved.
  final ConfigLoader Function(LicenseTier tier, {required bool allowTooling})
  configLoaderFactory;

  static ConfigLoader _defaultConfigLoader(
    LicenseTier tier, {
    required bool allowTooling,
  }) => ConfigLoader(
    licenseTier: tier,
    // `--allow-project-tooling`. Off unless the user typed it: a project
    // file may not choose what this run executes on its own. See
    // `CliArgs.allowProjectTooling`.
    allowProjectDefinedTooling: allowTooling,
  );

  /// The built-in driver map, mirroring the desktop
  /// `simulatorDriverRegistryProvider` minus the env-gated demo driver
  /// and the plugin registry.
  static SimulatorDriverRegistry defaultDriverRegistry() {
    final reaper = defaultProcessReaper();
    return SimulatorDriverRegistry(<String, SimulatorDriver>{
      'icarus': IcarusDriver(reaper: reaper),
      'verilator': VerilatorDriver(reaper: reaper),
      'ghdl': GhdlDriver(reaper: reaper),
      'cocotb': CocotbDriver(reaper: reaper),
      DartTestDriver.kId: DartTestDriver(reaper: reaper),
      RiscvArchDriver.kId: RiscvArchDriver(reaper: reaper),
      RiscvFormalDriver.kId: RiscvFormalDriver(reaper: reaper),
      SbyDriver.kId: SbyDriver(reaper: reaper),
      EqyDriver.kId: EqyDriver(reaper: reaper),
      LibreLaneFlowDriver.kId: LibreLaneFlowDriver(reaper: reaper),
      NextpnrFlowDriver.kId: NextpnrFlowDriver(reaper: reaper),
    });
  }

  /// Runs the command described by [args] and returns the exit code.
  ///
  /// [stdoutSink] / [stderrSink] receive one call per line. Injected so
  /// tests capture output without touching the real streams.
  ///
  /// Exit codes follow the established SimCrux CLI contract: `0` on
  /// success, `2` on any usage/import/infrastructure error, and
  /// `CiRunner`'s own outcome codes for `--ci` (where `--fail-threshold`
  /// and friends decide). An invocation that selects no headless work —
  /// the desktop app would open a window here — is an error for this
  /// binary: it prints the usage block and exits `2` rather than
  /// silently doing nothing.
  ///
  /// `run`, `results`, `test` and `trend` write one JSON document with
  /// `--json` and exit with the suite's codes for its outcome; `mcp` serves
  /// the four as MCP tools, reading requests from [input] and writing
  /// answers to [output] (the process's stdin and stdout unless given).
  Future<int> run(
    List<String> args, {
    required void Function(String line) stdoutSink,
    required void Function(String line) stderrSink,
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
  }) async {
    if (args.isNotEmpty && args.first == kMcpSubcommand) {
      return await _serve(
        args.sublist(1),
        stdoutSink: stdoutSink,
        stderrSink: stderrSink,
        input: input,
        output: output,
      );
    }
    if (args.isNotEmpty && SimCommands.names.contains(args.first)) {
      return await _command(
        args.first,
        args.sublist(1),
        stdoutSink: stdoutSink,
        stderrSink: stderrSink,
      );
    }
    // Tolerate the suite-shared launch recovery flags (`--reset` /
    // `--no-restore`) the way `bootstrap()` does: strip them before the
    // strict parser, so a shell alias shared between the app and the
    // binary keeps working. They are GUI-session concerns and have
    // nothing to reset here.
    final isSubcommand = CliArgParser.startsWithSubcommand(args);
    final launchArgs = isSubcommand ? args : launch_cli.stripLaunchFlags(args);

    final CliArgs parsedArgs;
    try {
      final parsed = CliArgParser().parse(launchArgs);
      if (parsed is HelpCliArgs) {
        stdoutSink(kCommandsUsage);
        stdoutSink(CliArgParser().usage);
        return 0;
      }
      if (parsed is VersionCliArgs) {
        // `<tool> <semver>`, as every headless tool in the suite prints it.
        stdoutSink('simcrux ${SimCruxBuildInfo.productVersion}');
        return 0;
      }
      parsedArgs = parsed;
    } on CliArgsException catch (e) {
      stderrSink('$e');
      return 2;
    }

    final importPath = parsedArgs.importFusesoc;
    if (importPath != null && importPath.isNotEmpty) {
      return await _runFusesocImport(importPath, stdoutSink, stderrSink);
    }

    final importKind = RiscvImportKind.fromSubcommand(parsedArgs.subcommand);
    if (importKind != null) {
      return await _runRiscvImport(
        importKind,
        parsedArgs.subcommandArgs,
        stdoutSink,
        stderrSink,
      );
    }

    final formalKind = FormalImportKind.fromSubcommand(parsedArgs.subcommand);
    if (formalKind != null) {
      return await runFormalImport(
        formalKind,
        parsedArgs.subcommandArgs,
        stdoutSink: stdoutSink,
        stderrSink: stderrSink,
      );
    }

    if (parsedArgs.subcommand == CliArgParser.kExportDashboardSubcommand) {
      return await _runExportDashboard(
        parsedArgs.subcommandArgs,
        stdoutSink,
        stderrSink,
      );
    }

    if (parsedArgs.subcommand == CliArgParser.kFlowSubcommand) {
      return await FlowCli(
        stdoutSink: stdoutSink,
        stderrSink: stderrSink,
        driverRegistry: driverRegistry,
      ).run(parsedArgs.subcommandArgs);
    }

    if (parsedArgs.subcommand == CliArgParser.kLicenseSubcommand) {
      return await _runLicense(
        parsedArgs.subcommandArgs,
        stdoutSink,
        stderrSink,
      );
    }

    if (parsedArgs.ciMode && parsedArgs.hasProject) {
      return await _runCi(parsedArgs, stdoutSink, stderrSink);
    }

    // Everything else is a GUI invocation — a positional project without
    // `--ci`, or no arguments at all. The desktop app opens a window
    // for these; this binary cannot, and pretending the run happened
    // would be the silent-false-clean failure mode.
    stderrSink(
      'simcrux: nothing to do headless: pass --ci <config>, '
      '--import-fusesoc, import-riscv-arch-test, import-riscv-formal, '
      'import-sby, import-eqy, export-dashboard, license, flow, run, '
      'results, test, trend, or mcp. The '
      'graphical workflows '
      'need the SimCrux desktop app.',
    );
    stderrSink('');
    stderrSink(kCommandsUsage);
    stderrSink(CliArgParser().usage);
    return 2;
  }

  Future<int> _runFusesocImport(
    String importPath,
    void Function(String line) stdoutSink,
    void Function(String line) stderrSink,
  ) async {
    try {
      final result = await FuseSoCImporter().importFile(importPath);
      final outPath = p.join(
        File(importPath).parent.path,
        result.suggestedOutputFilename,
      );
      await File(outPath).writeAsString(result.simcruxYaml);
      stdoutSink('simcrux: wrote $outPath');
      for (final w in result.warnings) {
        stdoutSink('simcrux: [${w.code}] ${w.message}');
      }
      return 0;
    } on FuseSoCImportException catch (e) {
      stderrSink('simcrux: $e');
      return 2;
    } on Object catch (e) {
      stderrSink('simcrux: import-fusesoc failed: $e');
      return 2;
    }
  }

  Future<int> _runRiscvImport(
    RiscvImportKind importKind,
    List<String> subcommandArgs,
    void Function(String line) stdoutSink,
    void Function(String line) stderrSink,
  ) async {
    try {
      await RiscvImportCli(stdoutWriter: stdoutSink).run(
        importKind,
        subcommandArgs,
      );
      return 0;
    } on RiscvImportCliException catch (e) {
      stderrSink('$e');
      return 2;
    } on RiscvImportException catch (e) {
      stderrSink('simcrux: $e');
      return 2;
    } on Object catch (e) {
      stderrSink('simcrux ${importKind.subcommand}: $e');
      return 2;
    }
  }

  /// Runs `simcrux import-sby` or `simcrux import-eqy` and returns its exit
  /// code: 0 when the file
  /// was written or help was shown, 2 for a usage error or an input with
  /// nothing to import (the `import-*` family's grandfathered code).
  ///
  /// Shared by this binary and the desktop app's headless branch, so the
  /// two cannot answer the same command line differently.
  static Future<int> runFormalImport(
    FormalImportKind kind,
    List<String> subcommandArgs, {
    required void Function(String line) stdoutSink,
    required void Function(String line) stderrSink,
  }) async {
    try {
      await FormalImportCli(
        stdoutWriter: stdoutSink,
        stderrWriter: stderrSink,
      ).run(kind, subcommandArgs);
      return 0;
    } on FormalImportCliException catch (e) {
      stderrSink('$e');
      return 2;
    } on FormalImportException catch (e) {
      stderrSink('simcrux ${kind.subcommand}: $e');
      return 2;
    } on Object catch (e) {
      stderrSink('simcrux ${kind.subcommand}: $e');
      return 2;
    }
  }

  Future<int> _runExportDashboard(
    List<String> subcommandArgs,
    void Function(String line) stdoutSink,
    void Function(String line) stderrSink,
  ) async {
    try {
      await DashboardBundleWriter(
        stdoutWriter: stdoutSink,
        telemetry: telemetry,
      ).run(subcommandArgs);
      return 0;
    } on DashboardBundleException catch (e) {
      stderrSink('$e');
      return 2;
    } on Object catch (e) {
      stderrSink('simcrux export-dashboard: $e');
      return 2;
    }
  }

  Future<int> _runLicense(
    List<String> subcommandArgs,
    void Function(String line) stdoutSink,
    void Function(String line) stderrSink,
  ) async {
    try {
      await licenseCli.run(subcommandArgs, stdoutWriter: stdoutSink);
      return 0;
    } on LicenseCliException catch (e) {
      stderrSink('$e');
      return 2;
    } on Object catch (e) {
      stderrSink('simcrux license: $e');
      return 2;
    }
  }

  /// The scheduler a `--ci` run of [config] executes on.
  ///
  /// Dump retention is bounded, as in the app: an unbounded policy never
  /// prunes failing tests' work dirs, which fills a long-lived CI runner's
  /// temp directory. [retention] is what `--keep-failures` built; the run's
  /// own failure folders are never pruned whatever it says.
  LocalJobScheduler ciSchedulerFor(
    RegressionConfig config, {
    DumpRetentionPolicy retention = DumpRetentionPolicy.defaultPolicy,
  }) => LocalJobScheduler(
    driverRegistry: driverRegistry,
    config: config,
    dumpRetentionPolicy: retention,
  );

  Future<int> _runCi(
    CliArgs parsedArgs,
    void Function(String line) stdoutSink,
    void Function(String line) stderrSink,
  ) async {
    final LicenseTier tier;
    try {
      final resolution = await licenseTierResolver.resolve(
        licenseFilePath: parsedArgs.licenseFile,
      );
      resolution.notes.map((note) => 'simcrux: $note').forEach(stderrSink);
      tier = resolution.tier;
    } on HeadlessLicenseException catch (e) {
      stderrSink('simcrux: error: $e');
      return 2;
    }
    final retention = ciDumpRetentionPolicy(
      keepFailures: parsedArgs.keepFailures,
      log: stderrSink,
    );
    final runner = CiRunner(
      configLoader: configLoaderFactory(
        tier,
        allowTooling: parsedArgs.allowProjectTooling,
      ),
      schedulerFactory: (config) =>
          ciSchedulerFor(config, retention: retention),
      exporterRegistry: const ExporterRegistry(),
      stdoutWriter: stdoutSink,
      stderrWriter: stderrSink,
      failOnRegressionPolicy: failOnRegressionPolicy,
      licenseTier: tier,
      telemetry: telemetry,
    );
    try {
      final outcome = await runner.run(args: parsedArgs);
      return outcome.exitCode;
    } on Object catch (e) {
      stderrSink('simcrux: $e');
      return 2;
    }
  }

  // ── run, results, test, trend, mcp ────────────────────────────────

  /// The word that starts the MCP server.
  static const String kMcpSubcommand = 'mcp';

  /// The lines `--help` and the "nothing to do" error print above the option
  /// list: the usage line, then every command with one line of what it does.
  /// A test holds it to every command `run` dispatches on.
  static const String kCommandsUsage =
      'Usage: simcrux <command> [options]\n'
      '       simcrux --ci <project> [options]\n'
      '\n'
      'Commands (each takes --help):\n'
      '  run <simcrux.yaml>                 run a regression, each test '
      'described\n'
      '  results <results.ndjson>           the results of a run\n'
      '  test <results.ndjson> <suite/test> one test, its log and seed\n'
      "  trend <suite/test> <results.ndjson>... a test's history\n"
      '  mcp [--root <dir>]                 serve the four as MCP tools on '
      'stdio\n'
      '  import-sby <file.sby|dir>          write a project from SymbiYosys '
      'files\n'
      '  import-eqy <file.eqy>              write a project from an EQY file\n'
      '  import-riscv-arch-test <suite>     write a project from a RISC-V '
      'architectural test suite\n'
      '  import-riscv-formal <checks>       write a project from riscv-formal '
      'checks\n'
      '  export-dashboard <dir>             write the results dashboard as '
      'static files\n'
      '  license                            the install fingerprint and an '
      'offline activation request\n'
      '  flow                               run, ingest, gate and export '
      'implementation flows\n'
      '\n'
      'run, results, test and trend write one JSON document with --json.\n'
      '\n'
      'Options:';

  /// SimCrux's own `runs/` folder, where `run` keeps failing tests' work
  /// folders.
  String scratchRuns() => p.join(runRoot ?? SimcruxScratch.jobs(), 'runs');

  /// The four commands, running regressions through [executeRun] with
  /// [log] for what a run says on the way.
  SimCommands commands({required void Function(String line) log}) =>
      SimCommands(
        program: program,
        classify: classify,
        trendFlakiness: trendFlakiness,
        scratchRuns: scratchRuns,
        execute: (request) => executeRun(request, log: log),
      );

  /// Runs [request] the way `--ci` runs a project: the licence tier from
  /// the same resolver, the project loaded at it with project tooling off,
  /// the same `CiRunner` and scheduler. No export, and no telemetry but the
  /// server's own `mcp.tool_call`. [log] gets what `--ci` prints on stderr.
  Future<SimRunExecution> executeRun(
    SimRunRequest request, {
    required void Function(String line) log,
  }) async {
    final resolution = await licenseTierResolver.resolve(
      licenseFilePath: request.licenseFile,
    );
    resolution.notes.map((note) => 'simcrux: $note').forEach(log);
    final tier = resolution.tier;
    final loader = configLoaderFactory(tier, allowTooling: false);
    final config = await loader.load(request.configPath);
    final retention = ciDumpRetentionPolicy(keepFailures: null, log: log);
    final runner = CiRunner(
      configLoader: loader,
      schedulerFactory:
          runSchedulerFactory ??
          (config) => LocalJobScheduler(
            driverRegistry: driverRegistry,
            config: config,
            runRoot: runRoot,
            dumpRetentionPolicy: retention,
          ),
      exporterRegistry: const ExporterRegistry(),
      stdoutWriter: log,
      stderrWriter: log,
      licenseTier: tier,
      now: now,
    );
    final result = await runner.run(
      args: CliArgs(
        projectPaths: <String>[request.configPath],
        filter: request.filter,
        maxParallel: request.maxParallel,
        ciMode: true,
      ),
      config: config,
      cancel: request.cancel,
      onProgress: request.onProgress,
    );
    return (
      result: result,
      loadWarnings: <String>[for (final w in config.loadWarnings) w.format()],
    );
  }

  /// Writes [document] as the whole of stdout: [McpDocument.render] ends in
  /// the newline [sink] adds.
  static void _writeDocument(void Function(String) sink, McpDocument document) {
    final text = document.render();
    sink(text.substring(0, text.length - 1));
  }

  Future<int> _command(
    String name,
    List<String> args, {
    required void Function(String line) stdoutSink,
    required void Function(String line) stderrSink,
  }) async {
    if (args.contains('--help') || args.contains('-h')) {
      stdoutSink(SimCommands.usageOf(name));
      stdoutSink(SimCommands.parserFor(name).usage);
      return 0;
    }
    final stop = Completer<void>();
    final reaper = installSignalHandlers && name == kRunCommand
        ? (FlowSignalReaper()..install((_) {
            if (!stop.isCompleted) stop.complete();
          }))
        : null;
    final McpDocument document;
    try {
      document = await commands(
        log: stderrSink,
      ).document(name, args, cancel: stop.future);
    } finally {
      await reaper?.dispose();
    }
    if (args.contains('--json')) {
      _writeDocument(stdoutSink, document);
    } else {
      SimCommands.describe(document).forEach(stdoutSink);
    }
    for (final d in document.diagnostics) {
      stderrSink('simcrux $name: ${d.severity.name}: ${d.message}');
    }
    return reaper?.exitCode ?? McpExitCodes.suite.exitCodeFor(document.outcome);
  }

  /// The MCP server over `run`, `results`, `test` and `trend`, its paths
  /// held inside [root]. Every call runs the command line the tool's fields
  /// make, plus `--root` (so a log is read only inside the root or SimCrux
  /// scratch) and, for `run`, the server's [licenseFile]; [stop] cancels
  /// every run in flight.
  McpServer server({
    required String root,
    String? licenseFile,
    McpTelemetry? telemetry,
    void Function(String line)? log,
    Future<void>? stop,
  }) {
    final sink = log ?? (String line) => stderr.writeln(line);
    final confinement = Confinement(root);
    return McpServer(
      program: program,
      instructions: kSimcruxMcpInstructions,
      tools: kSimcruxMcpTools,
      confinement: confinement,
      telemetry: telemetry,
      log: log,
      runner: (call) async => McpCommandOutput.document(
        await toolDocument(
          call,
          root: confinement.root,
          licenseFile: licenseFile,
          log: sink,
          stop: stop,
        ),
      ),
    );
  }

  /// The document a call of `run`, `results`, `test` or `trend` answers:
  /// the command line the tool's fields make, plus `--root` [root] and, for
  /// `run`, the server's [licenseFile], run through [commands]. [stop]
  /// cancels a run in flight, as the call's own cancellation does.
  Future<McpDocument> toolDocument(
    McpCall call, {
    required String root,
    required void Function(String line) log,
    String? licenseFile,
    Future<void>? stop,
  }) async {
    final name = call.tool.command;
    final cancel = stop == null
        ? call.whenCancelled
        : Future.any(<Future<void>>[call.whenCancelled, stop]);
    return await commands(log: log).document(
      name,
      <String>[
        ...call.arguments.argv,
        '--root',
        root,
        if (name == kRunCommand && licenseFile != null) ...<String>[
          '--license-file',
          licenseFile,
        ],
        '--json',
      ],
      cancel: cancel,
      onProgress: (finished, submitted) =>
          call.progress(finished, total: submitted),
    );
  }

  Future<int> _serve(
    List<String> args, {
    required void Function(String line) stdoutSink,
    required void Function(String line) stderrSink,
    Stream<List<int>>? input,
    StreamSink<List<int>>? output,
  }) async {
    final parser = ArgParser()
      ..addOption(
        'root',
        help: 'Every path a tool receives must be inside it.',
        valueHelp: 'dir',
        defaultsTo: Directory.current.path,
      )
      ..addOption(
        'license-file',
        valueHelp: 'path',
        help:
            'A SimCrux licence file for run, read as --ci reads it. The '
            'four tools of this binary are free.',
      )
      ..addFlag('help', abbr: 'h', negatable: false, help: 'This text.');
    final ArgResults parsed;
    try {
      parsed = parser.parse(args);
    } on FormatException catch (e) {
      stderrSink('simcrux mcp: ${e.message}');
      stderrSink(parser.usage);
      return McpExitCodes.suite.usageError;
    }
    if (parsed.flag('help')) {
      stdoutSink(
        'Serve run, results, test and trend as MCP tools: newline-delimited '
        'JSON-RPC on stdin and stdout.\n\n'
        'Usage: simcrux mcp [--root <dir>] [--license-file <path>]',
      );
      stdoutSink(parser.usage);
      return 0;
    }
    if (parsed.rest.isNotEmpty) {
      stderrSink('simcrux mcp: unexpected `${parsed.rest.first}`');
      return McpExitCodes.suite.usageError;
    }
    final stop = Completer<void>();
    final server = this.server(
      root: parsed.option('root')!,
      licenseFile: parsed.option('license-file'),
      telemetry: _mcpTelemetry(),
      log: stderrSink,
      stop: stop.future,
    );
    final problem = server.confinement.rootProblem();
    if (problem != null) {
      stderrSink('simcrux mcp: $problem');
      return McpExitCodes.suite.usageError;
    }
    // A signal cancels every run in flight (killing its simulators), and
    // the binary exits with the signal's code once they have stopped.
    final reaper = installSignalHandlers
        ? (FlowSignalReaper()..install((_) {
            if (!stop.isCompleted) stop.complete();
          }))
        : null;
    try {
      await Future.any(<Future<void>>[
        server.serve(input ?? stdin, output ?? stdout),
        stop.future.then(
          (_) => Future<void>.delayed(const Duration(seconds: 10)),
        ),
      ]);
    } finally {
      await reaper?.dispose();
    }
    return reaper?.exitCode ?? 0;
  }
}
