// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_file_watcher/crux_file_watcher.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/services/watcher/suite_source_watcher.dart';

CoreSettings _autoMode() =>
    const CoreSettings.defaults().copyWith(autoReloadMode: AutoReloadMode.auto);

class _RecordingAutoReloadNotifier extends AutoReloadNotifier {
  int rerunCount = 0;
  @override
  Future<void> rerun() async {
    rerunCount += 1;
    // Don't actually invoke the regression runner — the unit test
    // exercises the watcher → notifier dispatch path, not the
    // scheduler.
  }
}

/// Stub SuiteSourceWatcher that lets the test push synthetic file
/// change events into the notifier without touching the file system.
class _ScriptedWatcher implements SuiteSourceWatcher {
  final StreamController<SuiteSourceChange> _controller =
      StreamController<SuiteSourceChange>.broadcast();
  bool _disposed = false;

  /// True once [watch] has been called — i.e. this watcher's tab was the
  /// elected armer for its project.
  bool watched = false;

  void push(SuiteSourceChange change) {
    if (_disposed) return;
    _controller.add(change);
  }

  @override
  Stream<SuiteSourceChange> get events => _controller.stream;

  @override
  int get watchedPathCount => 1;

  @override
  void watch(RegressionConfig config) {
    watched = true;
  }

  @override
  void stop() {}

  @override
  void dispose() {
    _disposed = true;
    unawaited(_controller.close());
  }
}

class _FakeSettingsNotifier extends AppSettingsNotifier {
  _FakeSettingsNotifier(this._settings);
  final AppSettings _settings;
  static AppSettingsNotifier Function() factory(AppSettings settings) =>
      () => _FakeSettingsNotifier(settings);
  @override
  Future<AppSettings> build() async => _settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('per-tab auto-reload', () {
    test('two tabs each get their own AutoReloadNotifier instance', () {
      final root = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            _FakeSettingsNotifier.factory(
              AppSettings(core: _autoMode()),
            ),
          ),
        ],
      );
      addTearDown(root.dispose);
      final tabA = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: simcruxTabOverrides(crux.TabId.generate()),
      );
      addTearDown(tabB.dispose);

      final a = tabA.read(autoReloadNotifierProvider.notifier);
      final b = tabB.read(autoReloadNotifierProvider.notifier);
      expect(
        identical(a, b),
        isFalse,
        reason:
            'per-tab override must produce distinct notifier '
            'instances',
      );
    });

    test('a file-change event in tab A re-runs tab A only', () async {
      final root = ProviderContainer(
        overrides: [
          appSettingsProvider.overrideWith(
            _FakeSettingsNotifier.factory(
              AppSettings(core: _autoMode()),
            ),
          ),
        ],
      );
      addTearDown(root.dispose);

      final scriptedA = _ScriptedWatcher();
      final scriptedB = _ScriptedWatcher();
      addTearDown(scriptedA.dispose);
      addTearDown(scriptedB.dispose);

      // Make each tab's AutoReloadNotifier use the scripted watcher
      // and a no-op `rerun` so we can verify dispatch without spinning
      // up the regression runner. We filter the
      // autoReloadNotifierProvider override out of the standard
      // per-tab list so we can replace it with the scripted notifier
      // here (Riverpod rejects two overrides for the same provider).
      List<Override> overridesWithScripted(
        crux.TabId id,
        _ScriptedWatcher watcher,
      ) {
        final defaults = simcruxTabOverrides(id);
        final filtered = defaults.where(
          (o) => !identical(o.origin, autoReloadNotifierProvider),
        );
        return [
          ...filtered,
          autoReloadNotifierProvider.overrideWith(
            () =>
                _RecordingAutoReloadNotifier()..watcherFactory = () => watcher,
          ),
        ];
      }

      final tabA = ProviderContainer(
        parent: root,
        overrides: overridesWithScripted(crux.TabId.generate(), scriptedA),
      );
      addTearDown(tabA.dispose);
      final tabB = ProviderContainer(
        parent: root,
        overrides: overridesWithScripted(crux.TabId.generate(), scriptedB),
      );
      addTearDown(tabB.dispose);

      // Await appSettings resolution so the AutoReloadNotifier reads
      // AsyncData(AutoReloadMode.auto) — without this, _onChange's
      // maybeWhen falls back to AutoReloadMode.prompt and the
      // recording rerun() never fires.
      await tabA.read(appSettingsProvider.future);
      await tabB.read(appSettingsProvider.future);

      // Arm both notifiers by reading them (build() runs).
      final notifierA =
          tabA.read(autoReloadNotifierProvider.notifier)
              as _RecordingAutoReloadNotifier;
      final notifierB =
          tabB.read(autoReloadNotifierProvider.notifier)
              as _RecordingAutoReloadNotifier;
      // Each tab's watcher arms when activeConfig becomes non-null.
      final cfg = RegressionConfig(
        projectFilePath: '/p/a.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      );
      tabA.read(activeConfigProvider.notifier).replace(cfg);
      tabB.read(activeConfigProvider.notifier).replace(cfg);

      // Push a change into tab A's watcher only.
      scriptedA.push(
        const SuiteSourceChange(
          path: '/p/cpu.v',
          event: FileWatchEvent.modified,
        ),
      );
      // Let the AutoReloadNotifier's stream listener pick it up.
      await Future<void>.delayed(Duration.zero);

      expect(
        notifierA.rerunCount,
        1,
        reason: 'tab A should auto-rerun on its own file change',
      );
      expect(
        notifierB.rerunCount,
        0,
        reason: "tab B is untouched by tab A's file changes",
      );
    });

    test(
      'two tabs of one project arm a single watcher and re-run once',
      () async {
        // The duplicate-watcher defect: two tabs viewing the SAME project each armed
        // their own watcher, so a single source edit fired both tabs'
        // rerun() → two runs into the shared per-project store slot. The
        // arming coordinator elects one armer per project.
        final root = ProviderContainer(
          overrides: [
            appSettingsProvider.overrideWith(
              _FakeSettingsNotifier.factory(AppSettings(core: _autoMode())),
            ),
          ],
        );
        addTearDown(root.dispose);

        final scriptedA = _ScriptedWatcher();
        final scriptedB = _ScriptedWatcher();
        addTearDown(scriptedA.dispose);
        addTearDown(scriptedB.dispose);

        List<Override> withScripted(crux.TabId id, _ScriptedWatcher w) {
          final filtered = simcruxTabOverrides(id).where(
            (o) => !identical(o.origin, autoReloadNotifierProvider),
          );
          return [
            ...filtered,
            autoReloadNotifierProvider.overrideWith(
              () => _RecordingAutoReloadNotifier()..watcherFactory = () => w,
            ),
          ];
        }

        final tabA = ProviderContainer(
          parent: root,
          overrides: withScripted(crux.TabId.generate(), scriptedA),
        );
        addTearDown(tabA.dispose);
        final tabB = ProviderContainer(
          parent: root,
          overrides: withScripted(crux.TabId.generate(), scriptedB),
        );
        addTearDown(tabB.dispose);

        await tabA.read(appSettingsProvider.future);
        await tabB.read(appSettingsProvider.future);
        final notifierA =
            tabA.read(autoReloadNotifierProvider.notifier)
                as _RecordingAutoReloadNotifier;
        final notifierB =
            tabB.read(autoReloadNotifierProvider.notifier)
                as _RecordingAutoReloadNotifier;

        // SAME project path in both tabs.
        final cfg = RegressionConfig(
          projectFilePath: '/p/shared.yaml',
          schemaVersion: '1',
          suites: const [],
          simulatorBinaries: const {},
        );
        tabA.read(activeConfigProvider.notifier).replace(cfg);
        tabB.read(activeConfigProvider.notifier).replace(cfg);

        // Exactly one tab armed its watcher.
        final armed = [
          scriptedA,
          scriptedB,
        ].where((w) => w.watched).toList();
        expect(
          armed,
          hasLength(1),
          reason: 'only one tab may arm a watcher per project',
        );

        // The single source edit reaches the one armed watcher.
        armed.single.push(
          const SuiteSourceChange(
            path: '/p/cpu.v',
            event: FileWatchEvent.modified,
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
          notifierA.rerunCount + notifierB.rerunCount,
          1,
          reason: 'one project must re-run once regardless of tab count',
        );
      },
    );
  });
}
