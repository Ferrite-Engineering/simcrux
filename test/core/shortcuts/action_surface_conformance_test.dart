// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Cross-surface conformance: every action-discovery surface (toolbar, menu
// bar, command palette) must render exactly the actions — and exactly the
// enabled/disabled state — that the single-source-of-truth selectors in
// `simcrux_action_descriptors.dart` prescribe, across a matrix of contexts.
//
// Each surface reads the shared `simcruxActionContextProvider`, so the
// harness overrides that provider with a precise `SimcruxActionContext` and
// asserts the rendered surface matches `groupedActionsFor` /
// `paletteActionsFor` / `isActionEnabled` for the same context. This keeps
// the assertions tied to the contract, not to any surface's internals.
//
// Modeled on WaveCrux's and NetCrux's own copies of this test (adapted to
// SimCrux's own action/context/descriptor types and surfaces — not copied
// verbatim). WaveCrux and NetCrux both had one; SimCrux did not.

import 'package:crux_command_palette/crux_command_palette.dart';
import 'package:crux_toolbar/crux_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/action_tier_label.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/command_palette/widgets/command_palette_dialog.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_actions_extensions.dart';
import 'package:simcrux/features/dashboard/widgets/simcrux_toolbar.dart';
import 'package:simcrux/features/menu_bar/widgets/desktop_menu_bar.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

void _noop(SimcruxAction _) {}

/// The context matrix every surface is checked against, built from what
/// [SimcruxActionContext] actually models: an empty workspace, an open tab
/// before/after a config loads, a run in flight, a completed run with and
/// without a selected test, a multi-pane workspace, and the diagnostics
/// opt-out (release-build default).
const Map<String, SimcruxActionContext> _contextMatrix = {
  'no tab': SimcruxActionContext(),
  'tab, no config': SimcruxActionContext(hasOpenTab: true),
  'config loaded, idle': SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
  ),
  'run in progress': SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    runInProgress: true,
  ),
  'results, no selection': SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    hasResults: true,
  ),
  'results + selection, multi-pane (fully loaded)': SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    hasResults: true,
    hasSelectedTest: true,
    paneCount: 2,
    tabCountInActivePane: 2,
  ),
  'diagnostics disabled (release-build default)': SimcruxActionContext(
    hasOpenTab: true,
    hasConfig: true,
    hasResults: true,
    hasSelectedTest: true,
    diagnosticsEnabled: false,
  ),
};

Widget _wrap({required Widget home, required SimcruxActionContext ctx}) =>
    ProviderScope(
      overrides: [
        simcruxActionContextProvider.overrideWithValue(ctx),
        extraDashboardActionsProvider.overrideWithValue(const <Widget>[]),
      ],
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        localizationsDelegates: L10N.localizationsDelegates,
        supportedLocales: L10N.supportedLocales,
        home: home,
      ),
    );

List<PlatformMenuItem> _leafItems(PlatformMenuBar bar) {
  final result = <PlatformMenuItem>[];
  void visit(PlatformMenuItem item) {
    if (item is PlatformMenu) {
      item.menus.forEach(visit);
    } else if (item is PlatformMenuItemGroup) {
      item.members.forEach(visit);
    } else {
      result.add(item);
    }
  }

  bar.menus.forEach(visit);
  return result;
}

String _menuLabel(SimcruxAction a, L10N l10n) =>
    a.label(l10n) + tierLabelSuffix(a.requiredTier, l10n);

void main() {
  // ── Menu bar (native, desktop) ─────────────────────────────────────────
  group('DesktopMenuBar conformance', () {
    Future<(PlatformMenuBar, L10N)> pumpMenu(
      WidgetTester tester,
      SimcruxActionContext ctx,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ctx: ctx,
          home: const DesktopMenuBar(
            onAction: _noop,
            child: Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));
      final l10n = L10N.of(tester.element(find.byType(PlatformMenuBar)));
      return (bar, l10n);
    }

    for (final entry in _contextMatrix.entries) {
      testWidgets('presence + enablement match the table (${entry.key})', (
        tester,
      ) async {
        final ctx = entry.value;
        final (bar, l10n) = await pumpMenu(tester, ctx);
        final expected = groupedActionsFor(
          SimcruxActionSurface.menu,
          ctx,
        ).values.expand((x) => x).toList();

        // Presence: the leaf labels are exactly the table's menu actions
        // (with tier suffixes).
        expect(
          _leafItems(bar).map((e) => e.label).toSet(),
          expected.map((a) => _menuLabel(a, l10n)).toSet(),
        );

        // Enablement: a menu item is enabled iff the table says so.
        final leafByLabel = {for (final i in _leafItems(bar)) i.label: i};
        for (final a in expected) {
          final item = leafByLabel[_menuLabel(a, l10n)];
          expect(item, isNotNull, reason: '$a missing from menu');
          expect(
            item!.onSelected != null,
            isActionEnabled(a, ctx),
            reason: '$a enablement mismatch under "${entry.key}"',
          );
        }
      });
    }
  });

  // ── Command palette ──────────────────────────────────────────────────────
  group('CommandPaletteDialog conformance', () {
    for (final entry in _contextMatrix.entries) {
      testWidgets('listed actions match paletteActionsFor (${entry.key})', (
        tester,
      ) async {
        final ctx = entry.value;
        await tester.pumpWidget(
          _wrap(
            ctx: ctx,
            home: const Scaffold(body: CommandPaletteDialog(onAction: _noop)),
          ),
        );
        await tester.pumpAndSettle();
        final palette = tester.widget<CommandPalette<SimcruxAction>>(
          find.byType(CommandPalette<SimcruxAction>),
        );
        expect(
          palette.actions,
          paletteActionsFor(ctx),
          reason:
              'the palette must list exactly the visible+enabled actions '
              'under "${entry.key}"',
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('disabled and hidden actions never surface as rows', (
      tester,
    ) async {
      const ctx = SimcruxActionContext();
      await tester.pumpWidget(
        _wrap(
          ctx: ctx,
          home: const Scaffold(body: CommandPaletteDialog(onAction: _noop)),
        ),
      );
      await tester.pumpAndSettle();
      final l10n = L10N.of(
        tester.element(find.byType(CommandPalette<SimcruxAction>)),
      );
      for (final hidden in [
        SimcruxAction.openSearch, // disabled: no open tab
        SimcruxAction.closeProject, // disabled: no open tab
        SimcruxAction.openCommandPalette, // self-referential, menu-only
      ]) {
        expect(
          find.descendant(
            of: find.byType(CommandPalette<SimcruxAction>),
            matching: find.text(hidden.label(l10n)),
          ),
          findsNothing,
          reason: '$hidden must not render a palette row',
        );
      }
    });
  });

  // ── Toolbar ───────────────────────────────────────────────────────────────
  group('SimcruxToolbar conformance', () {
    Iterable<SimcruxAction> toolbarActions() => SimcruxAction.values.where(
      (a) => descriptorFor(a).surfaces.contains(SimcruxActionSurface.toolbar),
    );

    // runRegression / cancelRegression share ONE morphing run/stop control
    // (CruxRunStopButton, see simcrux_toolbar.dart's `_RunStopButton`) rather
    // than each getting its own keyed CruxToolbarButtonItem — the toolbar's
    // equivalent of NetCrux's split-view trio sharing one grouped slot.
    // Checked separately below via the composite's onRun/onCancel.
    const inRunStopControl = {
      SimcruxAction.runRegression,
      SimcruxAction.cancelRegression,
    };

    for (final entry in _contextMatrix.entries) {
      testWidgets(
        'every visible toolbar action has a button enabled per the table '
        '(${entry.key})',
        (tester) async {
          final ctx = entry.value;
          await tester.pumpWidget(
            _wrap(
              ctx: ctx,
              home: const Scaffold(body: SimcruxToolbar()),
            ),
          );
          // Not pumpAndSettle: the run/stop control's progress ring runs a
          // perpetual AnimationController while runInProgress is true.
          await tester.pump();

          for (final a in toolbarActions()) {
            if (inRunStopControl.contains(a)) continue;
            final keyFinder = find.byKey(ValueKey<SimcruxAction>(a));
            if (!isActionVisibleIn(a, SimcruxActionSurface.toolbar, ctx)) {
              expect(keyFinder, findsNothing, reason: '$a must be hidden');
              continue;
            }
            expect(keyFinder, findsOneWidget, reason: '$a button missing');
            // The shared CruxToolbarButton wraps the IconButton, so reach
            // through rather than casting the keyed widget itself.
            final button = tester.widget<IconButton>(
              find.descendant(of: keyFinder, matching: find.byType(IconButton)),
            );
            expect(
              button.onPressed != null,
              isActionEnabled(a, ctx),
              reason: '$a enablement mismatch under "${entry.key}"',
            );
          }

          // The reverse direction. `SimcruxToolbar` places its buttons by
          // hand, so a button for an action whose descriptor does not claim
          // the toolbar would pass the loop above; the descriptor would then
          // under-report where the action is reachable from.
          final rendered = tester
              .widgetList(
                find.byWidgetPredicate(
                  (w) => w.key is ValueKey<SimcruxAction>,
                ),
              )
              .map((w) => (w.key! as ValueKey<SimcruxAction>).value)
              .toSet();
          expect(
            rendered.difference(toolbarActions().toSet()),
            isEmpty,
            reason:
                'toolbar buttons for actions whose descriptor does not '
                'claim SimcruxActionSurface.toolbar',
          );

          // The run/stop composite: exactly what the descriptor table's
          // mutual-exclusion gates (`_canStartRun` / `_requiresRunInProgress`)
          // say, never both offered at once.
          final runStop = tester.widget<CruxRunStopButton>(
            find.byType(CruxRunStopButton),
          );
          expect(
            runStop.onRun != null,
            isActionEnabled(SimcruxAction.runRegression, ctx),
            reason: 'run enablement mismatch under "${entry.key}"',
          );
          expect(
            runStop.onCancel != null,
            isActionEnabled(SimcruxAction.cancelRegression, ctx),
            reason: 'cancel enablement mismatch under "${entry.key}"',
          );
        },
      );
    }
  });

  // ── Locale sweep ────────────────────────────────────────────────────────
  group('locale sweep', () {
    for (final locale in ['en', 'zh_CN', 'zh', 'ja', 'ko']) {
      testWidgets('palette + toolbar render in $locale without exceptions', (
        tester,
      ) async {
        final ctx =
            _contextMatrix['results + selection, multi-pane (fully loaded)']!;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              simcruxActionContextProvider.overrideWithValue(ctx),
              extraDashboardActionsProvider.overrideWithValue(
                const <Widget>[],
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.macOS),
              locale: Locale(locale.replaceAll('_', '-')),
              localizationsDelegates: L10N.localizationsDelegates,
              supportedLocales: L10N.supportedLocales,
              home: const Scaffold(
                body: Column(
                  children: [
                    SimcruxToolbar(),
                    Expanded(child: CommandPaletteDialog(onAction: _noop)),
                  ],
                ),
              ),
            ),
          ),
        );
        // Not pumpAndSettle: see the toolbar group's note on the run/stop
        // control's perpetual progress-ring animation.
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  // ── The guard is not vacuous ────────────────────────────────────────────
  test('the action table is not empty and both surfaces carry actions', () {
    expect(SimcruxAction.values.length, greaterThan(10));
    expect(
      SimcruxAction.values.where(
        (a) => descriptorFor(a).surfaces.contains(SimcruxActionSurface.menu),
      ),
      isNotEmpty,
      reason:
          'no action is menu-visible — the descriptor table is not '
          'loading',
    );
    expect(
      SimcruxAction.values.where(
        (a) => descriptorFor(a).surfaces.contains(SimcruxActionSurface.toolbar),
      ),
      isNotEmpty,
      reason:
          'no action is toolbar-visible — the descriptor table is not '
          'loading',
    );
  });
}
