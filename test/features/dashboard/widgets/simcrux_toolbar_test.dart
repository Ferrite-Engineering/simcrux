// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_toolbar/crux_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_context.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptor.dart';
import 'package:simcrux/core/shortcuts/simcrux_action_descriptors.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_actions_extensions.dart';
import 'package:simcrux/features/dashboard/widgets/simcrux_toolbar.dart';
import 'package:simcrux/features/workspace/providers/simcrux_action_context_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// A config loaded with results and a selected test — every descriptor gate
/// the toolbar reads is satisfied, so the buttons are live.
const _loaded = SimcruxActionContext(
  hasOpenTab: true,
  hasConfig: true,
  hasResults: true,
  hasSelectedTest: true,
  paneCount: 2,
  tabCountInActivePane: 2,
);

const _running = SimcruxActionContext(
  hasOpenTab: true,
  hasConfig: true,
  hasResults: true,
  runInProgress: true,
);

Future<List<SimcruxAction>> _pump(
  WidgetTester tester, {
  SimcruxActionContext ctx = _loaded,
  List<Widget> extraActions = const <Widget>[],
  List<Widget> trailing = const <Widget>[],
  Locale? locale,
  double width = 1400,
  // The running state wears an indeterminate progress ring, which animates
  // forever — `pumpAndSettle` would time out waiting for it.
  bool settle = true,
}) async {
  final dispatched = <SimcruxAction>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extraDashboardActionsProvider.overrideWithValue(extraActions),
        simcruxActionContextProvider.overrideWithValue(ctx),
      ],
      child: MaterialApp(
        locale: locale ?? const Locale('en'),
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: Actions(
              actions: <Type, Action<Intent>>{
                SimcruxActionIntent: CallbackAction<SimcruxActionIntent>(
                  onInvoke: (intent) {
                    dispatched.add(intent.action);
                    return null;
                  },
                ),
              },
              child: SimcruxToolbar(trailing: trailing),
            ),
          ),
        ),
      ),
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return dispatched;
}

Set<SimcruxAction> _rendered(WidgetTester tester) => tester
    .widgetList<CruxToolbarButton>(find.byType(CruxToolbarButton))
    .where((b) => b.key is ValueKey<SimcruxAction>)
    .map((b) => (b.key! as ValueKey<SimcruxAction>).value)
    .toSet();

IconButton _buttonFor(WidgetTester tester, SimcruxAction a) =>
    tester.widget<IconButton>(
      find.descendant(
        of: find.byKey(ValueKey<SimcruxAction>(a)),
        matching: find.byType(IconButton),
      ),
    );

void main() {
  group('SimcruxToolbar', () {
    testWidgets('renders through the shared CruxToolbar', (tester) async {
      await _pump(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(CruxToolbar<SimcruxAction>), findsOneWidget);
    });

    testWidgets('leads with the canonical common block, in suite order', (
      tester,
    ) async {
      await _pump(tester);
      // SimCrux has no session concept, so the canonical Save slot is
      // legitimately absent — the one hole in the common block.
      const common = [
        SimcruxAction.openProject,
        SimcruxAction.closeProject,
        SimcruxAction.openSearch,
        SimcruxAction.openCrossProbePanel,
        SimcruxAction.openSettings,
      ];
      final xs = [
        for (final a in common)
          tester.getCenter(find.byKey(ValueKey<SimcruxAction>(a))).dx,
      ];
      expect(xs, orderedEquals(List<double>.from(xs)..sort()));
      expect(
        tester
            .getCenter(
              find.byKey(
                const ValueKey<SimcruxAction>(SimcruxAction.importFusesoc),
              ),
            )
            .dx,
        greaterThan(xs.last),
        reason: 'Import FuseSoC is app-specific and belongs after the divider',
      );
    });

    testWidgets('every rendered button declares the toolbar surface', (
      tester,
    ) async {
      await _pump(tester);
      for (final action in _rendered(tester)) {
        expect(
          descriptorFor(action).surfaces,
          contains(SimcruxActionSurface.toolbar),
          reason:
              '${action.name} has a toolbar button but its descriptor does '
              'not list SimcruxActionSurface.toolbar',
        );
      }
    });

    testWidgets('dispatches the matching action for each button', (
      tester,
    ) async {
      for (final action in [
        SimcruxAction.openProject,
        SimcruxAction.closeProject,
        SimcruxAction.openSearch,
        SimcruxAction.openSettings,
        SimcruxAction.importFusesoc,
        SimcruxAction.reRunSelected,
      ]) {
        final dispatched = await _pump(tester);
        await tester.tap(find.byKey(ValueKey<SimcruxAction>(action)));
        await tester.pump();
        expect(
          dispatched,
          <SimcruxAction>[action],
          reason: 'tapping $action should dispatch it',
        );
      }
    });

    testWidgets('the cross-probe toggle dispatches the action rather than '
        'poking the provider directly', (tester) async {
      // It used to call `crossProbeVisibleProvider.notifier.toggle()`, so the
      // toolbar and the menu bar reached the same state by two different
      // paths. Both must now go through the one dispatcher.
      final dispatched = await _pump(tester);
      await tester.tap(
        find.byKey(
          const ValueKey<SimcruxAction>(SimcruxAction.openCrossProbePanel),
        ),
      );
      await tester.pump();
      expect(dispatched, <SimcruxAction>[SimcruxAction.openCrossProbePanel]);
    });

    testWidgets('the cross-probe glyph tracks panel visibility', (
      tester,
    ) async {
      // Hidden is the default, so the outlined glyph is what renders.
      await _pump(tester);
      expect(find.byIcon(Icons.sensors_outlined), findsOneWidget);
      expect(find.byIcon(Icons.sensors), findsNothing);
    });

    group('enablement — the gap this migration closed', () {
      testWidgets('greys the config-gated buttons on the empty canvas', (
        tester,
      ) async {
        await _pump(tester, ctx: const SimcruxActionContext());
        expect(
          _buttonFor(tester, SimcruxAction.openProject).onPressed,
          isNotNull,
        );
        expect(_buttonFor(tester, SimcruxAction.openSearch).onPressed, isNull);
        expect(
          _buttonFor(tester, SimcruxAction.closeProject).onPressed,
          isNull,
        );
        expect(
          _buttonFor(tester, SimcruxAction.reRunSelected).onPressed,
          isNull,
          reason: 'nothing is selected to re-run',
        );
      });
    });

    group('the morphing run control', () {
      testWidgets('idle offers Run and never a simultaneous Cancel', (
        tester,
      ) async {
        await _pump(tester);
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        expect(
          find.byIcon(Icons.stop),
          findsNothing,
          reason: 'Run and Cancel used to sit side by side, both always lit',
        );
      });

      testWidgets('running offers Cancel with a progress ring', (tester) async {
        await _pump(tester, ctx: _running, settle: false);
        expect(find.byIcon(Icons.stop), findsOneWidget);
        expect(find.byIcon(Icons.play_arrow), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });

      testWidgets('dispatches run when idle and cancel when running', (
        tester,
      ) async {
        var dispatched = await _pump(tester);
        await tester.tap(find.byIcon(Icons.play_arrow));
        await tester.pump();
        expect(dispatched, [SimcruxAction.runRegression]);

        dispatched = await _pump(tester, ctx: _running, settle: false);
        await tester.tap(find.byIcon(Icons.stop));
        await tester.pump();
        expect(dispatched, [SimcruxAction.cancelRegression]);
      });
    });

    testWidgets('folds in Pro extension-contributed actions', (tester) async {
      await _pump(
        tester,
        extraActions: const [
          Icon(Icons.science_outlined, key: Key('pro-action')),
        ],
      );
      expect(find.byKey(const Key('pro-action')), findsOneWidget);
    });

    testWidgets('renders host-supplied trailing widgets', (tester) async {
      await _pump(
        tester,
        trailing: const [Icon(Icons.memory_outlined, key: Key('trailing'))],
      );
      expect(find.byKey(const Key('trailing')), findsOneWidget);
    });

    testWidgets('shows the overflow button only when the strip overflows', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await _pump(tester, width: 240);
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    group('locale sweep', () {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        testWidgets('renders in $locale without exceptions', (tester) async {
          await _pump(tester, locale: locale);
          expect(tester.takeException(), isNull);
          expect(find.byType(CruxToolbar<SimcruxAction>), findsOneWidget);
        });
      }
    });
  });
}
