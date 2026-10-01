// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_eula/crux_eula.dart';
import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_linux_integration/crux_linux_integration.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:crux_updates/crux_updates.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/cli_args_provider.dart';
import 'package:simcrux/core/eula/simcrux_eula_storage.dart';
import 'package:simcrux/core/issue_reporter/simcrux_issue_reporter_strings.dart';
import 'package:simcrux/core/platform/linux_desktop_identity.dart';
import 'package:simcrux/core/policy/simcrux_policy_keys.dart';
import 'package:simcrux/core/router/app_router.dart';
import 'package:simcrux/core/shortcuts/shortcut_manager_widget.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_handlers.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_storage.dart';
import 'package:simcrux/core/telemetry/simcrux_telemetry_strings.dart';
import 'package:simcrux/core/theme/simcrux_color_theme_bootstrap.dart';
import 'package:simcrux/core/theme/simcrux_theme.dart';
import 'package:simcrux/core/theme/simcrux_theme_tokens.dart';
import 'package:simcrux/core/update/simcrux_update_strings.dart';
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_gate.dart';
import 'package:simcrux/features/beta_expiry/widgets/beta_expiry_metrics.dart';
import 'package:simcrux/features/dashboard/widgets/cli_regression_bootstrapper.dart';
import 'package:simcrux/features/eula/simcrux_eula_overrides.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_overrides.dart';
import 'package:simcrux/features/lifecycle/widgets/app_exit_guard.dart';
import 'package:simcrux/features/menu_bar/widgets/desktop_menu_bar.dart';
import 'package:simcrux/features/remote/providers/cxp_attention_bridge.dart';
import 'package:simcrux/features/remote/providers/cxp_discovery_provider.dart';
import 'package:simcrux/features/remote/providers/inbound_request_handler.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/telemetry/simcrux_telemetry_overrides.dart';
import 'package:simcrux/features/update/providers/update_overrides.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/project_workspace_sync.dart';
import 'package:simcrux/features/workspace/providers/workspace_containers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/plugins/extra_localizations_delegates_provider.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/ci/fail_on_regression_policy.dart';
import 'package:simcrux/services/cli/cli_args.dart' as launch_cli;
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/export/dashboard_bundle_writer.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/import/fusesoc_importer.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/license/headless_license_tier.dart';
import 'package:simcrux/services/logging/headless_debug_print.dart';
import 'package:simcrux/services/logging/severe_log_stderr_sink.dart';
import 'package:simcrux/services/telemetry/headless_telemetry.dart';

/// Runs [bootstrap] and ends the process when it handled a headless
/// invocation — the entry point both `lib/main.dart` files call.
///
/// A Flutter desktop runner creates its window at launch and keeps its event
/// loop alive after Dart's `main` returns, so `SimCrux --ci proj.yaml` used to
/// finish the regression, set the exit code, and then sit there with an empty
/// window instead of exiting: a CI job that never ends. The headless branches
/// of [bootstrap] only return, so the exit happens here, after stdout and
/// stderr are flushed. [exitProcess] is injectable for tests.
Future<void> runSimcrux({
  List<String> args = const [],
  List<Override> extraOverrides = const [],
  LinuxDesktopApp? linuxDesktopApp,
  Future<void> Function(int code)? exitProcess,
}) async {
  final headless = await bootstrap(
    args: args,
    extraOverrides: extraOverrides,
    linuxDesktopApp: linuxDesktopApp,
  );
  if (!headless || kIsWeb) return;
  await (exitProcess ?? _flushAndExit)(exitCode);
}

Future<void> _flushAndExit(int code) async {
  await stdout.flush();
  await stderr.flush();
  exit(code);
}

/// Starts capturing diagnostics. Idempotent under hot restart.
///
/// The issue reporter's ring buffer takes every log record, and uncaught
/// framework and async errors are routed into the log (the console dumps are
/// preserved), so a failure during the session lands in a bug report. The
/// buffer is memory only, though; off the web, [SevereLogStderrSink] also
/// writes SEVERE records to stderr, the one trace a release build leaves once
/// the session is gone. [stderrSink] replaces the process-wide sink in tests.
@visibleForTesting
void attachDiagnosticSinks({SevereLogStderrSink? stderrSink}) {
  CruxIssueReporterLogBuffer.instance
    ..attachToLogging()
    ..captureFlutterErrors();
  if (!kIsWeb) (stderrSink ?? SevereLogStderrSink.instance).attach();
}

/// Entry-point body shared by the open-core `lib/main.dart` and the Pro
/// overlay's `lib/main.dart` (through [runSimcrux]). Open-core
/// runs `bootstrap(args: args)`; the Pro overlay adds
/// `extraOverrides: proOverrides`.
///
/// [linuxDesktopApp] is the freedesktop identity installed when the app runs
/// from an AppImage: open core passes nothing and gets
/// [kSimcruxLinuxDesktopApp]; the Pro overlay passes its own. Null rather
/// than a default value because the identity declares file types, which are
/// built and not compile-time constants.
///
/// Returns true when [args] selected a headless flow (`--help`, `--ci`,
/// an import, `export-dashboard`, or an argument error) that has finished and
/// set `exitCode`; false once the GUI is running.
Future<bool> bootstrap({
  List<String> args = const [],
  List<Override> extraOverrides = const [],
  LinuxDesktopApp? linuxDesktopApp,
}) async {
  WidgetsFlutterBinding.ensureInitialized();

  // `--reset-telemetry-consent` puts this installation back to "never
  // answered", so the one-time disclosure mounts again this launch rather than
  // next one. A testing affordance: the dialog is deliberately
  // once-per-installation, which makes it the surface hardest to see twice.
  //
  // Before the container is built, because `TelemetryConsentStore` starts
  // reading the persisted value the moment anything touches the telemetry
  // graph. The installation id is left alone — see `resetTelemetryConsent`.
  if (args.contains('--reset-telemetry-consent')) {
    await resetTelemetryConsent(const SimcruxTelemetryStorage());
  }

  // `--reset-eula` forgets the accepted agreement version, so the license
  // agreement is presented again this launch. The same testing affordance and
  // the same ordering constraint: the acceptance store reads the persisted
  // value as soon as it is first read, so the reset runs before the container
  // exists. Combined with `--reset-telemetry-consent`, both dialogs appear,
  // the agreement first, because `CruxEulaGate` wraps the telemetry gate.
  if (args.contains('--reset-eula')) {
    await resetCruxEulaAcceptance(const SimcruxEulaStorage());
  }

  // BEFORE any provider is constructed, so early-startup warnings (config
  // load failures, workspace hydration errors, plugin scan problems) are
  // already captured by the time a user files a report.
  attachDiagnosticSinks();

  // Suite-shared launch recovery flags (`--reset` / `--no-restore`),
  // ported from WaveCrux (`services/cli/cli_args.dart`). Parsed first and
  // stripped from the argument list so the strict `package:args` parser
  // below — where an unknown flag is a usage error — never sees them.
  // Sub-command invocations are exempt: everything after the sub-command
  // word is forwarded verbatim to its handler, which owns its own parser.
  final isSubcommand = CliArgParser.startsWithSubcommand(args);
  final launchFlags = isSubcommand
      ? const launch_cli.CliArgs()
      : launch_cli.parseCliArgs(args);
  final launchArgs = isSubcommand ? args : launch_cli.stripLaunchFlags(args);

  var parsedArgs = const CliArgs();
  try {
    final parsed = CliArgParser().parse(launchArgs);
    if (parsed is HelpCliArgs) {
      // CLI usage output is the standard --help contract — stdout. The
      // launch recovery flags are stripped before the primary parser
      // runs, so their usage lines are appended here instead.
      // ignore: avoid_print
      print('${CliArgParser().usage}\n${launch_cli.cliHelpText()}');
      return true;
    }
    parsedArgs = parsed;
  } on CliArgsException catch (e) {
    // A usage error ends the invocation with the documented exit 2, as the
    // standalone binary does. It used to print to stdout and fall through
    // to the GUI, so a mistyped flag in a CI script opened a window and
    // never exited.
    stderr.writeln(e);
    exitCode = 2;
    return true;
  }

  final importPath = parsedArgs.importFusesoc;
  if (importPath != null && importPath.isNotEmpty) {
    try {
      final result = await FuseSoCImporter().importFile(importPath);
      final outPath = p.join(
        File(importPath).parent.path,
        result.suggestedOutputFilename,
      );
      await File(outPath).writeAsString(result.simcruxYaml);
      // CLI status: the written-file confirmation is output, so stdout.
      // ignore: avoid_print
      print('simcrux: wrote $outPath');
      for (final w in result.warnings) {
        // Importer warnings are non-fatal but worth surfacing to the
        // user before they consume the synthesized simcrux.yaml.
        // ignore: avoid_print
        print('simcrux: [${w.code}] ${w.message}');
      }
      exitCode = 0;
    } on FuseSoCImportException catch (e) {
      // Unrecoverable import error. Failures go to stderr, as the
      // standalone binary sends them: `print` is stdout, which a script
      // reads for the import's output.
      stderr.writeln('simcrux: $e');
      exitCode = 2;
    } on Object catch (e) {
      // I/O failure (file read/write).
      stderr.writeln('simcrux: import-fusesoc failed: $e');
      exitCode = 2;
    }
    return true;
  }

  // `simcrux import-riscv-arch-test <checkout>` /
  // `simcrux import-riscv-formal <checks-dir>`. Importing several hundred
  // architectural tests or bounded proofs is a scripted job at least as
  // often as it is a GUI one, so both imports are reachable without ever
  // opening a window — and both exit without launching the UI, exactly as
  // `--import-fusesoc` does.
  final importKind = RiscvImportKind.fromSubcommand(parsedArgs.subcommand);
  if (importKind != null) {
    try {
      await RiscvImportCli().run(importKind, parsedArgs.subcommandArgs);
      exitCode = 0;
    } on RiscvImportCliException catch (e) {
      // Usage error. Failures go to stderr; `--help` is answered on stdout
      // inside `RiscvImportCli.run` and never reaches here.
      stderr.writeln(e);
      exitCode = 2;
    } on RiscvImportException catch (e) {
      // The named tree is not the thing it claims to be.
      stderr.writeln('simcrux: $e');
      exitCode = 2;
    } on Object catch (e) {
      // I/O failure (directory scan / file write).
      stderr.writeln('simcrux ${importKind.subcommand}: $e');
      exitCode = 2;
    }
    return true;
  }

  if (parsedArgs.subcommand == CliArgParser.kExportDashboardSubcommand) {
    // Same transient-container shape as the `--ci` branch below, and for the
    // same reason: `export-dashboard` is a headless invocation, so its
    // `export.completed` counter is governed by the `--ci` consent rule
    // — stored `enabled` transmits, `unset` and `disabled` do not, and
    // nothing on this path can prompt.
    final exportContainer = ProviderContainer(
      overrides: [...simcruxTelemetryOverrides, ...extraOverrides],
    );
    try {
      await DashboardBundleWriter(
        telemetry: await resolveHeadlessTelemetry(exportContainer),
      ).run(parsedArgs.subcommandArgs);
      exitCode = 0;
    } on DashboardBundleException catch (e) {
      // CLI usage error. Failures go to stderr, as the standalone binary
      // sends them.
      stderr.writeln(e);
      exitCode = 2;
    } on Object catch (e) {
      // I/O failure.
      stderr.writeln('simcrux export-dashboard: $e');
      exitCode = 2;
    } finally {
      // Cancels the telemetry service's six-hour flush timer. Without this a
      // consenting machine's `export-dashboard` would set its exit code and
      // then sit in the event loop for six hours.
      exportContainer.dispose();
    }
    return true;
  }

  if (parsedArgs.ciMode && parsedArgs.hasProject) {
    // A framework error during the run is presented through `debugPrint`,
    // which prints to stdout; the run owns stdout, so the dump goes to
    // stderr for as long as the run lasts.
    await withDebugPrintOnStderr(
      () => _runCiInvocation(parsedArgs, extraOverrides),
    );
    return true;
  }

  // `--reset` is the documented escape hatch for a session so corrupt it
  // wedges startup: wipe the auto-managed workspace.json and every per-tab
  // session sidecar, then launch into an empty workspace. Runs BEFORE the
  // root container exists so the workspace notifier's first load sees
  // nothing to restore. Scoped to session state — settings, keymap, and
  // recent files are kept. No-op on web (no on-disk session there).
  if (!kIsWeb && launchFlags.reset) {
    final workspaceService = crux.WorkspaceService<SimcruxTabPayload>(
      codec: const SimcruxWorkspaceCodec(),
    );
    await workspaceService.clear();
    await workspaceService.clearAllSidecars();
    // The --reset confirmation is CLI output — stdout is the contract.
    // ignore: avoid_print
    print('SimCrux: cleared saved session and workspace state (--reset).');
  }

  // Register the suite-shared chrome token catalog so Settings →
  // Appearance and `.crux-theme.json` packs resolve every chrome token
  // id to a registered descriptor.
  registerSimcruxThemeTokens();

  // Two-phase init: build the root container first so the per-tab and
  // per-pane container managers can be parented to it; expose the
  // managers (and the cli args) via overrides so widgets resolve them
  // without threading a ref through every constructor. Mirrors the
  // WaveCrux pattern in the `wavecrux` repository's `lib/app.dart`. The topology
  // itself lives in `createWorkspaceContainers` so provider tests can
  // exercise the REAL production wiring (see the run-actions regression
  // pinned in
  // test/features/workspace/providers/simcrux_action_context_provider_test.dart).
  final containers = createWorkspaceContainers(
    rootOverrides: <Override>[
      cliArgsProvider.overrideWithValue(parsedArgs),
      // `--no-restore` skips this launch's workspace rehydration without
      // deleting anything: the injected restore gate short-circuits
      // `shouldRestoreOnLaunch` so `workspace.json` is never loaded (and
      // stays untouched on disk for the next normal launch).
      if (launchFlags.noRestore)
        workspaceProvider.overrideWith(
          () => SimcruxWorkspaceNotifier(restoreGate: () async => false),
        ),
      // Bridge SimCrux persistence (AppSettings.core.activeThemeName +
      // themeOverrides) into crux_theme's cruxColorThemeProvider, exactly
      // as WaveCrux / NetCrux / LintCrux do. Spread before extraOverrides
      // so the Pro overlay can layer its own override on top per the
      // open-core conflict semantics.
      simcruxCruxColorThemeOverride,
      // Beta-release infrastructure. Both spread before
      // `extraOverrides` so the Pro overlay can layer its own
      // bindings on top (open-core first, Pro last, later overrides win) —
      // notably `cruxIssueReporterDataProviderProvider` for the Pro State
      // category.
      ...simcruxUpdateOverrides,
      ...simcruxIssueReporterOverrides,
      // `crux_audit`: the product id stamped into every audit event this
      // installation records. One JSONL file holds four products' events and
      // this is what makes it filterable — the same string the policy
      // namespace uses, so filtering the log and writing `.crux-policy.json`
      // share one vocabulary. Emission is unconditional; the SINK is what an
      // administrator gates, and it is `NoopAuditSink` until one sets
      // `suite.audit.path`.
      cruxAuditProductIdProvider.overrideWithValue(SimCruxPolicyKeys.productId),
      // Anonymous usage statistics. Spread before
      // `extraOverrides` for the same later-wins reason as the two above —
      // that is where an Enterprise `.crux-policy.json` `telemetry:
      // allow | deny` key will bind, as an override of
      // `telemetryConsentPromptVisibleProvider`. Inert for the whole beta: the
      // gate returns false for every consent value while `kBetaPeriod` is on,
      // so no live service is constructed and no consent surface mounts.
      //
      // The EULA gate's persistence and quit path bind here too, and only
      // here: the headless containers above mount no gate, and EULA 2.1(c)
      // makes using an Application an acceptance in its own right.
      ...simcruxEulaOverrides,
      ...simcruxTelemetryOverrides,
      ...extraOverrides,
    ],
    // The issue reporter's session contributor reaches the per-tab
    // containers, so it must materialize in the scoped container — below
    // the managers override — rather than in the root. See
    // `simcruxIssueReporterScopedOverrides` for why registering it in the
    // root silently produces an all-zero report.
    scopedOverrides: simcruxIssueReporterScopedOverrides,
  );
  final scopedContainer = containers.scoped;

  // `workspace.reset` is recorded here rather than from an override of
  // `WorkspaceNotifier.resetWorkspace`, because `--reset` is SimCrux's only
  // reset path and it runs through the *service* above, before this container
  // exists. Recording it here is the earliest honest moment: the document is
  // already gone, and the telemetry graph is finally readable.
  //
  // Before the workspace hydration below, so the counter lands whether or not
  // the (now empty) restore succeeds.
  if (!kIsWeb && launchFlags.reset) {
    scopedContainer
        .read(telemetryServiceProvider)
        .record(TelemetryEvent('workspace.reset'));
  }

  // Hydrate workspaceProvider before the first frame so PaneHost sees a
  // resolved AsyncValue and the empty-canvas state does not flash an
  // AsyncLoading placeholder on launch. Hydration failures fall back
  // to Workspace.empty inside the service.
  try {
    await scopedContainer.read(workspaceProvider.future);
  } on Object {
    // Non-fatal — the service returns Workspace.empty on failure.
  }

  // The user's active theme pack, before the first frame. Settings hold only
  // its id; its tokens are in its installed file, so without this the app
  // opens on the default theme every launch after a pack was chosen.
  await restoreActiveThemePack(containers.root);

  // Windows/Linux only: switch the window to frameless (TitleBarStyle.hidden)
  // and show it once ready, so the in-window VS Code-style title bar drawn by
  // DesktopMenuBar replaces the OS title bar. No-op / never invoked elsewhere
  // (macOS keeps its native menu; web has no window). Geometry restore across
  // sessions is not wired yet — the window opens at the default size.
  if (useCustomWindowChrome) {
    await initWindowChrome();
  }

  // AppImage first-run desktop self-integration (Linux/Wayland): write the
  // host-side .desktop + hicolor icons so GNOME/Ubuntu matches this window's
  // app_id to its dock icon. Inert off Linux and off AppImage. MUST be guarded
  // off web: maybeIntegrateDesktopEntry reaches dart:io `Platform`, which is
  // unavailable on web and throws before its own Linux guard — unguarded, that
  // throws out of bootstrap here so runApp never fires and the web app hangs on
  // its loading spinner.
  if (!kIsWeb) {
    await maybeIntegrateDesktopEntry(
      linuxDesktopApp ?? kSimcruxLinuxDesktopApp,
    );
  }

  // Say which policy file won, or that one was refused
  // (<https://edacrux.app/policy-reference#failures>). Without this call a
  // file whose signature fails is refused **silently**: from inside a running
  // app a refused policy and an absent one are indistinguishable, and telling
  // those two apart is the whole point of the distinction. A refusal means the
  // administrator's policy is not in force, so saying nothing is fail-open with
  // no signal.
  //
  // The two halves land in different places and `reportPolicyLoad` decides
  // which — a refusal CANNOT reach the audit sink, because the sink's path
  // comes from `suite.audit.path`, which comes from the file that was just
  // refused. See `crux_license`'s `PolicyReportDestination`.
  //
  // Here rather than in the Pro overlay: the policy file is honoured at every
  // tier for the day-one keys, so an open-core seat pointed at a bad file has
  // to be told too.
  reportPolicyLoad(
    result: scopedContainer.read(cruxPolicyProvider),
    // Names any key the administrator set that this build does not act on.
    productId: SimCruxPolicyKeys.productId,
    recorder: scopedContainer.read(cruxAuditRecorderProvider),
  );

  runApp(
    WorkspaceContainersScope(
      root: containers.root,
      scoped: scopedContainer,
      // AppExitGuard must sit above the app so the OS-termination hook
      // is installed for the whole session, not per-route.
      child: const AppExitGuard(child: SimcruxApp()),
    ),
  );
  return false;
}

/// The `--ci` branch of [bootstrap]: loads the project, runs the
/// regression, writes any `--export` targets, and sets the process
/// `exitCode`. Never opens a window.
Future<void> _runCiInvocation(
  CliArgs parsedArgs,
  List<Override> extraOverrides,
) async {
  // The FailOnRegressionPolicy is resolved through a transient
  // ProviderContainer so the Pro overlay's override flows into the
  // runner the same way it flows into the rest of the app. In an
  // open-core build the container returns NoopFailOnRegressionPolicy
  // and --fail-on-regression has no effect on the exit code.
  // The telemetry overrides are spread first so `extraOverrides` (the Pro
  // overlay, or a test's) can layer on top, exactly as in the GUI container
  // [bootstrap] builds. They are what let `resolveHeadlessTelemetry` read the consent the
  // GUI wrote — the `--ci` rule is a *read* of the GUI's decision, never a
  // second decision of its own.
  final ciContainer = ProviderContainer(
    overrides: [...simcruxTelemetryOverrides, ...extraOverrides],
  );
  final policy = ciContainer.read(failOnRegressionPolicyProvider);
  // The license tier the project loads at. A CI agent has no license
  // stored by this app, so it comes from `--license-file`, then
  // SIMCRUX_LICENSE_FILE, then the organization policy file — the same
  // resolution the standalone binary uses. Without it every headless load
  // is Open Core and, once the beta ends, Pro sweeps silently run once.
  final LicenseTier ciTier;
  try {
    final resolution = await ciContainer
        .read(headlessLicenseTierResolverProvider)
        .resolve(licenseFilePath: parsedArgs.licenseFile);
    for (final note in resolution.notes) {
      stderr.writeln('simcrux: $note');
    }
    ciTier = resolution.tier;
  } on HeadlessLicenseException catch (e) {
    stderr.writeln('simcrux: error: $e');
    exitCode = 2;
    ciContainer.dispose();
    return;
  }
  // Resolve the driver registry through the same container the policy
  // came from, so a Pro overlay override — or a test's scripted-driver
  // override via `extraOverrides` — reaches the CI scheduler exactly as
  // it reaches the app's interactive scheduler. Open-core resolves the
  // stock four built-in drivers plus the plugin registry (both via
  // `simulatorDriverRegistryProvider`), so a plugin-contributed driver
  // works under `--ci` exactly as it does interactively.
  final runner = CiRunner(
    configLoader: ConfigLoader(
      licenseTier: ciTier,
      // `--allow-project-tooling`. Off unless the user typed it: a
      // project file may not choose which binary this run spawns, or
      // its environment, on its own. The interactive app takes the
      // same decision from Settings → Simulators; a `--ci` run has no
      // Settings and must never block on a dialog, so the flag is it.
      allowProjectDefinedTooling: parsedArgs.allowProjectTooling,
    ),
    // Resolved from the container rather than constructed here, so a Pro
    // overlay override reaches the headless scheduler exactly as it reaches
    // the interactive one. Open core resolves LocalJobScheduler; the overlay
    // binds its templated backend when the policy file names one.
    schedulerFactory: ciContainer.read(ciSchedulerFactoryProvider),
    exporterRegistry: const ExporterRegistry(),
    failOnRegressionPolicy: policy,
    // The same tier the project loads at. The Pro overlay's regression gate
    // refuses `--fail-on-regression` when it does not include the gate.
    licenseTier: ciTier,
    // THE `--ci` RULE. Resolves to the live service only when the GUI on
    // this machine has stored an affirmative consent; `unset` and `disabled`
    // both resolve to the no-op, and neither prompts — a CI job must never
    // block on a dialog, nor be treated as consenting by silence. See
    // `services/telemetry/headless_telemetry.dart`.
    telemetry: await resolveHeadlessTelemetry(ciContainer),
  );
  try {
    final outcome = await runner.run(args: parsedArgs);
    exitCode = outcome.exitCode;
  } on Object catch (e) {
    // stderr, never stdout: under `--json` stdout is the results document,
    // and the summary may already be on it when a later step throws.
    stderr.writeln('simcrux: $e');
    exitCode = 2;
  } finally {
    ciContainer.dispose();
  }
}

/// Root widget. Wires the SimCrux theme, localization, and routing
/// into a [MaterialApp.router].
class SimcruxApp extends ConsumerWidget {
  /// Creates a [SimcruxApp].
  const SimcruxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(appRouterProvider);
    // Apply the persisted UI language (Appearance → Language). Before the
    // suite settings consistency pass, CoreSettings.locale was persisted but
    // never applied — the four shipped translations were unreachable except
    // via the OS language.
    final localeTag = ref.watch(
      appSettingsProvider.select((s) => s.value?.core.locale),
    );
    final locale = switch (localeTag ?? 'en') {
      'zh_CN' => const Locale.fromSubtags(
        languageCode: 'zh',
        countryCode: 'CN',
      ),
      'ja' => const Locale('ja'),
      'ko' => const Locale('ko'),
      _ => const Locale('en'),
    };
    // Drive the Material brightness from the active preset (so picking
    // WaveCrux Light flips the chrome to light, Solarized Dark to dark,
    // etc.) and apply the preset's chrome tokens onto the base SimCrux
    // theme. See applyChromeTokens in package:crux_theme/crux_theme.dart.
    final cruxColorTheme = ref.watch(cruxColorThemeProvider);
    final chromeExt = CruxThemeExtension(theme: cruxColorTheme);
    final themeMode = themeModeFromBrightness(cruxColorTheme);
    final lightTheme = applyChromeTokens(
      SimcruxTheme.light().copyWith(
        extensions: <ThemeExtension<dynamic>>[chromeExt],
      ),
      chromeExt,
    );
    final darkTheme = applyChromeTokens(
      SimcruxTheme.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[chromeExt],
      ),
      chromeExt,
    );
    // High-contrast variants for the platform accessibility setting, given
    // the same chrome tokens so an active theme preset still applies. Wired
    // into highContrastTheme / highContrastDarkTheme below for parity with
    // WaveCrux's app.dart.
    final highContrastLightTheme = applyChromeTokens(
      SimcruxTheme.highContrastLight().copyWith(
        extensions: <ThemeExtension<dynamic>>[chromeExt],
      ),
      chromeExt,
    );
    final highContrastDarkTheme = applyChromeTokens(
      SimcruxTheme.highContrastDark().copyWith(
        extensions: <ThemeExtension<dynamic>>[chromeExt],
      ),
      chromeExt,
    );
    return MaterialApp.router(
      onGenerateTitle: (context) => L10N.of(context).appTitle,
      theme: lightTheme,
      darkTheme: darkTheme,
      highContrastTheme: highContrastLightTheme,
      highContrastDarkTheme: highContrastDarkTheme,
      themeMode: themeMode,
      localizationsDelegates: [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        ...ref.watch(extraLocalizationsDelegatesProvider),
      ],
      supportedLocales: L10N.supportedLocales,
      locale: locale,
      routerConfig: router,
      scaffoldMessengerKey: rootScaffoldMessengerKey,
      // Builder stack, outermost first:
      //
      //   RepaintBoundary  — the beta issue reporter's screenshot source. Must
      //                      wrap the whole rendered app, so it goes first.
      //   ProviderScope    — binds the two crux-shared string bundles that
      //                      need a BuildContext for `L10N.of`. Everything
      //                      below (banner, gate, reporter dialog, action
      //                      handlers) resolves them from here; providers not
      //                      overridden still resolve in the root container.
      //   BetaExpiryGate   — a blocking expiry modal must cover everything,
      //                      including the update strip.
      //   UpdateBanner     — nested inside the gate, per the crux_updates
      //                      wiring contract.
      //   CliRegressionBootstrapper + the existing action/menu chrome.
      builder: (context, child) {
        final Widget app = RepaintBoundary(
          key: ref.watch(cruxAppScreenshotBoundaryKeyProvider),
          child: ProviderScope(
            overrides: [
              cruxUpdateStringsProvider.overrideWithValue(
                SimcruxUpdateStrings(L10N.of(context)),
              ),
              cruxIssueReporterStringsProvider.overrideWithValue(
                SimcruxIssueReporterStrings(L10N.of(context)),
              ),
              // The consent surfaces read this. `crux_telemetry` renders its
              // own copy, so the disclosure needs the SimCrux ARB bundle the
              // same way the update banner does — which is why the gate below
              // sits *inside* this scope rather than outside it.
              cruxTelemetryStringsProvider.overrideWithValue(
                SimcruxTelemetryStrings(L10N.of(context)),
              ),
            ],
            child: BetaExpiryGate(
              // Below the expiry gate so an expired build's blocking modal
              // still wins — an expired build has nothing to collect and
              // nothing the user can do about it — and above the update banner
              // so the one-time disclosure is not competing for the top of the
              // window with an update prompt.
              //
              // SimCrux is desktop-first with a desktop-class web viewer and
              // has no device-class system, so the sheet-vs-dialog choice is
              // settled: `isPhoneLayout` stays at its `false` default. The
              // sizing comes from the constants the beta-expiry surfaces
              // already use, which are the desktop values WaveCrux's
              // `MobileMetrics` resolves to and already clear the suite's
              // 44 dp floor.
              child: CruxEulaGate(
                // OUTSIDE the telemetry disclosure, and that ordering is not a
                // preference. The disclosure asks for consent to a term the
                // EULA itself defines (EULA 8), so collecting it first would
                // have the user answering a question about a contract they had
                // not been shown. It is also the only ordering under which the
                // EEA/UK/CH/KR opt-in default is defensible.
                //
                // Inside the expiry gate, on the same rule that puts the
                // disclosure there: an expired build has nothing to license.
                //
                // Sized from the same beta-expiry constants, and left at the
                // dialog presentation for the same reason — SimCrux has no
                // device-class system, so `isPhoneLayout` stays false.
                //
                // Not localized: the agreement is executed in English, so its
                // chrome stays English rather than implying otherwise.
                metrics: const CruxEulaMetrics(iconSize: kBetaExpiryIconSize),
                child: TelemetryConsentGate(
                  // Only `iconSize` differs from the package defaults —
                  // SimCrux's chrome draws a 20 dp glyph where the package
                  // assumes 18. `touchTarget` and `bodyFontSize` are passed by
                  // omission because `kTelemetryConsentMinTarget` and the
                  // package's body size already equal `kBetaExpiryTouchTarget`
                  // and `kBetaExpiryBodyFontSize`; the telemetry consent-metrics
                  // test asserts that equality, so a future change to either
                  // constant fails there rather than quietly desynchronising the
                  // two surfaces. The 44 dp floor is enforced inside the package
                  // regardless of what is passed.
                  metrics: const CruxTelemetryConsentMetrics(
                    iconSize: kBetaExpiryIconSize,
                  ),
                  child: UpdateBanner(
                    child: _SimcruxAppChrome(child: child),
                  ),
                ),
              ),
            ),
          ),
        );
        // Windows/Linux: restore the drop shadow + drag-to-resize edges the
        // frameless window loses. No-op wrapper elsewhere.
        return useCustomWindowChrome ? buildWindowFrame(app) : app;
      },
    );
  }
}

/// The routed-content chrome: the CLI regression bootstrapper, the anchored
/// app-lifetime providers, the action dispatch table, the native menu bar and
/// the keyboard shortcut manager.
///
/// Separate from [SimcruxApp.build] because the beta-release infrastructure
/// (screenshot boundary, string-bundle scope, beta-expiry gate, update
/// banner) wraps it — inline, the builder closure is a five-deep wrapper
/// chain around a 40-line body.
class _SimcruxAppChrome extends StatelessWidget {
  const _SimcruxAppChrome({required this.child});

  /// The routed content from `MaterialApp.router`'s builder, or `null` before
  /// the router has produced a route.
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CliRegressionBootstrapper(
      child: Consumer(
        builder: (context, innerRef, _) {
          // Anchor the CXP-side providers so the notify_selection
          // emitter, inbound request handler, and rolling-events
          // buffer stay alive for the app's lifetime regardless of
          // whether the cross-probe panel is open. Each is a thin
          // provider that subscribes to the running CXP server.
          innerRef
            ..watch(notifySelectionEmitterProvider)
            ..watch(inboundRequestHandlerProvider)
            // Mirror the "request attention on cross-probe" preference
            // into the global window-attention backend for the app's lifetime.
            ..watch(cxpAttentionBridgeProvider)
            // Start CXP eagerly whenever "Enable cross-probe (CXP)" is on,
            // decoupled from the Cross-Probe Panel dialog. Watching the
            // discovery provider transitively builds cxpServerProvider (bind
            // + listen) and runs the discovery service, which publishes this
            // peer's manifest under ~/Library/Application Support/crux/cxp/
            // peers/ and watches for peers — so enabling the setting has an
            // observable effect without opening any dialog. Mirrors NetCrux's
            // CxpInboundListener eager-watch. Gated internally on
            // cxpServerEnabled: a disabled setting resolves to null and binds
            // nothing.
            ..watch(cxpDiscoveryProvider)
            // Registry↔workspace glue: records every opened config
            // into the project registry (recents / pins / switcher
            // / cross-project search stay true) and follows
            // registry-driven activation back into the workspace
            // tabs (so switcher selection + recents Reopen +
            // reopenRecentProject actually change the displayed
            // content). See ProjectWorkspaceSync.
            ..watch(projectWorkspaceSyncProvider);
          // Build the action → handler dispatch table. One source of
          // truth: the keyboard shortcut manager, the native menu
          // bar, and the command palette all dispatch through this
          // same map (see [SimcruxActionHandlers]). The outer builder
          // `context` is passed for the file-picker flows; every
          // dialog / route-push handler resolves a navigator context
          // internally.
          final handlers = SimcruxActionHandlers.build(context, innerRef);
          // Wrap the shortcut handlers in the native platform menu
          // bar so every user-facing action is reachable via the
          // browsable categorized menu in addition to the keyboard
          // and command palette. The menu bar is a no-op on web and
          // mobile (Flutter 3.x doesn't bridge PlatformMenuBar to
          // iOS/iPadOS or Android). Dispatch routes through the
          // same handlers map the palette dispatches through, so
          // one implementation serves all three discovery surfaces.
          return DesktopMenuBar(
            onAction: (action) => handlers[action]?.call(),
            child: ShortcutManagerWidget(
              handlers: handlers,
              child: child ?? const SizedBox.shrink(),
            ),
          );
        },
      ),
    );
  }
}
