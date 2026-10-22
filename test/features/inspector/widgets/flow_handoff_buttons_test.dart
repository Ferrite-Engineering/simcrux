// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/flow_handoff_buttons.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';
import 'package:simcrux/services/flow/flow_handoff_provider.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';

/// The inspector's flow hand-off: a LibreLane result offers KLayout and
/// OpenROAD, a nextpnr result offers nextpnr, any other result offers
/// nothing; a press starts the viewer detached, and a missing viewer says so
/// in a toast. `flow.handoff.launched` and `flow.tool.missing` are recorded.
void main() {
  late Directory run;
  late List<List<String>> started;
  late List<TelemetryEvent> events;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    run = Directory.systemTemp.createTempSync('flow_handoff_ui_');
    Directory(p.join(run.path, 'final', 'gds')).createSync(recursive: true);
    File(p.join(run.path, 'final', 'gds', 'counter.gds')).writeAsStringSync('');
    started = <List<String>>[];
    events = <TelemetryEvent>[];
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

  Future<void> pump(
    WidgetTester tester,
    SelectedTest selected, {
    bool missing = false,
    Locale? locale,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
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
            body: Consumer(
              builder: (context, ref, _) =>
                  Wrap(children: flowHandoffButtons(context, ref, selected)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a LibreLane result opens its GDS in KLayout', (tester) async {
    await pump(tester, selection('librelane'));
    expect(find.byKey(const ValueKey('flowHandoff.klayout')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('flowHandoff.openroad_gui')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('flowHandoff.klayout')));
    // The fake starter completes at once; the plan only lists the run.
    await tester.pumpAndSettle();
    expect(started.single.first, 'klayout');
    expect(started.single.last, endsWith('counter.gds'));
    expect(events.single.name, 'flow.handoff.launched');
    expect(events.single.properties, {'viewer': 'klayout', 'ok': true});
  });

  testWidgets('a missing viewer is a toast and flow.tool.missing', (
    tester,
  ) async {
    await pump(tester, selection('librelane'), missing: true);
    await tester.tap(find.byKey(const ValueKey('flowHandoff.klayout')));
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
      find.byKey(const ValueKey('flowHandoff.nextpnr_gui')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('flowHandoff.klayout')), findsNothing);
    await pump(tester, selection(null));
    expect(find.byType(OutlinedButton), findsNothing);
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
