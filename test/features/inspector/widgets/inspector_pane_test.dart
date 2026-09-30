// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/log_preview_settings_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/providers/test_trend_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_actions.dart';
import 'package:simcrux/features/inspector/widgets/inspector_details.dart';
import 'package:simcrux/features/inspector/widgets/inspector_header.dart';
import 'package:simcrux/features/inspector/widgets/inspector_log_preview.dart';
import 'package:simcrux/features/inspector/widgets/inspector_pane.dart';
import 'package:simcrux/features/inspector/widgets/inspector_trend.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

const String _kTestId = 'smoke/pass_basic';

SelectedTest _selection() {
  final result = TestResult(
    testId: _kTestId,
    runId: 'r1',
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    exitCode: 0,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    ),
  );
}

/// Overrides that keep the pane's trend / log-preview children off
/// the real SQLite trend store and the async settings store.
List<Override> _selectedOverrides() {
  return [
    selectedTestProvider.overrideWith((_) => _selection()),
    // Static trend data — never touch trendStoreProvider (SQLite) or
    // the trendStoreChangeTickProvider stream in a widget test.
    testTrendProvider(_kTestId).overrideWith(
      (_) => const [TestStatus.pass, TestStatus.fail, TestStatus.pass],
    ),
    // Pin the tail-line count so the log preview never watches the
    // async app-settings provider.
    logPreviewLineCountProvider.overrideWithValue(50),
  ];
}

Future<void> _pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(body: InspectorPane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('InspectorPane', () {
    testWidgets('renders the empty placeholder when no test is selected', (
      tester,
    ) async {
      await _pump(
        tester,
        overrides: [selectedTestProvider.overrideWith((_) => null)],
      );
      expect(tester.takeException(), isNull);
      // The suite-standard empty state (consume the shared widget rather
      // than a hand-rolled local variant) — asserting the
      // TYPE proves InspectorPane actually delegates to it rather than a
      // look-alike Text/Padding/Center tree, and asserting the TEXT proves
      // the ARB key is threaded through correctly.
      expect(find.byType(CruxPanelEmptyState), findsOneWidget);
      expect(
        find.text(
          L10N.of(tester.element(find.byType(Scaffold))).inspectorEmpty,
        ),
        findsOneWidget,
      );
      expect(find.byType(InspectorHeader), findsNothing);
    });

    testWidgets(
      'empty placeholder locale sweep renders the correct message text',
      (tester) async {
        // Coverage moved here from the deleted inspector_empty_test.dart
        // when InspectorEmpty was retired in favour of CruxPanelEmptyState
        // (crux_ide_layout's own panel_empty_state_test.dart covers the
        // shared widget's generic rendering; this proves SimCrux's ARB key
        // resolves through it in every shipped locale).
        for (final locale in const [
          Locale('en'),
          Locale('zh', 'CN'),
          Locale('zh'),
          Locale('ja'),
          Locale('ko'),
        ]) {
          await _pump(
            tester,
            overrides: [selectedTestProvider.overrideWith((_) => null)],
            locale: locale,
          );
          expect(tester.takeException(), isNull, reason: '$locale');
          expect(
            find.text(
              L10N.of(tester.element(find.byType(Scaffold))).inspectorEmpty,
            ),
            findsOneWidget,
            reason: '$locale',
          );
        }
      },
    );

    testWidgets('composes all inspector sections for a selected test', (
      tester,
    ) async {
      await _pump(tester, overrides: _selectedOverrides());
      expect(tester.takeException(), isNull);
      expect(find.byType(CruxPanelEmptyState), findsNothing);
      expect(find.byType(InspectorHeader), findsOneWidget);
      expect(find.byType(InspectorActions), findsOneWidget);
      expect(find.byType(InspectorDetails), findsOneWidget);
      expect(find.byType(InspectorLogPreview), findsOneWidget);
      expect(find.byType(InspectorTrend), findsOneWidget);

      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text('pass_basic'), findsOneWidget);
      expect(find.text(_kTestId), findsOneWidget);
      expect(find.text(l10n.inspectorSectionDetails), findsOneWidget);
      expect(find.text(l10n.inspectorSectionLog), findsOneWidget);
      expect(find.text(l10n.inspectorTrendHeading), findsOneWidget);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(tester, overrides: _selectedOverrides(), locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
