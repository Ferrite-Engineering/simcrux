// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/telemetry/crux_telemetry_headless.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/cli/cli_args.dart' as launch_cli;
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/export/dashboard_bundle_writer.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
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
///   engine arrives via [failOnRegressionPolicy]; this binary passes the
///   no-op, so the flag is inert here, as it is in an open-core desktop
///   `--ci` run. The regression gate runs only from the SimCrux Pro desktop
///   app's `--ci`.
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
  SimcruxCli({
    SimulatorDriverRegistry? driverRegistry,
    this.failOnRegressionPolicy = const NoopFailOnRegressionPolicy(),
    this.telemetry = const NoopTelemetryService(),
    HeadlessLicenseTierResolver? licenseTierResolver,
    ConfigLoader Function(LicenseTier tier, {required bool allowTooling})?
    configLoaderFactory,
  }) : driverRegistry = driverRegistry ?? defaultDriverRegistry(),
       licenseTierResolver =
           licenseTierResolver ?? HeadlessLicenseTierResolver(),
       configLoaderFactory = configLoaderFactory ?? _defaultConfigLoader;

  /// Simulator drivers available to `--ci` runs.
  final SimulatorDriverRegistry driverRegistry;

  /// The `--fail-on-regression` decision engine. Open-core default is
  /// the no-op (the comparison engine is a Pro feature); the flag is
  /// then inert, exactly as it is in a desktop open-core `--ci` run.
  final FailOnRegressionPolicy failOnRegressionPolicy;

  /// Where run counters go. Defaults to the no-op service — this
  /// binary never transmits telemetry (see the class doc).
  final TelemetryService telemetry;

  /// Resolves the license tier a `--ci` run loads its project at.
  final HeadlessLicenseTierResolver licenseTierResolver;

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
      RiscvArchDriver.kId: RiscvArchDriver(reaper: reaper),
      RiscvFormalDriver.kId: RiscvFormalDriver(reaper: reaper),
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
  Future<int> run(
    List<String> args, {
    required void Function(String line) stdoutSink,
    required void Function(String line) stderrSink,
  }) async {
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
        stdoutSink(CliArgParser().usage);
        return 0;
      }
      parsedArgs = parsed;
    } on CliArgsException catch (e) {
      stderrSink('$e');
      return 2;
    }

    final importPath = parsedArgs.importFusesoc;
    if (importPath != null && importPath.isNotEmpty) {
      return _runFusesocImport(importPath, stdoutSink, stderrSink);
    }

    final importKind = RiscvImportKind.fromSubcommand(parsedArgs.subcommand);
    if (importKind != null) {
      return _runRiscvImport(
        importKind,
        parsedArgs.subcommandArgs,
        stdoutSink,
        stderrSink,
      );
    }

    if (parsedArgs.subcommand == CliArgParser.kExportDashboardSubcommand) {
      return _runExportDashboard(
        parsedArgs.subcommandArgs,
        stdoutSink,
        stderrSink,
      );
    }

    if (parsedArgs.ciMode && parsedArgs.hasProject) {
      return _runCi(parsedArgs, stdoutSink, stderrSink);
    }

    // Everything else is a GUI invocation — a positional project without
    // `--ci`, or no arguments at all. The desktop app opens a window
    // for these; this binary cannot, and pretending the run happened
    // would be the silent-false-clean failure mode.
    stderrSink(
      'simcrux: nothing to do headless — pass --ci <config>, '
      '--import-fusesoc, import-riscv-arch-test, import-riscv-formal, '
      'or export-dashboard. The graphical workflows need the SimCrux '
      'desktop app.',
    );
    stderrSink('');
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

  /// The scheduler a `--ci` run of [config] executes on.
  ///
  /// Dump retention is bounded, as in the app: an unbounded policy never
  /// prunes failing tests' work dirs, which fills a long-lived CI runner's
  /// temp directory.
  LocalJobScheduler ciSchedulerFor(RegressionConfig config) =>
      LocalJobScheduler(
        driverRegistry: driverRegistry,
        config: config,
        dumpRetentionPolicy: DumpRetentionPolicy.defaultPolicy,
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
    final runner = CiRunner(
      configLoader: configLoaderFactory(
        tier,
        allowTooling: parsedArgs.allowProjectTooling,
      ),
      schedulerFactory: ciSchedulerFor,
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
}
