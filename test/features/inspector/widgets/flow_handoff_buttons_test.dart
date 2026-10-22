// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/features/flow/providers/flow_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/flow_handoff_buttons.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

/// The inspector's flow hand-off: a LibreLane result offers KLayout and
/// OpenROAD, a nextpnr result offers nextpnr, any other result offers
/// nothing. A press makes the result's run the selected flow run and
/// dispatches the same action as Tools > Open in KLayout…, whose handler
/// starts the viewer detached, or says in a toast that it is missing.
/// `flow.handoff.launched` and `flow.tool.missing` are recorded.
void main() {
  late Directory run;
  late List<List<String>> started;
  late List<TelemetryEvent> events;
  late List<SimcruxAction> dispatched;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    run = Directory.systemTemp.createTempSync('flow_handoff_ui_');
    Directory(p.join(run.path, 'final', 'gds')).createSync(recursive: true);
    File(p.join(run.path, 'final', 'gds', 'counter.gds')).writeAsStringSync('');
    started = <List<String>>[];
    events = <TelemetryEvent>[];
    dispatched = <SimcruxAction>[];
  });
  tearDown(() => run.deleteSync(recursive: true));

  SelectedTest selection(String? kind) => SelectedTest(
    row: DashboardRow(
      result: TestResult(
        testId: 'flow/counter',
        runId: 'r',
        status: TestStatus.fail,
        startedAt: DateTime.utc(2026),
        finishedAt: DateTime.utc(2026),
        metrics: kind == null
            ? const <String, String>{}
            : <String, String>{
                FlowMetricKeys.kind: kind,
                FlowMetricKeys.runDir: run.path,
                FlowMetricKeys.verdict: 'violated',
              },
      ),
      suiteName: 'flow',
      simulatorId: kind ?? 'icarus',
      testName: 'counter',
    ),
  );

  FlowViewer viewerFor(SimcruxAction action) => switch (action) {
    SimcruxAction.openInKlayout => FlowViewer.klayout,
    SimcruxAction.openInOpenroad => FlowViewer.openroadGui,
    _ => FlowViewer.nextpnrGui,
  };

  Future<ProviderContainer> pump(
    WidgetTester tester,
    SelectedTest selected, {
    bool missing = false,
    Locale? locale,
  }) async {
    final container = ProviderContainer(
      overrides: [
        flowHandoffLauncherProvider.overrideWithValue(
          FlowHandoffLauncher(
            telemetry: _Recording(events),
            start: (exe, args, {workingDirectory, environment}) async {
              if (missing) throw ProcessException(exe, args, 'not found', 2);
              started.add(<String>[exe, ...args]);
            },
          ),
        ),
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
          home: Scaffold(
            body: Builder(
              // The app's handler map, for the three hand-off actions: the
              // same FlowActions.handoff the menu and the palette reach.
              builder: (context) => Actions(
                actions: <Type, Action<Intent>>{
                  SimcruxActionIntent: CallbackAction<SimcruxActionIntent>(
                    onInvoke: (intent) {
                      dispatched.add(intent.action);
                      unawaited(
                        FlowActions.handoff(
                          context,
                          container,
                          container.read,
                          viewerFor(intent.action),
                        ),
                      );
                      return null;
                    },
                  ),
                },
                child: Consumer(
                  builder: (context, ref, _) => Wrap(
                    children: flowHandoffButtons(context, ref, selected),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('a LibreLane result opens its GDS in KLayout through the '
      'Open in KLayout action', (tester) async {
    final container = await pump(tester, selection('librelane'));
    final klayout = find.byKey(const ValueKey('flowHandoff.openInKlayout'));
    expect(klayout, findsOneWidget);
    expect(
      find.byKey(const ValueKey('flowHandoff.openInOpenroad')),
      findsOneWidget,
    );
    await tester.tap(klayout);
    await tester.pumpAndSettle();
    expect(dispatched, [SimcruxAction.openInKlayout]);
    expect(
      container.read(flowSelectedRunProvider),
      FlowRunSelection(
        root: run.path,
        kind: FlowKind.librelane,
        design: 'counter',
      ),
    );
    expect(started.single.first, 'klayout');
    expect(started.single.last, endsWith('counter.gds'));
    expect(events.single.name, 'flow.handoff.launched');
    expect(events.single.properties, {'viewer': 'klayout', 'ok': true});
  });

  testWidgets('a missing viewer is a toast and flow.tool.missing', (
    tester,
  ) async {
    await pump(tester, selection('librelane'), missing: true);
    await tester.tap(find.byKey(const ValueKey('flowHandoff.openInKlayout')));
    await tester.pumpAndSettle();
    final l10n = L10N.of(tester.element(find.byType(Scaffold)));
    expect(find.text(l10n.inspectorFlowViewerMissing('KLayout')), findsOne);
    expect(events.map((e) => e.name), [
      'flow.handoff.launched',
      'flow.tool.missing',
    ]);
  });

  testWidgets('a nextpnr result offers nextpnr only; others offer nothing', (
    tester,
  ) async {
    await pump(tester, selection('nextpnr'));
    expect(
      find.byKey(const ValueKey('flowHandoff.openInNextpnrGui')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('flowHandoff.openInKlayout')),
      findsNothing,
    );
    await pump(tester, selection(null));
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('a hand-off of the other kind says which runs it opens', (
    tester,
  ) async {
    final container = await pump(tester, selection('nextpnr'));
    final ctx = tester.element(find.byType(Scaffold));
    container
        .read(flowSelectedRunProvider.notifier)
        .select(
          FlowRunSelection(root: run.path, kind: FlowKind.nextpnr),
        );
    unawaited(
      FlowActions.handoff(
        ctx,
        container,
        container.read,
        FlowViewer.klayout,
      ),
    );
    await tester.pumpAndSettle();
    final l10n = L10N.of(ctx);
    expect(find.text(l10n.flowHandoffNeedsLibreLane('KLayout')), findsOne);
    expect(started, isEmpty);
  });

  testWidgets('no run selected says so', (tester) async {
    final container = await pump(tester, selection(null));
    final ctx = tester.element(find.byType(Scaffold));
    unawaited(
      FlowActions.handoff(
        ctx,
        container,
        container.read,
        FlowViewer.klayout,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(L10N.of(ctx).flowHandoffNoRun), findsOne);
  });

  testWidgets('every locale labels the buttons', (tester) async {
    for (final locale in L10N.supportedLocales) {
      await pump(tester, selection('librelane'), locale: locale);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorActionOpenInKlayout), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}

class _Recording implements TelemetryService {
  _Recording(this.events);

  final List<TelemetryEvent> events;

  @override
  void record(TelemetryEvent event) => events.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
