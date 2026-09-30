// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Launch-time regressions for tab dedupe and restore — see the notes above
/// `main`.
library;

import 'dart:io';

import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';

import '../../../support/answered_telemetry.dart';

/// Launch-time regressions for the two halves of one launch defect:
///
/// * a command-line open of a config the restored workspace already contains
///   piled up a second tab, one more per relaunch, without bound;
/// * `restoreTabsOnLaunch = false` restored the tabs anyway.
///
/// The mechanism lives in `crux_workspace`; what these pin is that SimCrux
/// actually *wires* it — `SimcruxWorkspaceCodec.identityOf` and
/// `SimcruxWorkspaceNotifier.shouldRestoreOnLaunch`.
///
/// Written as plain `test`s over a `ProviderContainer` rather than as widget
/// tests. A launch is a sequence of real file reads, and the fake-async zone a
/// `testWidgets` body runs in cannot carry a *restore* through to completion
/// — the widget harness settles only when the document is absent, which is
/// precisely the case the bug is not about. `CliRegressionBootstrapper`'s own
/// coverage, including its command-line dedupe, is in
/// `test/features/dashboard/widgets/cli_regression_bootstrapper_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String configPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('simcrux-restore-dedupe-');
    final file = File(p.join(tempDir.path, 'cpu', 'simcrux.yaml'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('tests: []\n');
    configPath = file.path;
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  File documentFile() => File(p.join(tempDir.path, 'workspace.json'));

  WorkspaceService<SimcruxTabPayload> newService() =>
      WorkspaceService<SimcruxTabPayload>(
        codec: const SimcruxWorkspaceCodec(),
        directoryFactory: () async => tempDir,
        logger: (_) {},
      );

  /// Settings service backed by mock preferences, so the restore gate reads a
  /// real value instead of falling through its unreadable-store fallback.
  /// Passing `null` leaves the real (plugin-less, therefore failing) service
  /// in place, which is how the fallback itself gets exercised.
  Future<SettingsService<AppSettings>> settingsWith({
    required bool restoreTabsOnLaunch,
  }) async {
    SharedPreferences.setMockInitialValues({
      'flutter.settings.restoreTabsOnLaunch': restoreTabsOnLaunch,
    });
    final prefs = await SharedPreferences.getInstance();
    return SettingsService<AppSettings>(
      const SimcruxSettingsCodec(),
      prefsOverride: prefs,
    );
  }

  /// One application launch: a fresh container over the same storage
  /// directory, hydrated, with [cliPaths] opened the way
  /// `CliRegressionBootstrapper` opens them.
  ///
  /// Returns the workspace as it stands after the command line has been
  /// processed, and leaves the document flushed so the next call is a
  /// genuine relaunch.
  Future<Workspace<SimcruxTabPayload>> launch({
    List<String> cliPaths = const [],
    SettingsService<AppSettings>? settings,
  }) async {
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simcruxWorkspaceServiceProvider.overrideWithValue(newService()),
        if (settings != null)
          settingsServiceProvider.overrideWithValue(settings),
      ],
    );
    try {
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      for (final path in cliPaths) {
        await notifier.openTab(
          displayName: p.basename(path),
          payload: SimcruxTabPayload(configPath: path),
        );
      }
      await notifier.flushPendingSave();
      return container.read(workspaceProvider).requireValue;
    } finally {
      container.dispose();
    }
  }

  List<String> configPathsOf(Workspace<SimcruxTabPayload> ws) => [
    for (final tab in ws.tabs) tab.payload.configPath,
  ];

  group('CLI open of an already-open config', () {
    test('focuses the restored tab instead of duplicating it', () async {
      final first = await launch(cliPaths: [configPath]);
      final restoredId = first.tabs.single.id;

      final second = await launch(cliPaths: [configPath]);

      expect(
        second.tabs,
        hasLength(1),
        reason:
            'The restored tab and the CLI tab are the same regression suite.',
      );
      expect(second.tabs.single.id, restoredId);
      expect(second.activeTabId, restoredId);
    });

    test('seven relaunches leave one tab, not seven', () async {
      // The shipped symptom, at product level: each launch added one more
      // copy of the same project, without bound.
      for (var launchNo = 1; launchNo <= 7; launchNo++) {
        final ws = await launch(cliPaths: [configPath]);
        expect(ws.tabs, hasLength(1), reason: 'after launch $launchNo');
      }
    });

    test(
      'a relative launch argument matches the restored absolute path',
      () async {
        await launch(cliPaths: [configPath]);

        final previous = Directory.current;
        Directory.current = tempDir;
        addTearDown(() => Directory.current = previous);

        final ws = await launch(cliPaths: [p.join('cpu', 'simcrux.yaml')]);
        expect(ws.tabs, hasLength(1));
      },
    );

    test('a dot-segment launch argument matches the restored path', () async {
      await launch(cliPaths: [configPath]);

      final ws = await launch(
        cliPaths: [
          p.join(tempDir.path, 'cpu', '..', 'cpu', '.', 'simcrux.yaml'),
        ],
      );
      expect(ws.tabs, hasLength(1));
    });

    test(
      'a symlinked launch argument matches the restored real path',
      () async {
        await launch(cliPaths: [configPath]);
        final link = Link(p.join(tempDir.path, 'alias.yaml'))
          ..createSync(configPath);

        final ws = await launch(cliPaths: [link.path]);
        expect(ws.tabs, hasLength(1));
      },
    );

    test('a differently cased launch argument matches on a case-insensitive '
        'filesystem', () async {
      await launch(cliPaths: [configPath]);

      final ws = await launch(cliPaths: [configPath.toUpperCase()]);
      expect(
        ws.tabs,
        hasLength(Platform.isMacOS || Platform.isWindows ? 1 : 2),
      );
    });

    test('distinct configs still open distinct tabs', () async {
      final other = File(p.join(tempDir.path, 'mem', 'simcrux.yaml'));
      other.parent.createSync(recursive: true);
      other.writeAsStringSync('tests: []\n');

      await launch(cliPaths: [configPath]);
      final ws = await launch(cliPaths: [configPath, other.path]);

      expect(ws.tabs, hasLength(2));
      expect(configPathsOf(ws), containsAll([configPath, other.path]));
    });

    test('two blank tabs remain two tabs', () async {
      // A payload with no config has no identity, so the "+" button must
      // still be able to open a second empty tab.
      final container = ProviderContainer(
        overrides: [
          ...answeredTelemetryOverrides(),
          simcruxWorkspaceServiceProvider.overrideWithValue(newService()),
        ],
      );
      addTearDown(container.dispose);
      await container.read(workspaceProvider.future);
      final notifier = container.read(workspaceProvider.notifier);
      await notifier.openTab(
        displayName: '(new tab)',
        payload: SimcruxTabPayload(configPath: ''),
      );
      await notifier.openTab(
        displayName: '(new tab)',
        payload: SimcruxTabPayload(configPath: ''),
      );
      await notifier.flushPendingSave();

      expect(container.read(workspaceProvider).requireValue.tabs, hasLength(2));
    });
  });

  group('restoreTabsOnLaunch', () {
    test('false starts with no tabs', () async {
      await launch(cliPaths: [configPath]);

      final ws = await launch(
        settings: await settingsWith(restoreTabsOnLaunch: false),
      );

      expect(ws.tabs, isEmpty);
    });

    test('false leaves the persisted document intact', () async {
      await launch(cliPaths: [configPath]);
      final before = documentFile().readAsStringSync();

      await launch(settings: await settingsWith(restoreTabsOnLaunch: false));

      expect(
        documentFile().readAsStringSync(),
        before,
        reason:
            'Turning the preference back on has to bring the session back, '
            'so declining to restore must not destroy it.',
      );
    });

    test('false plus a CLI argument yields exactly the CLI tab', () async {
      final stale = p.join(tempDir.path, 'stale', 'simcrux.yaml');
      await launch(cliPaths: [configPath, stale]);

      final ws = await launch(
        cliPaths: [configPath],
        settings: await settingsWith(restoreTabsOnLaunch: false),
      );

      expect(ws.tabs, hasLength(1));
      expect(ws.tabs.single.payload.configPath, configPath);
    });

    test('true plus a CLI argument yields the restored tabs plus exactly one '
        'deduped CLI tab', () async {
      final other = p.join(tempDir.path, 'mem', 'simcrux.yaml');
      await launch(cliPaths: [configPath, other]);

      final ws = await launch(
        cliPaths: [configPath],
        settings: await settingsWith(restoreTabsOnLaunch: true),
      );

      expect(ws.tabs, hasLength(2));
      expect(
        ws.tabs.where((t) => t.payload.configPath == configPath),
        hasLength(1),
      );
      expect(configPathsOf(ws), contains(other));
    });

    test(
      'an unreadable settings store restores rather than discards',
      () async {
        // No settings override, so `SharedPreferences` has no plugin behind it
        // and the gate hits its fallback. Losing a session because a
        // *preference* could not be read is the worse failure of the two.
        await launch(cliPaths: [configPath]);

        final ws = await launch();

        expect(ws.tabs, hasLength(1));
      },
    );
  });
}
