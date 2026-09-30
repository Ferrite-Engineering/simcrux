// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';
import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_license/crux_license.dart';
import 'package:crux_projects/crux_projects.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/core/router/app_router.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_handlers.dart';
import 'package:simcrux/core/theme/simcrux_color_theme_bootstrap.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/retention_policy.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/config/providers/config_loader_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/projects/providers/project_list_openers.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/providers/retention_policy_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/lifecycle/app_exit_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../support/answered_telemetry.dart';

/// How a [SimcruxAction]'s handler is expected to behave when it is
/// dispatched in a stock **open-core** build with no project open.
///
/// The classification map below is pinned against `SimcruxAction.values`,
/// so a newly added action fails this test until its dispatch behaviour
/// is declared here. That pin is the point: the handler map is the single
/// routing surface shared by the keyboard, the native menu bar, and the
/// command palette, and an unclassified entry there is exactly how a
/// primary toolbar action ships enabled-but-broken.
enum _Dispatch {
  /// Shows `snackActionRequiresPro` — a Pro-tier action whose
  /// extension-point opener is null in open-core.
  proGatedSnack,

  /// Shows `snackActionUnavailableInThisBuild` — an open-core-tier
  /// action whose extension-point opener is not installed in this build.
  unavailableSnack,

  // A `notAvailableYetSnack` kind lived here for actions no tier could
  // activate. Its only two entries (the PR-annotation pair) became
  // Pro-reachable, leaving the kind with no members — and a test that
  // loops over zero entries passes while asserting nothing, which is
  // worse than no test. Removed with its production helper. The
  // `snackActionNotAvailableYet` ARB key survives in all five locales
  // for a future genuine deferral.

  // An `unimplementedSnack` kind lived here for the two focus actions, whose
  // handlers did nothing but show "not yet implemented". Hiding them from
  // the menu and palette left `Cmd/Ctrl+Shift+1`/`+2` bound, so the notice
  // was the whole feature; the actions were deleted rather than implemented
  // (F6 / Shift+F6 region traversal already moves focus between panes).
  // Removed with its production helper, like `notAvailableYetSnack` before
  // it. The `snackActionNotYetImplemented` ARB key survives in all five
  // locales for a future genuine stub.

  /// Shows `snackNoProjectOpen` — a project-scoped action with no project.
  noProjectSnack,

  // An `infoSnack` kind lived here for Pin Project Tab's "nothing to pin"
  // snack. Pinning became a Pro seam, leaving the kind with no members,
  // so it was removed rather than kept as a loop over zero entries.

  /// Opens a dialog or route; no snack.
  opensSurface,

  /// Mutates workspace/panel state directly; no snack, no dialog.
  mutatesState,

  /// Guarded no-op in this state (single pane, unmounted navigator).
  guardedNoOp,

  /// Drains in-flight regressions through the app-exit coordinator and
  /// then terminates. Exercised via an injected [processExitProvider].
  terminatesProcess,
}

/// Every action's expected open-core / no-project dispatch behaviour.
const Map<SimcruxAction, _Dispatch> _expectedDispatch = {
  // ── File ────────────────────────────────────────────────────────
  SimcruxAction.openProject: _Dispatch.opensSurface,
  SimcruxAction.importFusesoc: _Dispatch.opensSurface,
  // Both RISC-V imports open a directory picker first, exactly as the
  // FuseSoC import opens a file picker.
  SimcruxAction.importRiscvArchTest: _Dispatch.opensSurface,
  SimcruxAction.importRiscvFormal: _Dispatch.opensSurface,
  SimcruxAction.closeProject: _Dispatch.noProjectSnack,
  // Cmd/Ctrl+W (suite keyboard-parity pass) — same close-the-active-tab
  // implementation as closeProject, so the same no-project feedback.
  SimcruxAction.closeTab: _Dispatch.noProjectSnack,
  SimcruxAction.closeAllTabs: _Dispatch.noProjectSnack,
  SimcruxAction.runRegression: _Dispatch.noProjectSnack,
  SimcruxAction.cancelRegression: _Dispatch.noProjectSnack,
  SimcruxAction.reRunSelected: _Dispatch.noProjectSnack,
  // Export needs the active tab's result store, so with no project open the
  // handler reports "no project open" rather than opening a format picker
  // over nothing.
  SimcruxAction.exportResults: _Dispatch.noProjectSnack,
  SimcruxAction.quit: _Dispatch.terminatesProcess,
  // ── View / panes ────────────────────────────────────────────────
  SimcruxAction.toggleTestBrowser: _Dispatch.mutatesState,
  SimcruxAction.toggleInspector: _Dispatch.mutatesState,
  SimcruxAction.toggleLogPanel: _Dispatch.mutatesState,
  // Activates the opposite-brightness default color-theme preset via
  // cruxColorThemeProvider — pure state mutation, no snack, no dialog.
  SimcruxAction.toggleTheme: _Dispatch.mutatesState,
  SimcruxAction.splitPaneRight: _Dispatch.mutatesState,
  SimcruxAction.closePane: _Dispatch.guardedNoOp,
  SimcruxAction.focusOtherPane: _Dispatch.mutatesState,
  SimcruxAction.moveTabToOtherPane: _Dispatch.guardedNoOp,
  // ── Navigate / Search ───────────────────────────────────────────
  // Search now opens the real per-tab search dialog; with no tab there
  // is nothing to search, so the handler silently no-ops.
  SimcruxAction.openSearch: _Dispatch.guardedNoOp,
  // ── Tools / Help ────────────────────────────────────────────────
  SimcruxAction.openSettings: _Dispatch.opensSurface,
  SimcruxAction.openAbout: _Dispatch.opensSurface,
  // Tab Diagnostics needs the active tab's container; with no project the
  // handler reports "no project open" instead of opening an empty drawer.
  SimcruxAction.openTabDiagnostics: _Dispatch.noProjectSnack,
  SimcruxAction.openAppDiagnostics: _Dispatch.opensSurface,
  // Toggles the docked cross-probe panel's visibility flag rather
  // than opening a modal dialog.
  SimcruxAction.openCrossProbePanel: _Dispatch.mutatesState,
  SimcruxAction.openCommandPalette: _Dispatch.opensSurface,
  // Beta-release infrastructure. Both open a surface: the manual
  // update check shows its in-flight / outcome SnackBar, the issue reporter
  // opens its dialog. Neither is tier-gated in any build.
  SimcruxAction.checkForUpdates: _Dispatch.opensSurface,
  SimcruxAction.submitIssue: _Dispatch.opensSurface,
  // Hands docs.simcrux.app to the platform browser via the
  // `simcruxLaunchUrl` seam rather than opening an in-app surface.
  SimcruxAction.openDocumentation: _Dispatch.opensSurface,
  // ── Pro extension points (null openers in open-core) ────────────
  SimcruxAction.openSeedFailureHeatmap: _Dispatch.proGatedSnack,
  SimcruxAction.showTrendChart: _Dispatch.proGatedSnack,
  SimcruxAction.showSuiteTrendChart: _Dispatch.proGatedSnack,
  SimcruxAction.showCalendarHeatmap: _Dispatch.proGatedSnack,
  SimcruxAction.showFlakyTests: _Dispatch.proGatedSnack,
  SimcruxAction.configureRetentionPolicy: _Dispatch.proGatedSnack,
  SimcruxAction.openPluginManager: _Dispatch.proGatedSnack,
  SimcruxAction.reloadPlugins: _Dispatch.proGatedSnack,
  SimcruxAction.searchAcrossProjects: _Dispatch.proGatedSnack,
  // Multi-project registry semantics: Pro-tier seams whose openers are
  // null in open-core, so the snack matches the PRO badge the palette
  // and menu bar render.
  SimcruxAction.switchProject: _Dispatch.proGatedSnack,
  SimcruxAction.reopenRecentProject: _Dispatch.proGatedSnack,
  SimcruxAction.closeAllProjects: _Dispatch.proGatedSnack,
  SimcruxAction.pinActiveProject: _Dispatch.proGatedSnack,
  // PR annotation. Pro-gated, not deferred: open core binds
  // NoopPrAnnotationTargetStore and leaves both openers null, so the
  // Pro-gated snack is correct here. The Pro overlay registers the
  // Settings section and the dispatch opener, which is what makes
  // "requires SimCrux Pro" a true statement rather than "not available
  // yet".
  SimcruxAction.dispatchPrAnnotations: _Dispatch.proGatedSnack,
  SimcruxAction.configurePrAnnotationTarget: _Dispatch.proGatedSnack,
};

/// The open-core registry, recording every pin toggle it is asked for.
class _PinRecordingRegistry extends NoopProjectRegistry {
  final List<String> pinCalls = <String>[];

  @override
  Future<void> pinProject(String projectId, {required bool pinned}) {
    pinCalls.add(projectId);
    return super.pinProject(projectId, pinned: pinned);
  }
}

/// Driver that passes every test immediately, so a regression run in a
/// widget test finishes within a pump cycle.
class _PassingDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final started = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: started,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

TestSpec _spec(String id) => TestSpec(
  id: id,
  name: id.split('/').last,
  suiteName: id.split('/').first,
  simulatorId: 'icarus',
  top: 'tb',
);

RegressionConfig _config(List<TestSpec> tests) {
  final bySuite = <String, List<TestSpec>>{};
  for (final t in tests) {
    bySuite.putIfAbsent(t.suiteName, () => <TestSpec>[]).add(t);
  }
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      for (final e in bySuite.entries) Suite(name: e.key, tests: e.value),
    ],
    simulatorBinaries: const {},
  );
}

/// A [ConfigLoader] whose [load] returns [next] regardless of the path,
/// standing in for the on-disk `simcrux.yaml`.
///
/// The `runRegression` handler re-reads (re-parses) the project file on
/// every Run; these tests drive that path without a real file, and
/// mutating [next] between Runs simulates a user editing the config on
/// disk.
class _StubConfigLoader extends ConfigLoader {
  _StubConfigLoader(this.next);

  /// The config the next [load] call resolves to.
  RegressionConfig next;

  @override
  Future<RegressionConfig> load(String path) async => next;
}

/// Mirrors the two-phase container wiring from `bootstrap()`: a root
/// container carrying service overrides, per-tab / per-pane managers
/// parented to it, and a scoped child exposing the managers.
class _Harness {
  _Harness._(this.root, this.scoped, this.managers);

  final ProviderContainer root;
  final ProviderContainer scoped;
  final WorkspaceContainerManagers managers;

  /// The handler map captured from the last pumped frame.
  Map<SimcruxAction, VoidCallback> handlers = const {};

  static Future<_Harness> create({
    required Directory tempDir,
    List<Override> extraOverrides = const <Override>[],
  }) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    final root = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        settingsServiceProvider.overrideWithValue(
          SettingsService<AppSettings>(
            const SimcruxSettingsCodec(),
            prefsOverride: prefs,
          ),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => tempDir,
          ),
        ),
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _PassingDriver()}),
        ),
        trendStoreDirectoryOverrideProvider.overrideWithValue(tempDir.path),
        // A minimal router keeps the navigator context resolution the
        // handlers depend on real, without mounting the full workspace
        // screen (whose own async wiring would dominate the test).
        appRouterProvider.overrideWithValue(
          GoRouter(
            initialLocation: '/',
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) =>
                    const Scaffold(body: SizedBox.expand()),
              ),
            ],
          ),
        ),
        // The palette lists visible AND *enabled* actions now that SimCrux
        // has a descriptor table, so a harness with no loaded config would
        // show only the handful of workspace-independent commands. Pin a
        // fully-loaded context so these journeys exercise the full roster,
        // which is what they were written against. Individual tests can
        // still override it again through [extraOverrides].
        simcruxActionContextProvider.overrideWithValue(
          const SimcruxActionContext(
            hasOpenTab: true,
            hasConfig: true,
            hasResults: true,
            hasSelectedTest: true,
            paneCount: 2,
            tabCountInActivePane: 2,
          ),
        ),
        ...extraOverrides,
      ],
    );
    addTearDown(root.dispose);
    final managers = WorkspaceContainerManagers(
      tabs: crux.TabContainerManager(
        rootContainer: root,
        overridesFactory: root.read(simcruxTabOverridesFactoryProvider),
      ),
      panes: crux.PaneContainerManager(
        rootContainer: root,
        overridesFactory: simcruxPaneOverrides,
      ),
    );
    addTearDown(managers.dispose);
    final scoped = ProviderContainer(
      parent: root,
      overrides: [
        workspaceContainerManagersProvider.overrideWithValue(managers),
      ],
    );
    addTearDown(scoped.dispose);
    await scoped.read(workspaceProvider.future);
    return _Harness._(root, scoped, managers);
  }

  Widget wrap({Locale locale = const Locale('en')}) {
    return UncontrolledProviderScope(
      container: scoped,
      child: MaterialApp.router(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        routerConfig: scoped.read(appRouterProvider),
        builder: (context, child) => Consumer(
          builder: (innerContext, ref, _) {
            handlers = SimcruxActionHandlers.build(innerContext, ref);
            return child ?? const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  /// The per-tab container for the active tab, or null when no tab is open.
  ProviderContainer? activeTabContainer() {
    final id = scoped.read(workspaceProvider).value?.activeTabId;
    if (id == null) return null;
    return managers.tabs.containerFor(id);
  }
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('simcrux_handlers_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup.
      }
    }
  });

  Future<_Harness> pumpHarness(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    List<Override> extraOverrides = const <Override>[],
  }) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final harness = await _Harness.create(
      tempDir: tempDir,
      extraOverrides: extraOverrides,
    );
    await tester.pumpWidget(harness.wrap(locale: locale));
    await tester.pumpAndSettle();
    return harness;
  }

  /// Flushes the workspace autosave debounce (2s) so no Timer outlives
  /// the widget tree.
  Future<void> settleWorkspace(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  String? snackText(WidgetTester tester) {
    final finder = find.descendant(
      of: find.byType(SnackBar),
      matching: find.byType(Text),
    );
    if (finder.evaluate().isEmpty) return null;
    return tester.widget<Text>(finder.first).data;
  }

  group('handler map completeness', () {
    test('every SimcruxAction has a declared dispatch classification', () {
      expect(
        _expectedDispatch.keys.toSet(),
        SimcruxAction.values.toSet(),
        reason:
            'A new SimcruxAction must declare how its handler dispatches. '
            'Classifying it here forces the routing to be exercised below.',
      );
    });

    testWidgets('every SimcruxAction has a handler entry', (tester) async {
      final harness = await pumpHarness(tester);
      for (final action in SimcruxAction.values) {
        expect(
          harness.handlers.containsKey(action),
          isTrue,
          reason:
              '$action has no handler entry — it would render enabled in '
              'the menu bar / command palette and silently do nothing.',
        );
      }
    });
  });

  group('quit', () {
    testWidgets(
      'Quit drains in-flight regressions before terminating',
      (tester) async {
        final exitCodes = <int>[];
        final harness = await pumpHarness(
          tester,
          extraOverrides: [
            processExitProvider.overrideWithValue(exitCodes.add),
          ],
        );

        // A regression is mid-flight in some tab.
        var reaped = false;
        harness.root
            .read(activeRunRegistryProvider)
            .register(() async => reaped = true);

        harness.handlers[SimcruxAction.quit]!();
        await tester.pumpAndSettle();

        expect(
          reaped,
          isTrue,
          reason:
              'Quit must cancel in-flight runs — exit(0) alone orphaned '
              'every running simulator process tree.',
        );
        expect(exitCodes, <int>[0]);
      },
    );

    testWidgets('Quit with nothing running still terminates', (tester) async {
      final exitCodes = <int>[];
      final harness = await pumpHarness(
        tester,
        extraOverrides: [
          processExitProvider.overrideWithValue(exitCodes.add),
        ],
      );

      harness.handlers[SimcruxAction.quit]!();
      await tester.pumpAndSettle();

      expect(exitCodes, <int>[0]);
    });
  });

  group('snack selection', () {
    testWidgets('Pro-tier actions with a null opener say "requires Pro"', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      final l10n = await L10N.delegate.load(const Locale('en'));
      for (final entry in _expectedDispatch.entries) {
        if (entry.value != _Dispatch.proGatedSnack) continue;
        harness.handlers[entry.key]!();
        await tester.pumpAndSettle();
        expect(
          snackText(tester),
          l10n.snackActionRequiresPro(entry.key.label(l10n)),
          reason: '${entry.key} should surface the Pro-gated snack.',
        );
        expect(
          entry.key.requiredTier,
          isNot(LicenseTier.openCore),
          reason:
              '${entry.key} shows "requires SimCrux Pro" but declares the '
              'open-core tier — the snack would contradict its badge.',
        );
        ScaffoldMessenger.of(
          tester.element(find.byType(SnackBar)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    });

    testWidgets(
      'open-core-tier actions with a null opener make no tier claim',
      (
        tester,
      ) async {
        final harness = await pumpHarness(tester);
        final l10n = await L10N.delegate.load(const Locale('en'));
        final classified = _expectedDispatch.entries
            .where((e) => e.value == _Dispatch.unavailableSnack)
            .map((e) => e.key)
            .toSet();
        // No action carries this classification today: every
        // extension-point seam in SimCrux is Pro-tier, so `_snackProGated`
        // always takes its "requires SimCrux Pro" branch. The
        // `snackActionUnavailableInThisBuild` branch stays for the first
        // open-core seam that needs it — and this loop is what proves that
        // seam's snack makes no tier claim the moment it is classified here.
        expect(classified, isEmpty);
        for (final action in classified) {
          expect(action.requiredTier, LicenseTier.openCore);
          harness.handlers[action]!();
          await tester.pumpAndSettle();
          expect(
            snackText(tester),
            l10n.snackActionUnavailableInThisBuild(action.label(l10n)),
          );
          ScaffoldMessenger.of(
            tester.element(find.byType(SnackBar)),
          ).removeCurrentSnackBar();
          await tester.pumpAndSettle();
        }
      },
    );

    // An 'unlanded UI surfaces say "not yet implemented"' test lived here.
    // It went out with the `unimplementedSnack` kind: no action is classified
    // that way any more, and a loop over zero entries passes while asserting
    // nothing. The reachability guard in test/static is what now prevents an
    // action from shipping with no way to reach it.
  });

  group('pinActiveProject', () {
    testWidgets(
      'with a project open and no Pro opener, says it requires Pro and '
      'leaves the registry alone',
      (tester) async {
        // The open-core state the loop above cannot reach: a config tab is
        // recorded into NoopProjectRegistry, so there IS an active project,
        // and the old handler toggled a pin that registry never stores —
        // no state change, no feedback.
        final registry = _PinRecordingRegistry();
        await registry.openProject('/proj/simcrux.yaml');
        final harness = await pumpHarness(
          tester,
          extraOverrides: [projectRegistryProvider.overrideWithValue(registry)],
        );
        final l10n = await L10N.delegate.load(const Locale('en'));

        harness.handlers[SimcruxAction.pinActiveProject]!();
        await tester.pumpAndSettle();

        expect(
          snackText(tester),
          l10n.snackActionRequiresPro(
            SimcruxAction.pinActiveProject.label(l10n),
          ),
        );
        expect(registry.pinCalls, isEmpty);
      },
    );

    testWidgets('an installed opener receives the dispatch', (tester) async {
      final contexts = <BuildContext>[];
      final harness = await pumpHarness(
        tester,
        extraOverrides: [
          pinActiveProjectOpenerProvider.overrideWithValue(contexts.add),
        ],
      );

      harness.handlers[SimcruxAction.pinActiveProject]!();
      await tester.pumpAndSettle();

      expect(contexts, hasLength(1));
      expect(snackText(tester), isNull);
    });
  });

  group('no-project feedback', () {
    testWidgets('project-scoped actions snack instead of silently no-oping', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      final l10n = await L10N.delegate.load(const Locale('en'));
      for (final entry in _expectedDispatch.entries) {
        if (entry.value != _Dispatch.noProjectSnack) continue;
        harness.handlers[entry.key]!();
        await tester.pumpAndSettle();
        expect(
          snackText(tester),
          l10n.snackNoProjectOpen,
          reason:
              '${entry.key} fired with no project open and produced no '
              'feedback — a silent Run/Stop click reads as a broken app.',
        );
        ScaffoldMessenger.of(
          tester.element(find.byType(SnackBar)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('Re-run Selected with a project but no selection snacks', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      await harness.scoped
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'simcrux.yaml',
            payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
          );
      await tester.pumpAndSettle();
      final l10n = await L10N.delegate.load(const Locale('en'));
      harness.handlers[SimcruxAction.reRunSelected]!();
      await tester.pumpAndSettle();
      expect(snackText(tester), l10n.snackNoTestSelected);
      await settleWorkspace(tester);
    });

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('no-project snack is localized in $locale', (tester) async {
        final harness = await pumpHarness(tester, locale: locale);
        harness.handlers[SimcruxAction.runRegression]!();
        await tester.pumpAndSettle();
        final l10n = await L10N.delegate.load(locale);
        expect(snackText(tester), l10n.snackNoProjectOpen);
        expect(snackText(tester), isNotEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('pane guards', () {
    testWidgets('closePane / moveTabToOtherPane no-op with a single pane', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      await harness.scoped
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'simcrux.yaml',
            payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
          );
      await tester.pumpAndSettle();
      final before = harness.scoped.read(workspaceProvider).value!;
      expect(before.panes.length, 1);

      harness.handlers[SimcruxAction.closePane]!();
      harness.handlers[SimcruxAction.moveTabToOtherPane]!();
      await tester.pumpAndSettle();

      final after = harness.scoped.read(workspaceProvider).value!;
      expect(after.panes.length, 1);
      expect(after.tabs.length, before.tabs.length);
      expect(tester.takeException(), isNull);
      await settleWorkspace(tester);
    });

    testWidgets('splitPaneRight then closePane returns to a single pane', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      await harness.scoped
          .read(workspaceProvider.notifier)
          .openTab(
            displayName: 'simcrux.yaml',
            payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
          );
      await tester.pumpAndSettle();

      harness.handlers[SimcruxAction.splitPaneRight]!();
      await tester.pumpAndSettle();
      expect(harness.scoped.read(workspaceProvider).value!.panes.length, 2);

      harness.handlers[SimcruxAction.closePane]!();
      await tester.pumpAndSettle();
      expect(harness.scoped.read(workspaceProvider).value!.panes.length, 1);
      await settleWorkspace(tester);
    });
  });

  group('toggleTheme', () {
    testWidgets('flips the rendered brightness between Crux Dark and Light', (
      tester,
    ) async {
      // MaterialApp.themeMode is derived from the active preset's brightness
      // (`themeModeFromBrightness` in app.dart), so the toggle has to change
      // the preset, through the same notifier override the app installs, and
      // persist it.
      final harness = await pumpHarness(
        tester,
        extraOverrides: [simcruxCruxColorThemeOverride],
      );
      await harness.scoped.read(appSettingsProvider.future);
      ThemeMode rendered() =>
          themeModeFromBrightness(harness.scoped.read(cruxColorThemeProvider));
      expect(rendered(), ThemeMode.dark);

      harness.handlers[SimcruxAction.toggleTheme]!();
      await tester.pumpAndSettle();
      expect(harness.scoped.read(cruxColorThemeProvider).id, cruxLightPresetId);
      expect(rendered(), ThemeMode.light);
      expect(
        harness.scoped.read(appSettingsProvider).value?.core.activeThemeName,
        cruxLightPresetId,
      );

      harness.handlers[SimcruxAction.toggleTheme]!();
      await tester.pumpAndSettle();
      expect(harness.scoped.read(cruxColorThemeProvider).id, cruxDarkPresetId);
      expect(rendered(), ThemeMode.dark);
      await settleWorkspace(tester);
    });
  });

  group('closeAllTabs', () {
    testWidgets('confirms before closing and cancelling keeps every tab', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      final notifier = harness.scoped.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: 'a.yaml',
        payload: SimcruxTabPayload(configPath: '/a/simcrux.yaml'),
      );
      await notifier.openTab(
        displayName: 'b.yaml',
        payload: SimcruxTabPayload(configPath: '/b/simcrux.yaml'),
      );
      await tester.pumpAndSettle();
      expect(harness.scoped.read(workspaceProvider).value!.tabs.length, 2);

      harness.handlers[SimcruxAction.closeAllTabs]!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirmDialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirmDialogCancel')));
      await tester.pumpAndSettle();
      expect(harness.scoped.read(workspaceProvider).value!.tabs.length, 2);
      await settleWorkspace(tester);
    });

    testWidgets('confirming closes every open workspace tab', (
      tester,
    ) async {
      final harness = await pumpHarness(tester);
      final notifier = harness.scoped.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: 'a.yaml',
        payload: SimcruxTabPayload(configPath: '/a/simcrux.yaml'),
      );
      await notifier.openTab(
        displayName: 'b.yaml',
        payload: SimcruxTabPayload(configPath: '/b/simcrux.yaml'),
      );
      await tester.pumpAndSettle();

      harness.handlers[SimcruxAction.closeAllTabs]!();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDialogConfirm')));
      await tester.pumpAndSettle();

      // No registry involvement: closeAllTabs closes the tabs and
      // nothing else. This is the tier-free capability that survives
      // closeAllProjects becoming Pro.
      expect(harness.scoped.read(workspaceProvider).value!.tabs, isEmpty);
      await settleWorkspace(tester);
    });
  });

  group('reRunSelected', () {
    testWidgets(
      'runs exactly the selected test and leaves activeConfig intact',
      (tester) async {
        final harness = await pumpHarness(tester);
        await harness.scoped
            .read(workspaceProvider.notifier)
            .openTab(
              displayName: 'simcrux.yaml',
              payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
            );
        await tester.pumpAndSettle();
        final tab = harness.activeTabContainer()!;

        // Two suites — the shape the config-narrowing implementation got
        // wrong: it shrank only the selected test's suite and left every
        // other suite's tests in the config that start() flattens.
        final config = _config([
          _spec('unit/alu'),
          _spec('unit/regfile'),
          _spec('integration/soc'),
          _spec('integration/dma'),
        ]);

        // `dashboardRowsProvider` is a StreamProvider; keeping a live
        // listener on it means `selectedTestProvider` (which needs a row
        // for the selected id) resolves against real data rather than
        // AsyncLoading.
        final rowsSub = tab.listen(dashboardRowsProvider, (_, _) {});
        addTearDown(rowsSub.close);

        // The scheduler and its drivers run on the real event loop, so
        // the runs must be driven inside runAsync — fake-async pumps
        // would never advance them.
        await tester.runAsync(() async {
          final done = _waitForFinish(tab);
          await tab.read(regressionRunnerProvider.notifier).start(config);
          await done.timeout(const Duration(seconds: 30));
          await tab
              .read(dashboardRowsProvider.future)
              .timeout(const Duration(seconds: 30));
        });
        await tester.pumpAndSettle();
        expect(tab.read(regressionRunnerProvider).value!.run.testIds.length, 4);

        tab.read(selectedTestIdProvider.notifier).select('unit/alu');
        await tester.pumpAndSettle();
        expect(tab.read(selectedTestProvider)?.spec?.id, 'unit/alu');

        await tester.runAsync(() async {
          final done = _waitForFinish(tab);
          harness.handlers[SimcruxAction.reRunSelected]!();
          await done.timeout(const Duration(seconds: 30));
        });
        await tester.pumpAndSettle();

        expect(
          tab.read(regressionRunnerProvider).value!.run.testIds,
          ['unit/alu'],
          reason:
              'Re-run Selected must submit exactly the selected spec, not '
              'the selected spec plus every other suite in the config.',
        );
        final active = tab.read(activeConfigProvider);
        expect(active, isNotNull);
        expect(active!.suites.length, 2);
        expect(
          active.suites.expand((s) => s.tests).map((t) => t.id).toList(),
          ['unit/alu', 'unit/regfile', 'integration/soc', 'integration/dma'],
          reason:
              'Re-run Selected must not republish a narrowed config — the '
              'next plain Run Regression would silently run a subset.',
        );
        await settleWorkspace(tester);
      },
    );
  });

  group('palette → handler-map action-dispatch journey', () {
    // Every test above dispatches by calling `harness.handlers[action]!()`
    // directly — the fastest way to pin each handler's *behavior*, but it
    // never proves the UI SELECTION mechanism (palette row tap → onAction
    // → handlers[action]()) is wired correctly. This group closes that
    // gap: it opens the real `CommandPaletteDialog` via the real
    // `openCommandPalette` handler (itself part of the map under test),
    // interacts with the real search field / row `InkWell`s from
    // `crux_command_palette`, and asserts the SAME real handler fired —
    // doubling the handler-map net at the integration level.
    const stubBuildInfo = ApplicationBuildInfo(
      version: '1.2.3',
      buildNumber: '42',
      gitShortSha: 'abc1234',
      os: 'macOS 15.0',
      architecture: 'arm64',
      flutterSdkVersion: '3.29.0',
      dartSdkVersion: '3.7.0',
    );

    Future<void> openPalette(WidgetTester tester, _Harness harness) async {
      harness.handlers[SimcruxAction.openCommandPalette]!();
      await tester.pumpAndSettle();
    }

    // `find.text('...')` matches BOTH a `Text` widget with that data AND an
    // `EditableText` whose controller currently holds that same string —
    // so once the search field's typed query equals a row's own label,
    // `find.text(label)` is ambiguous (finds the field AND the row). This
    // scopes the match to the row's `Text` widget only.
    Finder paletteRow(String label) =>
        find.byWidgetPredicate((w) => w is Text && w.data == label);

    testWidgets(
      'typing a query filters the real palette down to matching rows',
      (tester) async {
        final harness = await pumpHarness(
          tester,
          extraOverrides: [
            aboutBuildInfoProvider.overrideWith((_) async => stubBuildInfo),
          ],
        );
        await openPalette(tester, harness);

        // Unfiltered: the palette's `ListView` is virtualized to
        // `_maxVisibleItems` (8) rows, so only the FIRST few
        // enum-declaration-order actions are actually built. "Open
        // Config…" is one of them — this is the "before" baseline.
        expect(paletteRow('Open Config…'), findsOneWidget);
        // "About SimCrux" is declared much later in the enum and is
        // NOT among the unfiltered visible rows.
        expect(paletteRow('About SimCrux'), findsNothing);

        await tester.enterText(find.byType(TextField), 'About SimCrux');
        await tester.pumpAndSettle();

        // The real fuzzy-search filter surfaced the row that wasn't
        // originally rendered…
        expect(paletteRow('About SimCrux'), findsOneWidget);
        // …and narrowed away the previously-visible unrelated row.
        expect(paletteRow('Open Config…'), findsNothing);
        await settleWorkspace(tester);
      },
    );

    testWidgets(
      'selecting "About SimCrux" from the real palette opens the real '
      'About dialog',
      (tester) async {
        final harness = await pumpHarness(
          tester,
          extraOverrides: [
            aboutBuildInfoProvider.overrideWith((_) async => stubBuildInfo),
          ],
        );
        await openPalette(tester, harness);

        await tester.enterText(find.byType(TextField), 'About SimCrux');
        await tester.pumpAndSettle();
        await tester.tap(paletteRow('About SimCrux'));
        // The palette dispatch (`_execute`) pops immediately, then the
        // handler awaits the build-info future before the About dialog
        // itself opens — mirrors `_openDialog` in
        // simcrux_about_dialog_test.dart.
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        // The palette itself is gone (it popped before dispatching)…
        expect(find.byType(TextField), findsNothing);
        // …and the real openAbout handler rendered the real dialog,
        // built from the overridden build-info stub — proof the palette
        // row tap actually reached `handlers[SimcruxAction.openAbout]`.
        expect(find.text('1.2.3'), findsWidgets);
        expect(find.text('abc1234'), findsWidgets);
        await settleWorkspace(tester);
      },
    );

    testWidgets(
      'selecting a Pro-gated action from the real palette surfaces the '
      'real "requires SimCrux Pro" snack',
      (tester) async {
        final harness = await pumpHarness(tester);
        final l10n = await L10N.delegate.load(const Locale('en'));
        final label = SimcruxAction.showFlakyTests.label(l10n);
        await openPalette(tester, harness);

        await tester.enterText(find.byType(TextField), label);
        await tester.pumpAndSettle();
        await tester.tap(paletteRow(label));
        await tester.pumpAndSettle();

        expect(
          snackText(tester),
          l10n.snackActionRequiresPro(label),
          reason:
              'The palette-driven dispatch for a Pro-gated action must '
              'reach the exact same snack the direct-call harness net '
              'pins in the "snack selection" group above.',
        );
        await settleWorkspace(tester);
      },
    );

    testWidgets(
      'selecting "Settings…" from the real palette opens the real Settings '
      'dialog',
      (tester) async {
        final harness = await pumpHarness(tester);
        await openPalette(tester, harness);

        await tester.enterText(find.byType(TextField), 'Settings…');
        await tester.pumpAndSettle();
        await tester.tap(paletteRow('Settings…'));
        await tester.pumpAndSettle();

        expect(find.byType(TextField), findsNothing);
        expect(find.text('Settings'), findsWidgets);
        await settleWorkspace(tester);
      },
    );
  });

  group('runRegression → retention-enforcement journey', () {
    // `regression_runner_test.dart`'s "RegressionRunner retention
    // enforcement" group already pins the retention behavior itself by
    // calling `regressionRunnerProvider.notifier.start(config)` directly
    // against a bare `ProviderContainer` — a unit-level check of
    // `_applyRetentionBestEffort`. This test instead drives the SAME
    // end-to-end effect through the real discovery-surface path: the
    // `SimcruxAction.runRegression` handler (what the toolbar / menu bar
    // / command palette all actually dispatch), against the real
    // `LocalJobScheduler`, real driver, and real on-disk `SqlTrendStore`
    // this harness wires up — proving retention enforcement survives the
    // full "user clicks Run Regression" journey, not just a direct
    // notifier call.
    testWidgets(
      'dispatching the real runRegression handler still prunes the trend '
      'store down to the configured retention policy',
      (tester) async {
        // The `runRegression` handler re-reads the project file from disk
        // on Run, so stub the loader to return the run's config
        // rather than pointing at a non-existent `/proj/simcrux.yaml`.
        final config = _config([
          _spec('unit/alu'),
          _spec('unit/regfile'),
          _spec('unit/decoder'),
        ]);
        final harness = await pumpHarness(
          tester,
          extraOverrides: [
            configLoaderProvider.overrideWithValue(_StubConfigLoader(config)),
          ],
        );
        await harness.scoped
            .read(workspaceProvider.notifier)
            .openTab(
              displayName: 'simcrux.yaml',
              payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
            );
        await tester.pumpAndSettle();
        final tab = harness.activeTabContainer()!;

        // Policy retains a single data point; the 3-test run ingests 3.
        tab
            .read(retentionPolicyProvider.notifier)
            .replace(const RetentionPolicy(maxDataPoints: 1));

        // Prime `activeConfigProvider` so the handler has a path to reload
        // from; in production the project-open flow populates it.
        tab.read(activeConfigProvider.notifier).replace(config);

        // Mirrors reRunSelected's harness above: keeping a live listener
        // on the (Riverpod-paused-when-unwatched) `dashboardRowsProvider`
        // stream is required for the run to actually settle.
        final rowsSub = tab.listen(dashboardRowsProvider, (_, _) {});
        addTearDown(rowsSub.close);

        // `TrendStore.storageStats()` (like the regression run itself)
        // performs real SQLite FFI I/O, so the read must stay inside
        // `runAsync` alongside the run — reading it on the bare
        // fake-async pump zone left a real `Future` completion
        // scheduled outside FakeAsync's synthetic queue, so every
        // subsequent `pump()` (even a bare single-frame one) hung
        // forever waiting on it and the test runner had to SIGTERM the
        // subprocess. Same class of bug as the "real file IO inside
        // testWidgets must go through tester.runAsync" rule.
        late int dataPointCount;
        await tester.runAsync(() async {
          final done = _waitForFinish(tab);
          // The real dispatch path: same closure the toolbar Run
          // button, the native menu bar, and the command palette all
          // invoke for this action.
          harness.handlers[SimcruxAction.runRegression]!();
          await done.timeout(const Duration(seconds: 15));
          await tab
              .read(dashboardRowsProvider.future)
              .timeout(const Duration(seconds: 15));
          final trendStore = await tab
              .read(trendStoreProvider.future)
              .timeout(const Duration(seconds: 15));
          final stats = await trendStore.storageStats().timeout(
            const Duration(seconds: 15),
          );
          dataPointCount = stats.dataPointCount;
        });
        await tester.pumpAndSettle();

        expect(tab.read(regressionRunnerProvider).value!.run.testIds.length, 3);
        expect(
          dataPointCount,
          1,
          reason:
              'Run Regression dispatched through the real handler map '
              'must still trigger the post-run retention prune, exactly '
              'as the direct notifier.start(config) unit test proves.',
        );
        await settleWorkspace(tester);
      },
    );
  });
  group('runRegression → reloads the edited config from disk', () {
    testWidgets(
      'Run picks up an on-disk config edit (added tests) without an app '
      'relaunch — it runs the freshly-parsed set, not the armed parse',
      (tester) async {
        // The tab is armed with the pre-edit 1-test parse; the "on-disk"
        // file (the stub loader) already holds the edited 3-test version,
        // as if the user changed simcrux.yaml while the tab was open.
        final armed = _config([_spec('unit/alu')]);
        final edited = _config([
          _spec('unit/alu'),
          _spec('unit/regfile'),
          _spec('unit/decoder'),
        ]);
        final loader = _StubConfigLoader(edited);
        final harness = await pumpHarness(
          tester,
          extraOverrides: [
            configLoaderProvider.overrideWithValue(loader),
          ],
        );
        await harness.scoped
            .read(workspaceProvider.notifier)
            .openTab(
              displayName: 'simcrux.yaml',
              payload: SimcruxTabPayload(configPath: '/proj/simcrux.yaml'),
            );
        await tester.pumpAndSettle();
        final tab = harness.activeTabContainer()!;

        // Arm with the STALE parse the tab was opened with.
        tab.read(activeConfigProvider.notifier).replace(armed);
        expect(
          tab.read(activeConfigProvider)!.suites.expand((s) => s.tests).length,
          1,
        );

        final rowsSub = tab.listen(dashboardRowsProvider, (_, _) {});
        addTearDown(rowsSub.close);

        await tester.runAsync(() async {
          final done = _waitForFinish(tab);
          harness.handlers[SimcruxAction.runRegression]!();
          await done.timeout(const Duration(seconds: 15));
          await tab
              .read(dashboardRowsProvider.future)
              .timeout(const Duration(seconds: 15));
        });
        await tester.pumpAndSettle();

        // The run submitted the EDITED (reloaded) test set, not the armed
        // one — proof the Run re-parsed the file on disk.
        expect(
          tab.read(regressionRunnerProvider).value!.run.testIds.length,
          3,
        );
        // …and the active config was replaced by the fresh on-disk parse,
        // so every downstream surface (filters, watcher, next Run) now sees
        // the edit.
        expect(
          tab.read(activeConfigProvider)!.suites.expand((s) => s.tests).length,
          3,
        );
        await settleWorkspace(tester);
      },
    );
  });
}

/// Completes when the tab's runner publishes a finished run state.
Future<RegressionRunState> _waitForFinish(ProviderContainer tab) {
  final completer = Completer<RegressionRunState>();
  final sub = tab.listen<AsyncValue<RegressionRunState?>>(
    regressionRunnerProvider,
    (_, next) {
      final value = next.value;
      if (value != null && value.isFinished && !completer.isCompleted) {
        completer.complete(value);
      }
    },
  );
  return completer.future.whenComplete(sub.close);
}
