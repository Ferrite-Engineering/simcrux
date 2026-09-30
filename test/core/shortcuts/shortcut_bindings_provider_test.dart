// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_keybindings/crux_keybindings.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/shortcuts/keymap_presets.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings_provider.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shortcutBindingsProvider', () {
    // Mirrors the documented no-default-bindings set in
    // shortcut_bindings_test.dart — these actions are
    // command-palette / menu-only by design.
    const noDefaultBindings = <SimcruxAction>{
      SimcruxAction.closePane,
      SimcruxAction.focusOtherPane,
      SimcruxAction.moveTabToOtherPane,
      SimcruxAction.openCrossProbePanel,
      SimcruxAction.openSeedFailureHeatmap,
      SimcruxAction.showTrendChart,
      SimcruxAction.showSuiteTrendChart,
      SimcruxAction.showCalendarHeatmap,
      SimcruxAction.showFlakyTests,
      SimcruxAction.configureRetentionPolicy,
      SimcruxAction.dispatchPrAnnotations,
      SimcruxAction.configurePrAnnotationTarget,
      // Tab-strip / context-menu / command-palette only.
      SimcruxAction.reopenRecentProject,
      SimcruxAction.pinActiveProject,
      SimcruxAction.closeAllProjects,
      SimcruxAction.closeAllTabs,
      // Settings-panel / command-palette only.
      SimcruxAction.openPluginManager,
      SimcruxAction.reloadPlugins,
      SimcruxAction.checkForUpdates,
      // Documentation opens a URL in the browser — Help menu /
      // palette only. F1 is About's binding across the suite.
      SimcruxAction.openDocumentation,
      SimcruxAction.submitIssue,
      // App Diagnostics — Tools menu / palette only, no chord.
      SimcruxAction.openAppDiagnostics,
      // The two RISC-V importers — File menu / palette only. Cmd/Ctrl+I is
      // the one headline import chord and belongs to importFusesoc; the
      // scripted path for these two is the `simcrux import-riscv-…`
      // sub-commands.
      SimcruxAction.importRiscvArchTest,
      SimcruxAction.importRiscvFormal,
      // Export Results — Tools menu / palette only, no chord.
      SimcruxAction.exportResults,
    };

    test('seeds from defaultBindings', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final bindings = container.read(shortcutBindingsProvider);
      for (final action in SimcruxAction.values) {
        if (noDefaultBindings.contains(action)) continue;
        expect(
          bindings[action],
          isNotNull,
          reason: 'No seeded binding for ${action.id}',
        );
      }
    });

    test('setBinding overrides the activator for one action', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const newActivator = SingleActivator(LogicalKeyboardKey.f5);
      container
          .read(shortcutBindingsProvider.notifier)
          .setBinding(SimcruxAction.openProject, newActivator);

      final bindings = container.read(shortcutBindingsProvider);
      expect(bindings[SimcruxAction.openProject], same(newActivator));
    });

    test('reset reverts a single binding', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const newActivator = SingleActivator(LogicalKeyboardKey.f5);
      final notifier = container.read(shortcutBindingsProvider.notifier)
        ..setBinding(SimcruxAction.openProject, newActivator);

      expect(
        container.read(shortcutBindingsProvider)[SimcruxAction.openProject],
        same(newActivator),
      );

      notifier.reset(SimcruxAction.openProject);

      final reset = container.read(
        shortcutBindingsProvider,
      )[SimcruxAction.openProject];
      expect(reset, isNot(same(newActivator)));
      expect(reset, isA<ShortcutActivator>());
    });

    test('resetAll wipes every override', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(shortcutBindingsProvider.notifier)
        ..setBinding(
          SimcruxAction.openProject,
          const SingleActivator(LogicalKeyboardKey.f5),
        )
        ..setBinding(
          SimcruxAction.quit,
          const SingleActivator(LogicalKeyboardKey.f6),
        )
        ..resetAll();
      // Reset bindings are == the default platform-aware activators
      // (which are not necessarily F5/F6).
      final bindings = container.read(shortcutBindingsProvider);
      expect(
        bindings[SimcruxAction.openProject],
        isNot(
          isA<SingleActivator>().having(
            (a) => a.trigger,
            'trigger',
            LogicalKeyboardKey.f5,
          ),
        ),
      );
    });
  });

  group('persistence', () {
    const action = SimcruxAction.openProject;

    ProviderContainer persistentContainer(SharedPreferences prefs) =>
        ProviderContainer(
          overrides: [
            shortcutBindingsStoreProvider.overrideWithValue(
              KeyBindingsStore<SimcruxAction>(
                codec: simCruxKeymapCodec,
                prefsOverride: prefs,
              ),
            ),
          ],
        );

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('currentDiffs is empty until something changes', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(shortcutBindingsProvider.notifier).currentDiffs(),
        isEmpty,
      );
    });

    test('a rebind survives into a fresh container (relaunch path)', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = persistentContainer(prefs);
      first
          .read(shortcutBindingsProvider.notifier)
          .setBinding(
            action,
            const SingleActivator(LogicalKeyboardKey.keyJ, control: true),
          );
      await settle();
      first.dispose();

      final second = persistentContainer(prefs);
      addTearDown(second.dispose);
      second.read(shortcutBindingsProvider);
      await settle();

      final restored =
          second.read(shortcutBindingsProvider)[action]! as SingleActivator;
      expect(restored.trigger, LogicalKeyboardKey.keyJ);
      expect(restored.control, isTrue);
    });

    test('unbind then relaunch keeps the action unbound', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = persistentContainer(prefs);
      first.read(shortcutBindingsProvider.notifier).unbind(action);
      await settle();
      first.dispose();

      final second = persistentContainer(prefs);
      addTearDown(second.dispose);
      second.read(shortcutBindingsProvider);
      await settle();
      expect(
        second.read(shortcutBindingsProvider).containsKey(action),
        isFalse,
      );
    });

    test('resetAll clears persisted overrides', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = persistentContainer(prefs);
      first.read(shortcutBindingsProvider.notifier)
        ..setBinding(
          action,
          const SingleActivator(LogicalKeyboardKey.keyJ, control: true),
        )
        ..resetAll();
      await settle();
      first.dispose();

      final second = persistentContainer(prefs);
      addTearDown(second.dispose);
      second.read(shortcutBindingsProvider);
      await settle();
      expect(
        second.read(shortcutBindingsProvider.notifier).currentDiffs(),
        isEmpty,
      );
    });

    test('importDiffs applies + persists a keymap', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final first = persistentContainer(prefs);
      first.read(shortcutBindingsProvider.notifier).importDiffs({
        action: const KeyBinding(
          key: LogicalKeyboardKey.keyP,
          modifiers: {KeyModifier.mod, KeyModifier.shift},
        ),
      });
      await settle();
      first.dispose();

      final second = persistentContainer(prefs);
      addTearDown(second.dispose);
      second.read(shortcutBindingsProvider);
      await settle();
      final restored =
          second.read(shortcutBindingsProvider)[action]! as SingleActivator;
      expect(restored.trigger, LogicalKeyboardKey.keyP);
      expect(restored.shift, isTrue);
    });

    // After a downgrade the stored keymap is one this build cannot read. The
    // store refuses it by throwing rather than answering "no customizations",
    // precisely so the caller can decline to save over it. The launch restore
    // used to let that refusal escape as an uncaught error and then, on the
    // first rebind, save this build's diffs over the newer keymap.
    test('a keymap written by a newer build is refused and never '
        'overwritten', () async {
      const key = 'settings.shortcutBindings';
      const newer = '{"version": ${kKeymapVersion + 1}, "bindings": {}}';
      SharedPreferences.setMockInitialValues({key: newer});
      final prefs = await SharedPreferences.getInstance();
      final records = <LogRecord>[];
      final originalLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = originalLevel);
      final sub = Logger.root.onRecord
          .where((r) => r.loggerName == 'simcrux.shortcuts')
          .listen(records.add);
      addTearDown(sub.cancel);

      final container = persistentContainer(prefs);
      addTearDown(container.dispose);
      container.read(shortcutBindingsProvider);
      await settle();

      container
          .read(shortcutBindingsProvider.notifier)
          .setBinding(
            action,
            const SingleActivator(LogicalKeyboardKey.keyJ, control: true),
          );
      await settle();

      expect(prefs.getString(key), newer);
      // The session still works, on this build's defaults plus the change.
      final current =
          container.read(shortcutBindingsProvider)[action]! as SingleActivator;
      expect(current.trigger, LogicalKeyboardKey.keyJ);
      expect(records, isNotEmpty);
      expect(records.first.level, Level.WARNING);
    });

    group('applyPreset', () {
      test('replaces the whole map with the supplied preset', () {
        final container = ProviderContainer();
        addTearDown(container.dispose);

        final notifier = container.read(shortcutBindingsProvider.notifier)
          // Diverge first so the preset visibly replaces a custom binding.
          ..setBinding(
            action,
            const SingleActivator(LogicalKeyboardKey.keyJ, control: true),
          );
        expect(
          presetForBindings(container.read(shortcutBindingsProvider)),
          isNull,
        );

        notifier.applyPreset(bindingsForPreset(KeymapPreset.simCrux));

        expect(
          presetForBindings(container.read(shortcutBindingsProvider)),
          KeymapPreset.simCrux,
        );
        // A preset equal to the defaults persists as an empty diff.
        expect(notifier.currentDiffs(), isEmpty);
      });

      test('persists as diff-from-default across a relaunch', () async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();

        final first = persistentContainer(prefs);
        first.read(shortcutBindingsProvider.notifier)
          ..setBinding(
            action,
            const SingleActivator(LogicalKeyboardKey.keyJ, control: true),
          )
          ..applyPreset(bindingsForPreset(KeymapPreset.simCrux));
        await settle();
        first.dispose();

        final second = persistentContainer(prefs);
        addTearDown(second.dispose);
        second.read(shortcutBindingsProvider);
        await settle();
        expect(
          presetForBindings(second.read(shortcutBindingsProvider)),
          KeymapPreset.simCrux,
        );
        expect(
          second.read(shortcutBindingsProvider.notifier).currentDiffs(),
          isEmpty,
        );
      });
    });
  });
}
