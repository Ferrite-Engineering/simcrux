// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_eula/crux_eula.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/cli_args_provider.dart';
import 'package:simcrux/core/platform/incoming_file_service.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/dashboard/widgets/cli_regression_bootstrapper.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../../../support/answered_telemetry.dart';

const Key _kChildKey = Key('bootstrapper-child');

/// In-memory [WorkspaceService] whose futures complete on the **microtask**
/// queue rather than the real event loop.
///
/// Why this, rather than a real service over a temp directory: the
/// bootstrapper kicks its own work off from a post-frame callback, so the
/// resulting `WorkspaceService` futures are created *inside* the fake-async
/// zone `testWidgets` runs in. A `dart:io` future created there completes
/// only once the real event loop has delivered the I/O **and** the fake
/// zone's microtask queue has since been drained by a `pump()`. Because the
/// widget — not the test — starts that work, there is no operation to wrap in
/// `tester.runAsync`, and the shape this file used to have (sleep a fixed
/// 50 ms on the real loop, then settle) was a bet that the I/O would land
/// inside that window. Roughly 2x machine load was enough to lose the bet,
/// and losing it did not fail the test: the later
/// `runAsync(() => container.read(workspaceProvider.future))` waited forever,
/// because `runAsync` suspends the test body, so nothing pumps the fake zone,
/// so the notifier's `build()` continuation never runs, so the future being
/// awaited can never complete. Nothing bounds that deadlock except the
/// 10-minute default test timeout, which it burned in full — twice.
///
/// Where the workspace document physically lives is `WorkspaceService`'s own
/// contract, covered by `crux_workspace`'s tests and by
/// `test/features/workspace/providers/workspace_restore_and_dedupe_test.dart`.
/// This file's subject is "CLI arguments become workspace tabs", for which
/// disk is incidental. Keeping every future inside the fake zone makes a
/// plain `pumpAndSettle()` exact, so there is no window left to lose.
class _InMemoryWorkspaceService extends WorkspaceService<SimcruxTabPayload> {
  _InMemoryWorkspaceService() : super(codec: const SimcruxWorkspaceCodec());

  Workspace<SimcruxTabPayload> _auto = Workspace<SimcruxTabPayload>.empty();
  final Map<String, Workspace<SimcruxTabPayload>> _named =
      <String, Workspace<SimcruxTabPayload>>{};

  @override
  Future<Workspace<SimcruxTabPayload>> load() async => _auto;

  @override
  Future<void> save(Workspace<SimcruxTabPayload> workspace) async =>
      _auto = workspace;

  @override
  Future<void> saveToPath(
    String path,
    Workspace<SimcruxTabPayload> workspace,
  ) async => _named[path] = workspace;

  /// Mirrors the real service: a named document that cannot be read throws
  /// rather than yielding an empty workspace, so a caller keeps its live
  /// session and reports the failure instead of saving over it.
  @override
  Future<Workspace<SimcruxTabPayload>> loadFromPath(String path) async {
    final doc = _named[path];
    if (doc == null) {
      throw WorkspaceLoadException(path: path, reason: 'no such document');
    }
    return doc;
  }

  @override
  Future<void> clear() async => _auto = Workspace<SimcruxTabPayload>.empty();

  @override
  Future<String?> sidecarPathFor(
    String tabId, {
    String extension = '.json',
  }) async => null;

  @override
  Future<void> deleteSidecar(
    String tabId, {
    String extension = '.json',
  }) async {}
}

/// Plays macOS delivering files, with the native side's semantics: a file
/// delivered while nothing listens is buffered, and the next listener gets
/// the buffer first. Never touches the real channels, so no test here
/// depends on whether the host running it is a Mac.
class _FakeIncomingFiles extends IncomingFileService {
  _FakeIncomingFiles() : super(supported: false);

  final List<String> _pending = <String>[];
  final StreamController<String> _later = StreamController<String>.broadcast();

  /// Finder "opens" [path].
  void deliver(String path) {
    if (_later.hasListener) {
      _later.add(path);
    } else {
      _pending.add(path);
    }
  }

  /// Whether a bootstrapper is currently subscribed.
  bool get hasListener => _later.hasListener;

  @override
  Stream<String> openedFiles() async* {
    final queued = List<String>.of(_pending);
    _pending.clear();
    for (final path in queued) {
      yield path;
    }
    yield* _later.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _InMemoryWorkspaceService service;
  late SharedPreferences prefs;

  setUp(() async {
    service = _InMemoryWorkspaceService();
    // The workspace notifier's launch gate reads the settings *service*
    // before it reads the document. Left unstubbed, that resolves through the
    // real `shared_preferences` platform channel, whose reply is delivered by
    // the real event loop — the same fake-zone/real-zone split the workspace
    // service had, and enough on its own to leave the workspace unresolved
    // for the whole of `pumpAndSettle`. `prefsOverride` keeps the gate
    // microtask-bound. This `setUp` runs outside the fake zone, so awaiting
    // `getInstance()` here is safe.
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    CliArgs args = const CliArgs(),
    Locale locale = const Locale('en'),
    _FakeIncomingFiles? incoming,
  }) async {
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        cliArgsProvider.overrideWithValue(args),
        incomingFileServiceProvider.overrideWithValue(
          incoming ?? _FakeIncomingFiles(),
        ),
        settingsServiceProvider.overrideWithValue(
          SettingsService<AppSettings>(
            const SimcruxSettingsCodec(),
            prefsOverride: prefs,
          ),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: const CliRegressionBootstrapper(
            child: Scaffold(body: SizedBox(key: _kChildKey)),
          ),
        ),
      ),
    );
    // Everything the bootstrapper awaits is microtask-bound, so settling
    // frames drains all of it. No fixed delay, no real event loop, no race.
    await tester.pumpAndSettle();
    return container;
  }

  /// Boots the bootstrapper **underneath a live [CruxEulaGate]**, the way a
  /// first run does.
  ///
  /// The gate renders `child` unchanged until its acceptance store loads, and
  /// then — when acceptance is required — returns a `Stack` with `child`
  /// inside it. That reparents the subtree, so the element holding
  /// `_CliRegressionBootstrapperState` is destroyed and rebuilt, and the
  /// post-frame callback the old state armed fires against a disposed
  /// `ConsumerState`. The real gate is used rather than a stand-in with the
  /// same shape, because a stand-in would only prove my model of the gate.
  Future<ProviderContainer> pumpBehindEulaGate(
    WidgetTester tester, {
    CliArgs args = const CliArgs(),
    _FakeIncomingFiles? incoming,
  }) async {
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        cliArgsProvider.overrideWithValue(args),
        incomingFileServiceProvider.overrideWithValue(
          incoming ?? _FakeIncomingFiles(),
        ),
        settingsServiceProvider.overrideWithValue(
          SettingsService<AppSettings>(
            const SimcruxSettingsCodec(),
            prefsOverride: prefs,
          ),
        ),
        simcruxWorkspaceServiceProvider.overrideWithValue(service),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: CruxEulaGate(
            child: CliRegressionBootstrapper(
              child: Scaffold(body: SizedBox(key: _kChildKey)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  /// The workspace as the bootstrapper left it.
  ///
  /// Reading it synchronously is itself the guard: if [pump] ever returned
  /// while the workspace was still loading, this fails immediately with
  /// "workspace never resolved" rather than hanging on a future that the
  /// fake-async zone will never complete.
  Workspace<SimcruxTabPayload> resolvedWorkspace(ProviderContainer container) {
    final snapshot = container.read(workspaceProvider);
    expect(
      snapshot.hasValue,
      isTrue,
      reason: 'workspace never resolved: $snapshot',
    );
    return snapshot.requireValue;
  }

  /// Flushes the workspace notifier's debounced auto-save so the test body
  /// ends with no pending timer.
  Future<void> flush(ProviderContainer container) =>
      container.read(workspaceProvider.notifier).flushPendingSave();

  group('CliRegressionBootstrapper', () {
    testWidgets('renders its child and opens no tabs without CLI args', (
      tester,
    ) async {
      final container = await pump(tester);
      expect(find.byKey(_kChildKey), findsOneWidget);

      expect(resolvedWorkspace(container).tabs, isEmpty);
      await flush(container);
    });

    testWidgets('opens one workspace tab per positional config path', (
      tester,
    ) async {
      final container = await pump(
        tester,
        args: const CliArgs(
          projectPaths: ['/p/cpu/simcrux.yaml', '/p/mem/simcrux.yaml'],
        ),
      );

      final ws = resolvedWorkspace(container);
      expect(ws.tabs, hasLength(2));
      expect(ws.tabs[0].displayName, 'simcrux.yaml');
      expect(ws.tabs[0].payload.configPath, '/p/cpu/simcrux.yaml');
      expect(ws.tabs[1].payload.configPath, '/p/mem/simcrux.yaml');
      await flush(container);
    });

    testWidgets('the same config named twice opens one tab, not two', (
      tester,
    ) async {
      // The defect this pins: the bootstrapper opened a tab per positional argument
      // with no notion of "already open", so a config the workspace already
      // held got a second tab — and one more on every relaunch. Naming it
      // twice on one command line is the same defect with the clock removed.
      // The path spellings differ deliberately: identity is canonical, not
      // textual.
      final container = await pump(
        tester,
        args: const CliArgs(
          projectPaths: [
            '/p/cpu/simcrux.yaml',
            '/p/cpu/../cpu/simcrux.yaml',
          ],
        ),
      );

      expect(resolvedWorkspace(container).tabs, hasLength(1));
      await flush(container);
    });

    testWidgets('--session opens an additional tab for the session config', (
      tester,
    ) async {
      final container = await pump(
        tester,
        args: const CliArgs(
          projectPaths: ['/p/cpu/simcrux.yaml'],
          sessionPath: '/s/debug.simcrux-session',
        ),
      );

      final ws = resolvedWorkspace(container);
      expect(ws.tabs, hasLength(2));
      expect(ws.tabs[0].payload.configPath, '/p/cpu/simcrux.yaml');
      expect(ws.tabs[1].displayName, 'debug.simcrux-session');
      expect(ws.tabs[1].payload.configPath, '/s/debug.simcrux-session');
      await flush(container);
    });

    testWidgets(
      'a broken --workspace path is best-effort: positional tabs still open',
      (tester) async {
        final container = await pump(
          tester,
          args: const CliArgs(
            workspacePath: '/does/not/exist.simcrux-workspace',
            projectPaths: ['/p/cpu/simcrux.yaml'],
          ),
        );
        expect(tester.takeException(), isNull);

        final ws = resolvedWorkspace(container);
        expect(ws.tabs, hasLength(1));
        expect(ws.tabs.single.payload.configPath, '/p/cpu/simcrux.yaml');
        await flush(container);
      },
    );

    group('design manifests on the command line', () {
      const uartYaml =
          'version: 1\nname: uart\nartifacts:\n  simulation: sim/simcrux.yaml\n';

      /// A design directory with its regression config, and a manifest named
      /// [fileName] beside it. Synchronous I/O only, so it is safe inside the
      /// fake-async zone the widget test body runs in.
      String writeDesign({String fileName = 'uart.crux-project'}) {
        final root = Directory.systemTemp.createTempSync('sc_cli_manifest');
        addTearDown(() => root.deleteSync(recursive: true));
        final dir = Directory(p.join(root.path, 'uart'))..createSync();
        File(p.join(dir.path, 'sim', 'simcrux.yaml'))
          ..parent.createSync()
          ..writeAsStringSync('');
        File(p.join(dir.path, fileName)).writeAsStringSync(uartYaml);
        return dir.path;
      }

      /// Lets a snack bar's display timer run out so no timer outlives the
      /// test.
      Future<void> dismissSnack(WidgetTester tester) async {
        await tester.pump(const Duration(seconds: 10));
        await tester.pumpAndSettle();
      }

      testWidgets('a named manifest opens the config it names', (
        tester,
      ) async {
        final dir = writeDesign();
        final container = await pump(
          tester,
          args: CliArgs(projectPaths: [p.join(dir, 'uart.crux-project')]),
        );

        final ws = resolvedWorkspace(container);
        expect(ws.tabs, hasLength(1));
        expect(
          ws.tabs.single.payload.configPath,
          endsWith(p.join('sim', 'simcrux.yaml')),
        );
        expect(ws.tabs.single.displayName, 'simcrux.yaml');
        // A clean open says nothing.
        expect(find.byType(SnackBar), findsNothing);
        await flush(container);
      });

      testWidgets('a design directory opens through its one manifest', (
        tester,
      ) async {
        final dir = writeDesign();
        final container = await pump(
          tester,
          args: CliArgs(projectPaths: [dir]),
        );

        final ws = resolvedWorkspace(container);
        expect(ws.tabs, hasLength(1));
        expect(
          ws.tabs.single.payload.configPath,
          endsWith(p.join('sim', 'simcrux.yaml')),
        );
        await flush(container);
      });

      testWidgets(
        'a legacy bare .crux-project opens and says what to rename it to',
        (tester) async {
          final dir = writeDesign(fileName: '.crux-project');
          final container = await pump(
            tester,
            args: CliArgs(projectPaths: [p.join(dir, '.crux-project')]),
          );

          expect(resolvedWorkspace(container).tabs, hasLength(1));
          final l10n = await L10N.delegate.load(const Locale('en'));
          expect(
            find.text(l10n.cruxProjectLegacyFileName('uart.crux-project')),
            findsOneWidget,
          );
          await dismissSnack(tester);
          await flush(container);
        },
      );

      testWidgets('a directory holding two manifests opens nothing', (
        tester,
      ) async {
        final dir = writeDesign();
        File(p.join(dir, 'uart_old.crux-project')).writeAsStringSync(uartYaml);
        final container = await pump(
          tester,
          args: CliArgs(projectPaths: [dir]),
        );

        expect(resolvedWorkspace(container).tabs, isEmpty);
        final l10n = await L10N.delegate.load(const Locale('en'));
        expect(
          find.text(
            l10n.cruxProjectAmbiguous(
              dir,
              'uart.crux-project, uart_old.crux-project',
            ),
          ),
          findsOneWidget,
        );
        await dismissSnack(tester);
        await flush(container);
      });
    });

    // The first-run crash, found 2026-09-19 while capturing README
    // screenshots — the first time anyone launched the open-core release
    // build with a positional argument. This is the exact flow the READMEs
    // teach: "Try it" tells a new reader to pass a file, and a new reader is
    // by definition someone who has not accepted the EULA yet.
    //
    // ⚠️ **THESE DO NOT REPRODUCE THE CRASH, AND PASSED BEFORE THE FIX.**
    // Stated plainly because a green test that cannot fail for the right
    // reason is worse than no test: someone will otherwise read this group as
    // covering the defect.
    //
    // The vacuity pin below is real — the gate IS up and the subtree IS
    // reparented. What a widget test cannot stage is the *ordering*. The real
    // callback is armed during Flutter's warm-up frame and delivered by a
    // timer afterwards, so the acceptance store resolves and the gate swaps
    // BEFORE it runs. `testWidgets` invokes post-frame callbacks inline at
    // the end of the same frame, so the bootstrapper always finishes its work
    // before the reparenting and wins a race it loses in production.
    //
    // So these stand as invariant guards — behind the gate, the project opens
    // and nothing throws — and the actual regression check is the manual
    // first run recorded in the launch ledger: clear `eula.acceptedVersion`
    // from the open-core prefs domain, launch the release build with a
    // positional config, and expect zero `Null check operator` lines.
    group('a first run, with the EULA gate still up', () {
      testWidgets('the named project still opens', (tester) async {
        final container = await pumpBehindEulaGate(
          tester,
          args: const CliArgs(projectPaths: ['/p/cpu/simcrux.yaml']),
        );

        // THE VACUITY PIN. Without it these three tests pass whether or not
        // the defect exists: if the acceptance store never resolves, the gate
        // returns `child` unchanged, nothing is ever reparented, and the
        // harness quietly measures the ordinary second-run path under a
        // first-run name.
        expect(
          find.byType(CruxEulaAcceptanceDialog),
          findsOneWidget,
          reason: 'the gate is not up, so this is not a first run',
        );

        // The assertion that matters. `if (!mounted) return;` would silence
        // the throw below and still fail this line, which is why the one-line
        // fix was the wrong one.
        final ws = resolvedWorkspace(container);
        expect(
          ws.tabs.map((t) => t.payload.configPath),
          <String>['/p/cpu/simcrux.yaml'],
          reason: 'the project named on the command line never opened',
        );
        await flush(container);
      });

      testWidgets('and nothing is thrown while it does', (tester) async {
        final container = await pumpBehindEulaGate(
          tester,
          args: const CliArgs(projectPaths: ['/p/cpu/simcrux.yaml']),
        );

        // `Null check operator used on a null value`, from `ConsumerState.ref`
        // on a state the gate's reparenting had already disposed.
        expect(tester.takeException(), isNull);
        await flush(container);
      });

      testWidgets('a second run, gate already accepted, is unaffected', (
        tester,
      ) async {
        // The control. The crash never reproduced on a second launch, which
        // is precisely why it survived to the day of the public flip — so a
        // fix has to leave this path exactly as it was.
        final container = await pump(
          tester,
          args: const CliArgs(projectPaths: ['/p/cpu/simcrux.yaml']),
        );
        expect(resolvedWorkspace(container).tabs, hasLength(1));
        expect(tester.takeException(), isNull);
        await flush(container);
      });
    });

    // A Finder double-click, `open -a` or a drop on the Dock icon. macOS
    // hands over a bare path with no flag, so the bootstrapper routes it by
    // extension to the argument that would have opened it, through the same
    // code. The native half is `macos/Runner/AppDelegate.swift`; the channel
    // contract is pinned in `test/core/platform/incoming_file_service_test.dart`.
    group('files macOS opens', () {
      testWidgets('a double-clicked config opens the tab its command-line '
          'spelling does', (tester) async {
        final incoming = _FakeIncomingFiles()..deliver('/p/cpu/simcrux.yaml');
        final container = await pump(tester, incoming: incoming);

        final ws = resolvedWorkspace(container);
        expect(ws.tabs, hasLength(1));
        expect(ws.tabs.single.displayName, 'simcrux.yaml');
        expect(ws.tabs.single.payload.configPath, '/p/cpu/simcrux.yaml');
        await flush(container);
      });

      testWidgets('a .yml and a .simcrux-session open as positional paths', (
        tester,
      ) async {
        final incoming = _FakeIncomingFiles()
          ..deliver('/p/mem/regress.yml')
          ..deliver('/s/debug.simcrux-session');
        final container = await pump(tester, incoming: incoming);

        expect(
          resolvedWorkspace(container).tabs.map((t) => t.payload.configPath),
          <String>['/p/mem/regress.yml', '/s/debug.simcrux-session'],
        );
        await flush(container);
      });

      testWidgets('a double-clicked manifest opens the config it names', (
        tester,
      ) async {
        final root = Directory.systemTemp.createTempSync('sc_finder_manifest');
        addTearDown(() => root.deleteSync(recursive: true));
        final dir = Directory(p.join(root.path, 'uart'))..createSync();
        File(p.join(dir.path, 'sim', 'simcrux.yaml'))
          ..parent.createSync()
          ..writeAsStringSync('');
        final manifest = p.join(dir.path, 'uart.crux-project');
        File(manifest).writeAsStringSync(
          'version: 1\nname: uart\nartifacts:\n  simulation: sim/simcrux.yaml\n',
        );
        final incoming = _FakeIncomingFiles()..deliver(manifest);
        final container = await pump(tester, incoming: incoming);

        expect(
          resolvedWorkspace(container).tabs.single.payload.configPath,
          endsWith(p.join('sim', 'simcrux.yaml')),
        );
        await flush(container);
      });

      testWidgets('a double-clicked workspace loads as --workspace does', (
        tester,
      ) async {
        final pane = crux.WorkspacePane(id: crux.PaneId.generate());
        const named = '/w/team.simcrux-workspace';
        service._named[named] = Workspace<SimcruxTabPayload>(
          tabs: [
            crux.WorkspaceTab<SimcruxTabPayload>(
              id: crux.TabId.generate(),
              displayName: 'simcrux.yaml',
              paneId: pane.id,
              payload: SimcruxTabPayload(configPath: '/team/simcrux.yaml'),
            ),
          ],
          panes: [pane],
          activePaneId: pane.id,
        );
        final incoming = _FakeIncomingFiles()..deliver(named);
        final container = await pump(tester, incoming: incoming);

        expect(
          resolvedWorkspace(container).tabs.map((t) => t.payload.configPath),
          <String>['/team/simcrux.yaml'],
          reason: 'the workspace was opened as a project, not loaded',
        );
        await flush(container);
      });

      testWidgets('a broken workspace is best-effort, as --workspace is', (
        tester,
      ) async {
        final incoming = _FakeIncomingFiles()
          ..deliver('/does/not/exist.simcrux-workspace')
          ..deliver('/p/cpu/simcrux.yaml');
        final container = await pump(tester, incoming: incoming);

        expect(tester.takeException(), isNull);
        expect(
          resolvedWorkspace(container).tabs.map((t) => t.payload.configPath),
          <String>['/p/cpu/simcrux.yaml'],
        );
        await flush(container);
      });

      testWidgets('the command line opens first, then what Finder sent', (
        tester,
      ) async {
        final incoming = _FakeIncomingFiles()..deliver('/p/mem/simcrux.yaml');
        final container = await pump(
          tester,
          args: const CliArgs(projectPaths: ['/p/cpu/simcrux.yaml']),
          incoming: incoming,
        );

        expect(
          resolvedWorkspace(container).tabs.map((t) => t.payload.configPath),
          <String>['/p/cpu/simcrux.yaml', '/p/mem/simcrux.yaml'],
        );
        await flush(container);
      });

      testWidgets('a file opened while the app runs opens too', (
        tester,
      ) async {
        final incoming = _FakeIncomingFiles();
        final container = await pump(tester, incoming: incoming);
        expect(resolvedWorkspace(container).tabs, isEmpty);

        incoming.deliver('/p/cpu/simcrux.yaml');
        await tester.pumpAndSettle();

        expect(
          resolvedWorkspace(container).tabs.single.payload.configPath,
          '/p/cpu/simcrux.yaml',
        );
        await flush(container);
      });

      testWidgets('behind the first-run EULA gate the file still opens', (
        tester,
      ) async {
        final incoming = _FakeIncomingFiles()..deliver('/p/cpu/simcrux.yaml');
        final container = await pumpBehindEulaGate(tester, incoming: incoming);

        expect(find.byType(CruxEulaAcceptanceDialog), findsOneWidget);
        expect(
          resolvedWorkspace(container).tabs.map((t) => t.payload.configPath),
          <String>['/p/cpu/simcrux.yaml'],
        );
        expect(tester.takeException(), isNull);
        await flush(container);
      });

      testWidgets('the subscription ends with the widget', (tester) async {
        final incoming = _FakeIncomingFiles();
        final container = await pump(tester, incoming: incoming);
        expect(incoming.hasListener, isTrue);

        await tester.pumpWidget(const SizedBox());
        expect(incoming.hasListener, isFalse);
        await flush(container);
      });
    });

    // The other half of "a double-click routes like the command line": a
    // Finder-opened file only ever becomes a tab (above), and a tab loads
    // its project the one way every tab does, `startFromConfigPath` through
    // `configLoaderProvider`. That path is pinned here with the real
    // provider and default settings, because a double-click is a zero-click
    // open of whatever was clicked, including a project file someone else
    // wrote.
    group('a double-clicked project loads with the tooling gate closed', () {
      test('its simulator binary is dropped with the advisory, and nothing '
          'runs', () async {
        final dir = Directory.systemTemp.createTempSync('sc_finder_gate');
        addTearDown(() => dir.deleteSync(recursive: true));
        final project = p.join(dir.path, 'simcrux.yaml');
        File(project).writeAsStringSync(
          'version: "1"\n'
          'defaults:\n'
          '  simulator: icarus\n'
          'simulators:\n'
          '  icarus:\n'
          '    source: custom\n'
          '    path: /tmp/not-a-simulator\n'
          'suites:\n'
          '  s:\n'
          '    tests:\n'
          '      - name: t\n'
          '        top: tb\n',
        );
        final container = ProviderContainer(
          overrides: [
            ...answeredTelemetryOverrides(),
            settingsServiceProvider.overrideWithValue(
              SettingsService<AppSettings>(
                const SimcruxSettingsCodec(),
                prefsOverride: prefs,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        // What `RegressionTabContent` does for a new tab: the user's
        // run-on-open preference, which defaults to off.
        final settings = await container.read(settingsServiceProvider).load();
        await container
            .read(regressionRunnerProvider.notifier)
            .startFromConfigPath(project, autoStart: settings.autoRunOnOpen);

        final config = container.read(activeConfigProvider);
        expect(config, isNotNull, reason: 'the project did not load');
        final icarus = config!.simulatorBinaries['icarus']!;
        expect(icarus.customPath, isNull);
        expect(icarus.source, SimulatorBinarySource.system);
        expect(
          config.loadWarnings.map((w) => w.message),
          anyElement(contains('--allow-project-tooling')),
        );
        expect(
          container.read(regressionRunnerProvider).value,
          isNull,
          reason: 'opening a project must not run it',
        );
      });
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        final container = await pump(tester, locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
        await flush(container);
      }
    });
  });
}
