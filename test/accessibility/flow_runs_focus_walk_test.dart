// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a keyboard and screen-reader user meets in the Flow Runs panel: the
// run list as one Tab stop named by its current run, the run's hand-off
// buttons, the Steps / Metrics / Worst paths switch, and the table it
// shows, one Tab stop named by its current row. And that the step and path
// dialogs never serialize a semantics node the desktop bridge would
// reject.
//
// The transcripts under `goldens/` are what the focus walk records, in text
// and independent of the renderer. Rewrite them with
// `flutter test --update-goldens test/accessibility/flow_runs_focus_walk_test.dart`
// and read the diff before committing.

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/flow/widgets/flow_runs_panel.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../features/flow/flow_panel_harness.dart';

void main() {
  SemanticsOrphanTestBinding.ensureInitialized();

  testWidgets(
    'the Flow Runs panel: the runs, the hand-off, the switch, the steps',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFlowPanel(tester, size: const Size(1100, 700));
      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'View > Flow Runs');
      expectFocusWalkGolden(walk, 'test/accessibility/goldens/flow_runs.txt');
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the worst-paths table: one Tab stop named by its current path',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pumpFlowPanel(tester, size: const Size(1100, 700));
      final l10n = L10N.of(tester.element(find.byType(FlowRunsPanel)));
      await tester.tap(find.text('t2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.flowPathsTableLabel));
      await tester.pumpAndSettle();
      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'Flow Runs, Worst paths');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/flow_worst_paths.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('opening and closing the step and path dialogs serializes no '
      'orphan node', (tester) async {
    SemanticsOrphanGuard.instance.reset();
    final handle = tester.ensureSemantics();
    await pumpFlowPanel(tester, size: const Size(1100, 700));
    final l10n = L10N.of(tester.element(find.byType(FlowRunsPanel)));
    await tester.tap(find.text('yosys-synthesis'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    await tester.tap(find.text('t2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.flowPathsTableLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('src_a_SB_DFF_Q'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    handle.dispose();
    SemanticsOrphanGuard.instance.check(context: 'Flow Runs dialogs');
    expect(SemanticsOrphanGuard.instance.updates, greaterThan(1));
  });
}
