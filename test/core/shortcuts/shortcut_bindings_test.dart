// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/shortcut_bindings.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';

void main() {
  // Actions that intentionally have no default keyboard binding —
  // command-palette-only or menu-only. Each entry documents why.
  const noDefaultBindings = <SimcruxAction>{
    // Split-pane: discoverability via command palette + menu;
    // single-key shortcuts reserved for the higher-traffic
    // splitPaneRight action plus per-product chord work later.
    SimcruxAction.closePane,
    SimcruxAction.focusOtherPane,
    SimcruxAction.moveTabToOtherPane,
    // Pro seed-failure heatmap is opened from the
    // dashboard toolbar / command palette / menu; no dedicated
    // chord — the screen is a low-frequency drill-down.
    SimcruxAction.openSeedFailureHeatmap,
    // Pro trend-tracking screens (per-test chart,
    // per-suite chart, calendar heatmap, retention config). Opened
    // through the command palette / menu / dashboard context menu;
    // no headline chord — these are drill-down workflows triggered
    // from another surface (a selected test, a dashboard row).
    SimcruxAction.showTrendChart,
    SimcruxAction.showSuiteTrendChart,
    SimcruxAction.showCalendarHeatmap,
    SimcruxAction.configureRetentionPolicy,
    // The Pro Flaky Tests panel opener. Same
    // drill-down rationale as the trend screens above — command
    // palette / menu only, no headline chord.
    SimcruxAction.showFlakyTests,
    // Pro PR Annotation dispatch + settings dialog.
    // Both are command-palette / menu workflows triggered manually
    // from outside the editor's hot path; no headline chord
    // justification.
    SimcruxAction.dispatchPrAnnotations,
    SimcruxAction.configurePrAnnotationTarget,
    // Multi-project workspace.
    // `switchProject` and `searchAcrossProjects` earn dedicated chords
    // (Cmd/Ctrl+P and Cmd/Ctrl+Shift+F respectively). The remaining
    // three actions are tab-strip / context-menu / command-palette
    // flows — no headline chord.
    SimcruxAction.reopenRecentProject,
    SimcruxAction.pinActiveProject,
    SimcruxAction.closeAllProjects,
    // The open-core close-every-tab capability. Destructive and
    // confirmation-guarded; menu + command palette only, no chord.
    SimcruxAction.closeAllTabs,
    // Custom simulator-driver plugin SDK actions.
    // Both are Settings-panel + command-palette workflows triggered
    // manually outside the editor's hot path; no headline chord
    // justification.
    SimcruxAction.openPluginManager,
    SimcruxAction.reloadPlugins,
    // openAppDiagnostics left this set in the suite UI-consistency pass:
    // it now carries WaveCrux's Cmd/Ctrl+Shift+M default, and
    // openTabDiagnostics carries Cmd/Ctrl+Shift+I.
    // Beta-release infrastructure. Both are
    // Help-menu / command-palette / About-box workflows a user reaches
    // deliberately once in a while; no headline chord justification, and
    // F1 is already taken by About.
    SimcruxAction.checkForUpdates,
    // Documentation opens a URL in the browser — Help menu /
    // palette only. F1 is About's binding across the suite.
    SimcruxAction.openDocumentation,
    SimcruxAction.submitIssue,
    // The two RISC-V importers. `importFusesoc` holds Cmd/Ctrl+I as the
    // one headline import chord; these two are once-per-checkout setup
    // flows reached from the File menu or the palette, and the scripted
    // path is `simcrux import-riscv-arch-test` /
    // `simcrux import-riscv-formal` rather than a keystroke.
    SimcruxAction.importRiscvArchTest,
    SimcruxAction.importRiscvFormal,
    // Export Results. A Tools-menu / palette workflow reached
    // once at the end of a run, and it opens two modals before it does
    // anything — a headline chord would buy nothing. Cmd/Ctrl+E stays free.
    SimcruxAction.exportResults,
  };

  group('defaultBindings()', () {
    test('every SimcruxAction either has a default binding or is on '
        'the documented no-default list', () {
      final bindings = defaultBindings();
      for (final action in SimcruxAction.values) {
        if (noDefaultBindings.contains(action)) {
          expect(
            bindings[action],
            isNull,
            reason:
                'Expected no default binding for ${action.id} '
                '(documented as command-palette / menu-only).',
          );
          continue;
        }
        expect(
          bindings[action],
          isNotNull,
          reason: 'No default binding for ${action.id}',
        );
      }
    });

    test(r'splitPaneRight binds to Cmd/Ctrl+\', () {
      final bindings = defaultBindings();
      final split = bindings[SimcruxAction.splitPaneRight];
      expect(split, isA<SingleActivator>());
      final sa = split! as SingleActivator;
      expect(sa.trigger, equals(LogicalKeyboardKey.backslash));
    });

    test('macOS bindings use meta (Cmd)', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final bindings = defaultBindings();
      final open = bindings[SimcruxAction.openProject];
      expect(open, isA<SingleActivator>());
      final sa = open! as SingleActivator;
      expect(sa.meta, isTrue);
      expect(sa.control, isFalse);
      expect(sa.trigger, equals(LogicalKeyboardKey.keyO));
    });

    test('non-macOS bindings use control', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final bindings = defaultBindings();
      final sa = bindings[SimcruxAction.openProject]! as SingleActivator;
      expect(sa.control, isTrue);
      expect(sa.meta, isFalse);
    });

    test('Escape clears regression with no modifier', () {
      final bindings = defaultBindings();
      final cancel = bindings[SimcruxAction.cancelRegression];
      expect(cancel, isA<SingleActivator>());
      final sa = cancel! as SingleActivator;
      expect(sa.trigger, equals(LogicalKeyboardKey.escape));
      expect(sa.control, isFalse);
      expect(sa.meta, isFalse);
    });

    test('F1 opens About on every platform', () {
      final bindings = defaultBindings();
      final about = bindings[SimcruxAction.openAbout]! as SingleActivator;
      expect(about.trigger, equals(LogicalKeyboardKey.f1));
    });

    test('Import FuseSoC is plain Ctrl/Cmd+I (suite import convention)', () {
      // Mirrors WaveCrux's importGtkwSession; Shift+I moved to
      // openTabDiagnostics in the suite UI-consistency pass.
      final sa =
          defaultBindings()[SimcruxAction.importFusesoc]! as SingleActivator;
      expect(sa.trigger, equals(LogicalKeyboardKey.keyI));
      expect(sa.shift, isFalse);
      expect(sa.meta || sa.control, isTrue);
    });

    test('Tab Diagnostics is Ctrl/Cmd+Shift+I (WaveCrux parity)', () {
      final sa =
          defaultBindings()[SimcruxAction.openTabDiagnostics]!
              as SingleActivator;
      expect(sa.trigger, equals(LogicalKeyboardKey.keyI));
      expect(sa.shift, isTrue);
      expect(sa.meta || sa.control, isTrue);
    });

    test('App Diagnostics is Ctrl/Cmd+Shift+M (WaveCrux parity)', () {
      final sa =
          defaultBindings()[SimcruxAction.openAppDiagnostics]!
              as SingleActivator;
      expect(sa.trigger, equals(LogicalKeyboardKey.keyM));
      expect(sa.shift, isTrue);
      expect(sa.meta || sa.control, isTrue);
    });
  });
}
