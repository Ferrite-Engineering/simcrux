// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// A single `--export <format>=<path>` export target on the CLI.
@immutable
class CliExportTarget {
  /// Creates a [CliExportTarget].
  const CliExportTarget({required this.formatId, required this.outputPath});

  /// Stable [ExportFormat.id] (e.g. `junit`, `json`, `csv`, `html`).
  final String formatId;

  /// Absolute or relative path to write the rendered output to.
  final String outputPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CliExportTarget &&
          other.formatId == formatId &&
          other.outputPath == outputPath;

  @override
  int get hashCode => Object.hash(formatId, outputPath);

  @override
  String toString() => 'CliExportTarget($formatId → $outputPath)';
}

/// Parsed, validated CLI arguments from the SimCrux entry point.
///
/// Produced by [CliArgParser.parse] from `main(args)` and consumed by
/// the app bootstrap (`lib/app.dart`) via [cliArgsProvider]. The
/// shape is incremental:
///
/// ```text
/// simcrux [config.yaml ...] [--filter <pattern>] [--max-parallel <n>]
///         [--json] [--ci] [--export <fmt>=<path>]…
///         [--fail-threshold <count>] [--session <path>]
///         [--workspace <path>]
///
/// simcrux export-dashboard <out-dir>
///         [--results <path>] [--web-bundle <dir>]
///
/// simcrux import-riscv-arch-test <suite-path>
///         [--out <path>] [--extensions I,M] [--target-command <cmd>] …
///
/// simcrux import-riscv-formal <checks-path>
///         [--out <path>] [--groups insn,reg] …
/// ```
///
/// Multiple positional config arguments open one tab per file under
/// the workspace shell. `--workspace <path>` loads a
/// named `.simcrux-workspace` document before the CLI tabs are
/// appended. `--session <path>` opens one more tab on `<path>`, loaded as
/// a project file: the `.simcrux-session` format itself is not read, so
/// no session state is restored.
///
/// Every sub-command's arguments are forwarded to it verbatim (its own
/// `ArgParser` owns them); the option grammar above applies only to the
/// default form. [CliArgParser.kSubcommands] is the recognized set.
///
/// Out of scope for the current phase:
///
/// - `simcrux watch` (a later sub-command).
/// - Suite-level `--suite` and `--test` filters with a richer grammar.
@immutable
class CliArgs {
  /// Creates a [CliArgs].
  const CliArgs({
    this.projectPaths = const <String>[],
    this.filter,
    this.maxParallel,
    this.jsonOutput = false,
    this.ciMode = false,
    this.exportTargets = const <CliExportTarget>[],
    this.failThreshold = 1,
    this.sessionPath,
    this.workspacePath,
    this.subcommand,
    this.subcommandArgs = const <String>[],
    this.importFusesoc,
    this.failOnRegression = false,
    this.failOnVacuous = false,
    this.allowProjectTooling = false,
    this.baselineRunPath,
    this.licenseFile,
  });

  /// Stable id of the sub-command the user invoked, or null for the
  /// default `simcrux [config.yaml]` form. The bootstrap dispatches
  /// on this value before falling through to the regression-runner
  /// path.
  final String? subcommand;

  /// Positional arguments that followed [subcommand] verbatim. The
  /// sub-command handler is responsible for parsing them.
  final List<String> subcommandArgs;

  /// Positional `simcrux.yaml` project files passed on the command
  /// line. Zero, one, or many. Each one opens as a workspace tab in
  /// the order supplied. Empty list = no positional configs were
  /// supplied (the empty-canvas state renders).
  final List<String> projectPaths;

  /// `--filter <pattern>` value. Glob-style substring match against
  /// the flattened `TestSpec.id`. The matching logic lives in the
  /// regression runner downstream.
  final String? filter;

  /// `--max-parallel <n>` override. Wins over the per-project default
  /// and the user's setting. Null means "use the default".
  final int? maxParallel;

  /// `--json` flag. When true the CLI prints results as JSON to
  /// stdout instead of the human-readable progress UI.
  final bool jsonOutput;

  /// `--ci` flag. When true the CLI runs non-interactively and the
  /// process exit code reflects the regression outcome (0 = all
  /// passed, non-zero otherwise) — matches the
  /// `simcrux run --ci` mode in the v1.0 feature spec.
  final bool ciMode;

  /// One or more `--export <fmt>=<path>` targets. The CI driver
  /// fans the completed run out to each one before exiting.
  final List<CliExportTarget> exportTargets;

  /// `--fail-threshold <n>`. Process exits non-zero when the number
  /// of failed tests is `>= failThreshold`. Defaults to 1 — any
  /// failure aborts the build, which matches the default expectation
  /// for a "did the regression pass" CI gate.
  final int failThreshold;

  /// `--session <path>`. When set, the desktop bootstrap opens one more
  /// tab whose config path is `<path>` (`CliRegressionBootstrapper`). No
  /// session document is parsed — selection and filters are not restored
  /// — and `--ci` ignores it.
  final String? sessionPath;

  /// `--workspace <path>`. When set, the bootstrap loads the named
  /// `.simcrux-workspace` document before any positional configs are
  /// appended as additional tabs.
  final String? workspacePath;

  /// `--import-fusesoc <core-file>`. When set, the bootstrap runs
  /// the FuseSoC importer on the named `.core` file, writes a
  /// `simcrux.yaml` next to it, prints any warnings to stderr, and
  /// exits without launching the UI. Mutually exclusive with the
  /// regression-runner flow in practice (the bootstrap checks this
  /// field early and short-circuits).
  final String? importFusesoc;

  /// `--fail-on-regression` flag. When true in `--ci` mode the
  /// process exits non-zero if the completed run regressed relative
  /// to the baseline referenced by [baselineRunPath]. The comparison
  /// is performed by the
  /// `failOnRegressionPolicyProvider`-registered policy — open-core
  /// builds always return "no regression" (the engine lives in the
  /// Pro overlay); the Pro overlay runs the regression-comparison
  /// engine against the supplied baseline snapshot.
  ///
  /// When set without [baselineRunPath] the CI runner emits a
  /// warning and proceeds with `exitCode = 0` (no regression
  /// detected = no failure path possible). The warning surfaces
  /// drift between users' CI scripts and their baseline-capture
  /// pipelines without forcibly breaking the build.
  ///
  /// The default failure exit code is `1`; users can override via
  /// the `SIMCRUX_REGRESSION_EXIT_CODE` env var when their CI
  /// system requires a specific code for "regression detected"
  /// (e.g. GitLab uses `124` for "allowed failures").
  final bool failOnRegression;

  /// `--fail-on-vacuous` flag. When true, tests classified
  /// [TestStatus.vacuous] are counted as failures for the
  /// `--fail-threshold` gate.
  ///
  /// Default false, which preserves the scheduler's treatment of
  /// vacuous as a success-equivalent (it neither retries nor retains
  /// the work dir). A vacuous test is one whose testbench ran to
  /// completion without ever exercising its checks — legitimate while
  /// a testbench is under construction, and a silent hole in a
  /// nightly gate once it is not. Opt in per CI job rather than
  /// flipping the default and breaking every existing pipeline.
  ///
  /// [TestStatus.unknown] is NOT covered by this flag: unknown means
  /// the scheduler could not determine an outcome (no driver
  /// registered, a scheduler-level exception), which is always a
  /// failure of the run itself and always counts toward the gate.
  final bool failOnVacuous;

  /// `--allow-project-tooling` flag. When true this run honors the
  /// project file's **project-defined tooling** keys —
  /// `simulators.<id>.path`, `simulators.<id>.env`, the `riscv.target` /
  /// `riscv.riscof` / `riscv.compile` / `riscv.formal` `command:` argv
  /// lists, and the RISC-V executable paths (`reference.path`,
  /// `toolchain.path` / `prefix`, `riscof.binary`, `formal.sby_binary`) —
  /// each of which chooses what the run executes and under what
  /// environment. `ConfigLoader`'s `allowProjectDefinedTooling` has the
  /// full list.
  ///
  /// Default false, matching the app, where the same decision is the
  /// Settings → Simulators switch named by `kAllowProjectToolingControlLabel`.
  /// The CLI has no Settings to read, so the flag is the whole decision:
  /// typing it is a user saying "I trust this project file". Without it
  /// the loader drops the paths and `env:` with an advisory and refuses a
  /// `command:` outright.
  final bool allowProjectTooling;

  /// `--baseline <path>` value. Path to a `.ndjson` snapshot
  /// produced by a prior `--ci` run with streaming enabled (see
  /// `StreamingResultsWriter`). The Pro policy parses the snapshot
  /// into a `TestRun` and diffs the just-completed candidate
  /// against it. When null and [failOnRegression] is true, the CI
  /// runner emits a warning and proceeds with `exitCode = 0`.
  ///
  /// Why a file path rather than a runId. The in-memory result store
  /// holds only the currently-active run; a CI invocation is a
  /// fresh process with no prior in-memory state. Pointing at a
  /// committed `.ndjson` snapshot is the only model that works
  /// reliably across CI processes without coupling regression
  /// comparison to a hosted trend store.
  final String? baselineRunPath;

  /// `--license-file <path>` value. A SimCrux license file (or a file
  /// holding a license key) validated offline for a `--ci` run, which has
  /// no access to the license stored by the desktop app. When null the run
  /// falls back to the `SIMCRUX_LICENSE_FILE` environment variable and then
  /// to the organization policy file — see `HeadlessLicenseTierResolver`.
  final String? licenseFile;

  /// True when the user passed at least one positional argument.
  bool get hasProject => projectPaths.isNotEmpty;

  /// The first positional config path, if any. Convenience accessor
  /// for [CiRunner] and other call sites that only ever look at one
  /// project at a time.
  String? get projectPath => projectPaths.isEmpty ? null : projectPaths.first;

  /// Returns a copy with the given fields replaced.
  CliArgs copyWith({
    List<String>? projectPaths,
    String? filter,
    int? maxParallel,
    bool? jsonOutput,
    bool? ciMode,
    List<CliExportTarget>? exportTargets,
    int? failThreshold,
    String? sessionPath,
    String? workspacePath,
    String? subcommand,
    List<String>? subcommandArgs,
    String? importFusesoc,
    bool? failOnRegression,
    bool? failOnVacuous,
    bool? allowProjectTooling,
    String? baselineRunPath,
    String? licenseFile,
  }) {
    return CliArgs(
      projectPaths: projectPaths ?? this.projectPaths,
      filter: filter ?? this.filter,
      maxParallel: maxParallel ?? this.maxParallel,
      jsonOutput: jsonOutput ?? this.jsonOutput,
      ciMode: ciMode ?? this.ciMode,
      exportTargets: exportTargets ?? this.exportTargets,
      failThreshold: failThreshold ?? this.failThreshold,
      sessionPath: sessionPath ?? this.sessionPath,
      workspacePath: workspacePath ?? this.workspacePath,
      subcommand: subcommand ?? this.subcommand,
      subcommandArgs: subcommandArgs ?? this.subcommandArgs,
      importFusesoc: importFusesoc ?? this.importFusesoc,
      failOnRegression: failOnRegression ?? this.failOnRegression,
      failOnVacuous: failOnVacuous ?? this.failOnVacuous,
      allowProjectTooling: allowProjectTooling ?? this.allowProjectTooling,
      baselineRunPath: baselineRunPath ?? this.baselineRunPath,
      licenseFile: licenseFile ?? this.licenseFile,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CliArgs) return false;
    if (other.filter != filter) return false;
    if (other.maxParallel != maxParallel) return false;
    if (other.jsonOutput != jsonOutput) return false;
    if (other.ciMode != ciMode) return false;
    if (other.failThreshold != failThreshold) return false;
    if (other.sessionPath != sessionPath) return false;
    if (other.workspacePath != workspacePath) return false;
    if (other.subcommand != subcommand) return false;
    if (other.importFusesoc != importFusesoc) return false;
    if (other.failOnRegression != failOnRegression) return false;
    if (other.failOnVacuous != failOnVacuous) return false;
    if (other.allowProjectTooling != allowProjectTooling) return false;
    if (other.baselineRunPath != baselineRunPath) return false;
    if (other.licenseFile != licenseFile) return false;
    if (projectPaths.length != other.projectPaths.length) return false;
    for (var i = 0; i < projectPaths.length; i++) {
      if (projectPaths[i] != other.projectPaths[i]) return false;
    }
    if (exportTargets.length != other.exportTargets.length) return false;
    for (var i = 0; i < exportTargets.length; i++) {
      if (exportTargets[i] != other.exportTargets[i]) return false;
    }
    if (subcommandArgs.length != other.subcommandArgs.length) return false;
    for (var i = 0; i < subcommandArgs.length; i++) {
      if (subcommandArgs[i] != other.subcommandArgs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    Object.hashAll(projectPaths),
    filter,
    maxParallel,
    jsonOutput,
    ciMode,
    Object.hashAll(exportTargets),
    failThreshold,
    sessionPath,
    workspacePath,
    subcommand,
    Object.hashAll(subcommandArgs),
    importFusesoc,
    failOnRegression,
    failOnVacuous,
    allowProjectTooling,
    baselineRunPath,
    licenseFile,
  );
}
