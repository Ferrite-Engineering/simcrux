// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_dock/crux_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/panel_layout/widgets/simcrux_ide_layout.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_docks.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return ProviderScope(
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the four-pane scaffold with placeholders', (
    tester,
  ) async {
    // The Log panel starts collapsed; an explicit "visible" choice opens it.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'simcrux.panel.logPanelVisible': true,
      'simcrux.panel.logPanelChoice': true,
    });
    await tester.pumpWidget(_wrap(const SimcruxIdeLayout()));
    await tester.pumpAndSettle();

    // Each placeholder text comes from the en ARB. Substrings are
    // chosen from each pane's panelXxxPlaceholder string so the
    // assertions survive minor copy edits.
    expect(
      find.textContaining('Open a project'), // panelTestBrowserPlaceholder
      findsOneWidget,
    );
    expect(
      find.textContaining('Run results'), // panelRunResultsPlaceholder
      findsOneWidget,
    );
    expect(
      find.textContaining('Run details'), // panelRunDetailsPlaceholder
      findsOneWidget,
    );
    expect(
      find.textContaining('Select a test'), // panelLogStreamPlaceholder
      findsOneWidget,
    );
  });

  testWidgets('caller-injected builders replace defaults', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'simcrux.panel.logPanelVisible': true,
      'simcrux.panel.logPanelChoice': true,
    });
    await tester.pumpWidget(
      _wrap(
        SimcruxIdeLayout(
          testBrowserBuilder: (_) => const Text('CUSTOM-BROWSER'),
          runResultsBuilder: (_) => const Text('CUSTOM-RESULTS'),
          runDetailsBuilder: (_) => const Text('CUSTOM-DETAILS'),
          logPanelBuilder: (_) => const Text('CUSTOM-LOG'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CUSTOM-BROWSER'), findsOneWidget);
    expect(find.text('CUSTOM-RESULTS'), findsOneWidget);
    expect(find.text('CUSTOM-DETAILS'), findsOneWidget);
    expect(find.text('CUSTOM-LOG'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Log panel at startup (1280x700)', () {
    const testId = 'smoke/pass_basic';
    final row = DashboardRow(
      result: TestResult(
        runId: 'r1',
        testId: testId,
        status: TestStatus.pass,
        startedAt: DateTime.utc(2026),
        finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
        exitCode: 0,
      ),
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    );

    // Height the layout hands the results pane, as the dashboard sees it.
    var resultsHeight = 0.0;

    Future<ProviderContainer> pumpLayout(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedTestProvider.overrideWith(
              (ref) => ref.watch(selectedTestIdProvider) == null
                  ? null
                  : SelectedTest(row: row),
            ),
            fullInspectorLogProvider(testId).overrideWith(
              (_) => const [LogLine(line: 'TEST PASSED', fromStderr: false)],
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return SimcruxIdeLayout(
                    testBrowserBuilder: (_) => const Text('BROWSER'),
                    runResultsBuilder: (_) => LayoutBuilder(
                      builder: (context, constraints) {
                        resultsHeight = constraints.maxHeight;
                        return Consumer(
                          builder: (context, ref, _) => TextButton(
                            onPressed: () => ref
                                .read(selectedTestIdProvider.notifier)
                                .select(testId),
                            child: const Text('SELECT'),
                          ),
                        );
                      },
                    ),
                    runDetailsBuilder: (_) => const Text('DETAILS'),
                    logPanelBuilder: (_) => const SimcruxBottomDock(),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await container.read(appSettingsProvider.future);
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('the bottom region is collapsed until a test is selected', (
      tester,
    ) async {
      final container = await pumpLayout(tester);

      // Collapsed: the restore bar shows, no log content, full-height table.
      expect(find.byType(CruxDockRestoreBar), findsOneWidget);
      expect(find.text('TEST PASSED'), findsNothing);
      expect(find.textContaining('Select a test'), findsNothing);
      final collapsedHeight = resultsHeight;

      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      expect(find.byType(CruxDockRestoreBar), findsNothing);
      expect(find.text('TEST PASSED'), findsOneWidget);
      expect(
        container.read(panelLayoutProvider).logPanelChoiceMade,
        isFalse,
        reason: 'the automatic reveal is not a user choice',
      );
      // Opening the panel takes its share from the results table.
      expect(collapsedHeight, greaterThan(500));
      expect(resultsHeight, lessThan(collapsedHeight));
    });

    testWidgets('an explicit collapse is respected by the next selection', (
      tester,
    ) async {
      final container = await pumpLayout(tester);
      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();
      expect(find.text('TEST PASSED'), findsOneWidget);

      await container
          .read(panelLayoutProvider.notifier)
          .setLogPanelVisible(visible: false);
      container.read(selectedTestIdProvider.notifier).clear();
      await tester.pumpAndSettle();
      container.read(selectedTestIdProvider.notifier).select(testId);
      await tester.pumpAndSettle();

      expect(find.byType(CruxDockRestoreBar), findsOneWidget);
      expect(find.text('TEST PASSED'), findsNothing);
    });

    testWidgets('an explicit hidden choice never auto-reveals', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'simcrux.panel.logPanelVisible': false,
      }); // 1.0 install that hid the panel: migrated to a choice
      await pumpLayout(tester);
      await tester.tap(find.text('SELECT'));
      await tester.pumpAndSettle();

      expect(find.byType(CruxDockRestoreBar), findsOneWidget);
      expect(find.text('TEST PASSED'), findsNothing);
    });
  });

  for (final locale in const <Locale>[
    Locale('en'),
    Locale('zh', 'CN'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('locale sweep: renders cleanly in ${locale.toLanguageTag()}', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const SimcruxIdeLayout(), locale: locale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
