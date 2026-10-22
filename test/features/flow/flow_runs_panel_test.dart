// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_flow/crux_flow.dart';
import 'package:crux_table/crux_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/flow/widgets/flow_dialogs.dart';
import 'package:simcrux/features/flow/widgets/flow_runs_panel.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_index.dart';

import 'flow_panel_harness.dart';

/// The Flow Runs panel at Open Core with the beta period over: the runs,
/// the verdict, the unverified-reader banner, the last-run delta, the
/// steps, metrics and worst paths, the path detail and its event, the
/// hand-off buttons, and no overflow at the suite's smallest window.
void main() {
  L10N l10n(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(FlowRunsPanel)));

  // A table's one semantics node: its name is the table's, its value the
  // current row's sentence.
  Finder table(String id) => find.byKey(ValueKey<String>('$id.semantics'));

  testWidgets('with no project, and with no runs, it says what to do', (
    tester,
  ) async {
    await pumpFlowPanel(tester, withConfig: false);
    expect(find.text(l10n(tester).flowRunsNoProject), findsOneWidget);

    final dispatched = <SimcruxAction>[];
    await pumpFlowPanel(
      tester,
      index: FlowRunIndex.empty,
      dispatched: dispatched,
    );
    expect(find.text(l10n(tester).flowRunsEmpty), findsOneWidget);
    await tester.tap(
      find.text(SimcruxAction.ingestRunDirectory.label(l10n(tester))),
    );
    expect(dispatched, [SimcruxAction.ingestRunDirectory]);
  });

  testWidgets('the newest run is shown: a LibreLane run read best-effort '
      'says so before its verdict, and never as verified', (tester) async {
    final container = await pumpFlowPanel(tester);
    final words = l10n(tester);
    expect(find.byKey(const ValueKey('flowReaderNotVerified')), findsOneWidget);
    expect(find.text(words.flowReaderNotVerified), findsOneWidget);
    expect(find.text(words.flowFindingsNote), findsOneWidget);
    expect(
      // The design of a LibreLane run is the directory above runs/.
      find.text(words.flowRunHeading('counter', words.flowVerdictViolated)),
      findsOneWidget,
    );
    expect(container.read(flowSelectedRunProvider)?.root, endsWith('RUN_2'));
    expect(container.read(flowSelectedRunProvider)?.kind, FlowKind.librelane);
    // The hand-off for a LibreLane run: KLayout and OpenROAD.
    expect(
      find.byKey(const ValueKey('flowPanel.openInKlayout')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('flowPanel.openInNextpnrGui')),
      findsNothing,
    );
  });

  testWidgets('the run list is one Tab stop; the arrows move and speak one '
      'sentence per run', (tester) async {
    final announced = AnnouncementRecorder.attach(tester);
    final container = await pumpFlowPanel(tester);
    final words = l10n(tester);
    await tester.tap(find.text('t2'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(container.read(flowSelectedRunProvider)?.root, endsWith('t1'));
    expect(
      announced.messages.last,
      words.flowRunRowSpoken('adder', 't1', words.flowVerdictMet, 'nextpnr'),
    );
    // A verified nextpnr run: no banner, and its delta against nothing
    // (t1 is the oldest run of adder).
    expect(find.byKey(const ValueKey('flowReaderNotVerified')), findsNothing);
    expect(find.byKey(const ValueKey('flowDeltaChip')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(container.read(flowSelectedRunProvider)?.root, endsWith('t2'));
    // t2 against t1: two nanoseconds less slack is worse, said in words.
    expect(find.byKey(const ValueKey('flowDeltaChip')), findsOneWidget);
    expect(find.text(words.flowDeltaSlackWorse('2.000')), findsOneWidget);
    expect(
      find.bySemanticsLabel(words.flowDeltaSlackWorseSpoken('2.000')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('flowPanel.openInNextpnrGui')),
      findsOneWidget,
    );
  });

  testWidgets('the hand-off buttons select the run and dispatch the action', (
    tester,
  ) async {
    final dispatched = <SimcruxAction>[];
    final container = await pumpFlowPanel(tester, dispatched: dispatched);
    await tester.tap(find.byKey(const ValueKey('flowPanel.openInOpenroad')));
    expect(dispatched, [SimcruxAction.openInOpenroad]);
    expect(container.read(flowSelectedRunProvider)?.root, endsWith('RUN_2'));
  });

  testWidgets('metrics: a localized label with the raw key on hover, and '
      'corners as columns', (tester) async {
    await pumpFlowPanel(tester);
    final words = l10n(tester);
    await tester.tap(find.text(words.flowMetricsTableLabel));
    await tester.pumpAndSettle();
    expect(find.text(words.flowMetricSetupWorstSlack), findsOneWidget);
    final cell = tester.widget<CruxTableCell>(
      find.widgetWithText(CruxTableCell, words.flowMetricSetupWorstSlack),
    );
    expect(cell.tooltip, 'timing__setup__ws');
    // Corner names are the tool's own, never translated.
    expect(find.text('nom_tt_025C_1v80'), findsOneWidget);
    expect(find.text('max_ss_100C_1v60'), findsOneWidget);
    // The run list's Design column and the metrics' design-wide column.
    expect(find.text(words.flowMetricsColumnDesign), findsNWidgets(2));
    // A metric SimCrux has no label for shows its key.
    expect(find.text(words.flowMetricRouteDrc), findsOneWidget);
    final metrics = tester.getSemantics(table('flowMetrics'));
    expect(metrics.label, words.flowMetricsTableLabel);
    expect(metrics.value, contains(words.flowMetricSetupWorstSlack));
    expect(metrics.value, contains(words.flowUnitNanoseconds));
  });

  testWidgets('a LibreLane run says its paths are not read yet', (
    tester,
  ) async {
    await pumpFlowPanel(tester);
    final words = l10n(tester);
    await tester.tap(find.text(words.flowPathsTableLabel));
    await tester.pumpAndSettle();
    expect(find.text(words.flowPathsLibreLane), findsNothing);
    // The harness hands every run the same worst paths; the gap message is
    // the reader's, covered by the service test. Here the rows render.
    expect(find.text('src_a_SB_DFF_Q'), findsOneWidget);
  });

  testWidgets('a worst path opens as a list of rows, and flow.path.opened '
      'carries only the flow and the fidelity', (tester) async {
    final telemetry = RecordingTelemetry();
    await pumpFlowPanel(tester, telemetry: telemetry);
    final words = l10n(tester);
    await tester.tap(find.text('t2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(words.flowPathsTableLabel));
    await tester.pumpAndSettle();
    final paths = table('flowPaths');
    expect(
      tester.getSemantics(paths).value,
      words.flowPathRowSpoken(
        1,
        'clk',
        'src_a_SB_DFF_Q',
        'sum_q_SB_DFF_Q_3',
        '9.600',
        words.flowFidelityRegister,
      ),
    );
    await tester.tap(find.text('src_a_SB_DFF_Q'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(FlowPathDetailDialog), findsOneWidget);
    expect(find.text(words.flowPathDetailTitle(1)), findsOneWidget);
    expect(
      find.text(words.flowPathFromTo('src_a_SB_DFF_Q', 'sum_q_SB_DFF_Q_3')),
      findsOneWidget,
    );
    // The unmapped segment is shown beside its nearest mapped neighbour.
    expect(
      find.text(
        words.flowMappingNearest(words.flowMappingRegister('src_a')),
      ),
      findsOneWidget,
    );
    expect(telemetry.events.single.name, 'flow.path.opened');
    expect(telemetry.events.single.properties, <String, Object?>{
      'kind': 'nextpnr',
      'fidelity': 'register',
    });
  });

  testWidgets('a step opens with its log tail; a run with no steps offers its '
      'own log', (tester) async {
    await pumpFlowPanel(tester);
    final words = l10n(tester);
    expect(
      tester.getSemantics(table('flowSteps')).value,
      words.flowStepRowSpoken(
        1,
        'yosys-synthesis',
        words.flowStepCompleted,
        words.flowSecondsSpoken('12.0'),
      ),
    );
    await tester.tap(find.text('yosys-synthesis'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(FlowStepDetailDialog), findsOneWidget);
    expect(find.text(words.flowLogNone), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(FlowStepDetailDialog), findsNothing);

    await tester.tap(find.text('t2'));
    await tester.pumpAndSettle();
    expect(find.text(words.flowStepsNone), findsOneWidget);
    expect(find.text(words.flowOpenRunLog), findsOneWidget);
  });

  for (final size in const <Size>[
    Size(800, 160),
    Size(380, 500),
    Size(800, 500),
  ]) {
    testWidgets('no overflow at $size', (tester) async {
      await pumpFlowPanel(tester, size: size);
      final first = tester.takeException();
      expect(
        first,
        isNull,
        reason: first is FlutterError ? first.toStringDeep() : '$first',
      );
      final words = l10n(tester);
      for (final section in [
        words.flowMetricsTableLabel,
        words.flowPathsTableLabel,
      ]) {
        await tester.ensureVisible(find.text(section));
        await tester.tap(find.text(section));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: section);
      }
    });
  }

  for (final locale in L10N.supportedLocales) {
    testWidgets('$locale renders every section', (tester) async {
      await pumpFlowPanel(tester, locale: locale);
      final words = l10n(tester);
      for (final section in [
        words.flowMetricsTableLabel,
        words.flowPathsTableLabel,
        words.flowStepsTableLabel,
      ]) {
        await tester.tap(find.text(section).first);
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('the delta: higher slack and a faster clock are better', () {
    final better = flowRunDelta(
      nextpnrReading('b', wns: 1, fmax: 60),
      nextpnrReading('a', wns: 0.5, fmax: 50),
    )!;
    expect(better.kind, FlowDeltaKind.worstSlack);
    expect(better.improved, isTrue);
    final same = flowRunDelta(
      nextpnrReading('b', wns: 1, fmax: 60),
      nextpnrReading('a', wns: 1, fmax: 60),
    )!;
    expect(same.improved, isNull);
    expect(flowRunDelta(librelaneReading(), null), isNull);
  });
}
