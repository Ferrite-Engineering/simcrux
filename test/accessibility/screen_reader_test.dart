// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a screen reader user hears in SimCrux, asserted.
//
// The first external NVDA pass (Windows 11, NVDA 2026.1, on WaveCrux) found
// silence at launch, bare "text" Tab stops and rows announced as loose
// fragments while every automated guard was green. These cases walk SimCrux's
// real workspace screen the same way: focus must land somewhere named, every
// Tab stop must carry one name, and a results row must be one sentence. The
// transcripts under `goldens/` are what the focus walk records; a change in
// what is announced shows up as a diff there. Rewrite them with
// `flutter test --update-goldens test/accessibility` and read the diff before
// committing it.

import 'dart:io';

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/result_store.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/dashboard/widgets/test_browser_panel.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/simcrux_pane_overrides.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/screens/workspace_screen.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/features/workspace/widgets/regression_tab_content.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../support/recording_telemetry_service.dart';

// ── harness ─────────────────────────────────────────────────────────────────

const _configPath = '/kit/simcrux.yaml';

/// The walks run as Windows, the platform of the NVDA pass. Material widgets
/// shape their semantics by platform — `ExpansionTile` adds an Android-only
/// live-region label — so the default test platform would record wording no
/// desktop screen reader hears.
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);

/// The two-phase container wiring from `bootstrap()` in `lib/app.dart`, as in
/// `workspace_screen_test.dart`, with a hook for per-tab overrides.
class _Harness {
  _Harness._(this.scoped);

  final ProviderContainer scoped;

  static Future<_Harness> create({
    required Directory workspaceDir,
    required SharedPreferences prefs,
    List<Override> Function(crux.TabId)? extraTabOverrides,
  }) async {
    late final WorkspaceContainerManagers managers;
    final root = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        settingsServiceProvider.overrideWithValue(
          SettingsService<AppSettings>(
            const SimcruxSettingsCodec(),
            prefsOverride: prefs,
          ),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(
          crux.WorkspaceService<SimcruxTabPayload>(
            codec: const SimcruxWorkspaceCodec(),
            directoryFactory: () async => workspaceDir,
          ),
        ),
        // The trend surfaces read SQLite; the walk is about what is heard,
        // so they get fixed, empty data.
        recentTrendDeltasProvider.overrideWith(
          (ref) async => const <TrendDelta>[],
        ),
        testTrendProvider.overrideWith((ref, _) async => const <TestStatus>[]),
        // Opening a config records `project.opened`; nothing here transmits.
        telemetryServiceProvider.overrideWithValue(RecordingTelemetryService()),
        workspaceContainerManagersProvider.overrideWith((_) => managers),
      ],
    );
    addTearDown(root.dispose);
    managers = WorkspaceContainerManagers(
      tabs: crux.TabContainerManager(
        rootContainer: root,
        // The extra overrides replace the per-tab defaults for the same
        // providers; a container rejects two overrides of one provider.
        overridesFactory: (tabId) {
          final extra = extraTabOverrides?.call(tabId) ?? const <Override>[];
          final replaced = {for (final o in extra) o.origin};
          return [
            for (final o in simcruxTabOverrides(tabId))
              if (!replaced.contains(o.origin)) o,
            ...extra,
          ];
        },
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
    return _Harness._(scoped);
  }

  Widget wrap() {
    return UncontrolledProviderScope(
      container: scoped,
      child: const MaterialApp(
        localizationsDelegates: [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: WorkspaceScreen(),
      ),
    );
  }
}

void _useDesktopWindow(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1600, 1000)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

TestSpec _spec(String suite, String name, String simulator) => TestSpec(
  id: '$suite/$name',
  name: name,
  suiteName: suite,
  simulatorId: simulator,
  top: 'tb_$name',
  sources: ['/kit/tb_$name.v'],
);

final _specs = <TestSpec>[
  _spec('uart', 'tx_basic', 'icarus'),
  _spec('uart', 'rx_parity', 'icarus'),
  _spec('spi', 'loopback', 'verilator'),
];

RegressionConfig _config() => RegressionConfig(
  projectFilePath: _configPath,
  schemaVersion: '1',
  suites: [
    Suite(name: 'uart', tests: [_specs[0], _specs[1]]),
    Suite(name: 'spi', tests: [_specs[2]]),
  ],
  simulatorBinaries: const {
    'icarus': SimulatorBinaryConfig(simulatorId: 'icarus'),
    'verilator': SimulatorBinaryConfig(simulatorId: 'verilator'),
  },
);

class _LoadedConfig extends ActiveConfigNotifier {
  @override
  RegressionConfig? build() => _config();
}

/// [_config] plus a test the finished run never reached.
class _ConfigWithUnrunTest extends ActiveConfigNotifier {
  @override
  RegressionConfig? build() {
    final base = _config();
    return RegressionConfig(
      projectFilePath: base.projectFilePath,
      schemaVersion: base.schemaVersion,
      suites: [
        base.suites.first,
        Suite(
          name: 'spi',
          tests: [_specs[2], _spec('spi', 'cs_glitch', 'verilator')],
        ),
      ],
      simulatorBinaries: base.simulatorBinaries,
    );
  }
}

/// The native open dialog, answered with [path].
class _PickedConfig extends FilePickerPlatform with MockPlatformInterfaceMixin {
  _PickedConfig(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
    AndroidSAFOptions? androidSafOptions,
  }) async => FilePickerResult([
    PlatformFile(name: path.split('/').last, size: 0, path: path),
  ]);
}

class _FinishedRun extends ResultStoreNotifier {
  _FinishedRun(this._store);

  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

Future<InMemoryResultStore> _finishedRunStore() async {
  final started = DateTime.utc(2026, 5, 1, 14, 3);
  final run = TestRun(
    id: 'r1',
    startedAt: started,
    testIds: [for (final s in _specs) s.id],
  );
  final store = InMemoryResultStore.forRun(run);
  const statuses = [TestStatus.pass, TestStatus.fail, TestStatus.pass];
  const runtimes = [1200, 350, 2400];
  for (var i = 0; i < _specs.length; i++) {
    await store.recordResult(
      TestResult(
        testId: _specs[i].id,
        runId: 'r1',
        status: statuses[i],
        startedAt: started,
        finishedAt: started.add(Duration(milliseconds: runtimes[i])),
      ),
    );
  }
  // A finished run replays its snapshot to every subscriber; the rows table
  // and the status bar both subscribe after it was recorded.
  await store.recordRunCompletion(
    RunSummary(
      runId: 'r1',
      startedAt: started,
      finishedAt: started.add(const Duration(seconds: 3)),
      totalsByStatus: const <TestStatus, int>{
        TestStatus.pass: 2,
        TestStatus.fail: 1,
      },
    ),
  );
  return store;
}

// ── tests ───────────────────────────────────────────────────────────────────

void main() {
  const goldens = 'test/accessibility/goldens';
  late Directory workspaceDir;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
    workspaceDir = Directory.systemTemp.createTempSync('a11y_workspace');
  });

  tearDown(() {
    if (workspaceDir.existsSync()) workspaceDir.deleteSync(recursive: true);
  });

  testWidgets('launch puts focus on Open Config, so something is announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _useDesktopWindow(tester);
    final harness = await _Harness.create(
      workspaceDir: workspaceDir,
      prefs: prefs,
    );
    await tester.pumpWidget(harness.wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final l10n = L10N.of(tester.element(find.byType(WorkspaceScreen)));
    expectFocusAnnounced(
      tester,
      named: l10n.emptyCanvasOpenConfig,
      context: 'launch',
    );
    final walk = await walkFocus(tester);
    expectCleanFocusWalk(walk, context: 'start screen');
    expectFocusWalkGolden(walk, '$goldens/start_screen.txt');
    handle.dispose();
  }, variant: _desktop);

  testWidgets('opening a config from the start screen leaves focus on a '
      'named control', (tester) async {
    // The first SimCrux walk found focus stranded on the window here: the
    // focused Open Config button is rebuilt away when the tab replaces the
    // start screen, and nothing claimed focus in its place, so a screen
    // reader announced nothing and screen shortcuts had nowhere to fire from.
    final handle = tester.ensureSemantics();
    _useDesktopWindow(tester);
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _PickedConfig(_configPath);
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    final harness = await _Harness.create(
      workspaceDir: workspaceDir,
      prefs: prefs,
      // The config the picker returns does not exist on disk; the tab starts
      // with it already loaded so the runner never reads it.
      extraTabOverrides: (_) => [
        activeConfigProvider.overrideWith(_LoadedConfig.new),
      ],
    );
    await tester.pumpWidget(harness.wrap());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final l10n = L10N.of(tester.element(find.byType(WorkspaceScreen)));
    expectFocusAnnounced(
      tester,
      named: l10n.emptyCanvasOpenConfig,
      context: 'launch',
    );

    // Enter on the focused button: the keyboard route through the real
    // picker flow, not a direct openTab call.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    // The widget starts the tab's real file I/O itself, so there is no
    // operation to wrap in runAsync; poll with a bound instead.
    for (
      var i = 0;
      i < 50 && find.byType(RegressionTabContent).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byType(RegressionTabContent), findsOneWidget);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expectFocusAnnounced(
      tester,
      context: 'config opened from the start screen',
    );

    await tester.runAsync(
      harness.scoped.read(workspaceProvider.notifier).flushPendingSave,
    );
    await tester.pump(const Duration(milliseconds: 100));
    handle.dispose();
  }, variant: _desktop);

  testWidgets('Tests dock: suites are expandable buttons, tests carry their '
      'status', (tester) async {
    final handle = tester.ensureSemantics();
    _useDesktopWindow(tester);
    final store = await _finishedRunStore();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeConfigProvider.overrideWith(_ConfigWithUnrunTest.new),
          resultStoreProvider.overrideWith(() => _FinishedRun(store)),
        ],
        child: const MaterialApp(
          localizationsDelegates: [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: Scaffold(
            body: SizedBox(width: 320, child: TestBrowserPanel()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final walk = await walkFocus(tester);
    expectCleanFocusWalk(walk, context: 'Tests dock');
    // "uart text" before: the tile's expand wording is a hint, which the
    // desktop bridges drop, and the status was only an icon's color.
    expect(
      walk.stops.map((s) => s.line),
      containsAllInOrder(<String>[
        'uart button expanded',
        'tx_basic, Pass button',
        'rx_parity, Fail button',
        'spi button expanded',
        'loopback, Pass button',
        'cs_glitch, not run button',
      ]),
    );
    expectFocusWalkGolden(walk, '$goldens/tests_dock.txt');

    // The walk cycled back to the first stop, the uart header. Collapsing it
    // is heard as a state change on the same button, and its tests leave
    // the Tab order.
    expect(describeFocus(tester).name, 'uart');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    final header = describeFocus(tester);
    expect(header.name, 'uart');
    expect(header.role, 'button');
    expect(header.states, contains('collapsed'));
    final collapsed = await walkFocus(tester);
    expectCleanFocusWalk(collapsed, context: 'Tests dock, uart collapsed');
    expect(
      collapsed.stops.map((s) => s.line),
      isNot(anyElement(startsWith('tx_basic'))),
    );
    handle.dispose();
  }, variant: _desktop);

  testWidgets('each results row is one named sentence, and the walk is clean', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _useDesktopWindow(tester);
    final store = await _finishedRunStore();
    final harness = await _Harness.create(
      workspaceDir: workspaceDir,
      prefs: prefs,
      extraTabOverrides: (_) => [
        activeConfigProvider.overrideWith(_LoadedConfig.new),
        resultStoreProvider.overrideWith(() => _FinishedRun(store)),
      ],
    );
    await tester.pumpWidget(harness.wrap());
    await tester.pump();
    final notifier = harness.scoped.read(workspaceProvider.notifier);
    // openTab's save path does real file I/O, which never completes inside
    // the fake-async test zone.
    await tester.runAsync(
      () => notifier.openTab(
        displayName: 'simcrux.yaml',
        payload: SimcruxTabPayload(configPath: _configPath),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final l10n = L10N.of(tester.element(find.byType(WorkspaceScreen)));
    expect(find.text(l10n.dashboardLoading), findsNothing);
    final walk = await walkFocus(tester);
    expectCleanFocusWalk(walk, context: 'results dashboard');
    final lines = walk.stops.map((s) => s.line).toList();
    for (final (status, spec, runtime) in [
      (TestStatus.pass, _specs[0], '1.2s'),
      (TestStatus.fail, _specs[1], '350ms'),
      (TestStatus.pass, _specs[2], '2.4s'),
    ]) {
      final sentence = l10n.accessibilityResultRow(
        testStatusLabel(l10n, status),
        spec.suiteName,
        spec.name,
        spec.simulatorId,
        runtime,
      );
      // One stop per row, and that stop is the sentence — the row's check
      // box — not a grouping that repeats the status followed by a second,
      // unnamed stop for the check box.
      expect(
        lines.where((line) => line.contains(sentence)),
        [endsWith('$sentence check box not checked')],
        reason: 'row ${spec.id}',
      );
    }
    expect(lines, isNot(anyElement(endsWith('] check box not checked'))));
    expectFocusWalkGolden(walk, '$goldens/results_dashboard.txt');

    await tester.runAsync(notifier.flushPendingSave);
    await tester.pump(const Duration(milliseconds: 100));
    handle.dispose();
  }, variant: _desktop);
}
