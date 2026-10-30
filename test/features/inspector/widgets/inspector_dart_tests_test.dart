// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_dart_tests.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/simulator/dart_test_metrics.dart';
import 'package:simcrux/services/simulator/dart_test_report.dart';

bool _anyFile(String path) => true;

Map<String, String> _fixtureMetrics() => dartTestMetrics(
  parseDartTestReport(
    File('verification/fixtures/rohd/dart-test.json').readAsStringSync(),
  )!,
  resolve: (uri) => resolveDartSourcePath(
    uri,
    packageRoot: '/work/rohd_fixture',
    packageName: 'rohd_fixture',
  ),
);

SelectedTest _selection(Map<String, String> metrics) {
  final result = TestResult(
    testId: 'rohd/adder',
    runId: 'r1',
    status: TestStatus.fail,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(seconds: 1)),
    metrics: metrics,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'rohd',
      simulatorId: 'dart_test',
      testName: 'adder',
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  SelectedTest selection, {
  Locale locale = const Locale('en'),
  List<(String, List<String>)>? launched,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        editorLauncherProvider.overrideWithValue(
          EditorLauncher(
            template: 'code --goto {file}:{line}:{column}',
            processStarter: (executable, args) async {
              launched?.add((executable, args));
              throw ProcessException(executable, args, 'recorded');
            },
            spawnHost: const SpawnHost(windows: false, exists: _anyFile),
            extraSearchDirs: const <String>[],
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
          body: SingleChildScrollView(
            child: InspectorDartTests(selection: selection),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('InspectorDartTests', () {
    testWidgets('lists the cases, failing first, with the summary', (
      tester,
    ) async {
      await _pump(tester, _selection(_fixtureMetrics()));
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorSectionDartTests), findsOneWidget);
      expect(
        find.text(l10n.inspectorDartTestsSummary(4, 2, 0)),
        findsOneWidget,
      );
      expect(
        find.text(l10n.inspectorDartTestsObjections(2)),
        findsOneWidget,
        reason: 'objection warnings are surfaced',
      );
      final names = <String>[
        'plain rohd adder fails',
        'rohd-vf fails',
        'plain rohd adder passes',
        'rohd-vf passes',
      ];
      final tops = [
        for (final n in names)
          tester.getTopLeft(find.byKey(ValueKey('dartTestRow:$n'))).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
    });

    testWidgets('shows the ROHD-VF severe log lines of a failing case', (
      tester,
    ) async {
      await _pump(tester, _selection(_fixtureMetrics()));
      expect(
        find.textContaining('SEVERE at 0, add_test: mismatch'),
        findsNWidgets(3),
      );
    });

    testWidgets('Go to Source opens the Dart file at the failing line', (
      tester,
    ) async {
      final launched = <(String, List<String>)>[];
      await _pump(tester, _selection(_fixtureMetrics()), launched: launched);
      await tester.tap(
        find.byKey(const ValueKey('dartTestGoToSource:rohd-vf fails')),
      );
      await tester.pump();
      expect(launched.single.$1, 'code');
      expect(launched.single.$2, [
        '--goto',
        '/work/rohd_fixture/test/probe_test.dart:87:5',
      ]);
    });

    testWidgets('renders nothing for a row that is not a Dart test run', (
      tester,
    ) async {
      await _pump(tester, _selection(const {'cocotb.tests': '2'}));
      expect(find.byKey(const ValueKey('inspectorDartTests')), findsNothing);
    });

    testWidgets('says when the run did not finish', (tester) async {
      await _pump(
        tester,
        _selection({..._fixtureMetrics(), 'dart.complete': 'false'}),
      );
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorDartTestsIncomplete), findsOneWidget);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(tester, _selection(_fixtureMetrics()), locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
        expect(
          find.byKey(const ValueKey('inspectorDartTests')),
          findsOneWidget,
        );
      }
    });
  });
}
