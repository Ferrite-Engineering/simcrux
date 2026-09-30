// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/test_browser_panel.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

TestSpec _spec(String suite, String name) {
  return TestSpec(
    id: '$suite/$name',
    name: name,
    suiteName: suite,
    simulatorId: 'icarus',
    top: 'tb',
  );
}

DashboardRow _row(String suite, String name, TestStatus status) {
  final id = '$suite/$name';
  return DashboardRow(
    result: TestResult(
      runId: 'r1',
      testId: id,
      status: status,
      startedAt: DateTime.utc(2026),
      finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
      exitCode: status == TestStatus.pass ? 0 : 1,
    ),
    suiteName: suite,
    simulatorId: 'icarus',
    testName: name,
  );
}

RegressionConfig _config() {
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(name: 'smoke', tests: [_spec('smoke', 'pass_basic')]),
      Suite(name: 'unit', tests: [_spec('unit', 'alu'), _spec('unit', 'fail')]),
    ],
    simulatorBinaries: const {},
  );
}

void main() {
  group('TestBrowserPanel', () {
    Future<void> pump(
      WidgetTester tester,
      Locale locale, {
      List<Override> overrides = const [],
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: overrides,
          child: MaterialApp(
            locale: locale,
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: const Scaffold(body: TestBrowserPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // Locale sweep of the empty state (no config loaded).
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders empty state cleanly in $locale', (tester) async {
        await pump(tester, locale);
      });
    }

    testWidgets(
      'renders suites and tests when a config is loaded',
      (tester) async {
        await pump(
          tester,
          const Locale('en'),
          overrides: [
            activeConfigProvider.overrideWith(_StubActiveConfig.new),
            dashboardRowsProvider.overrideWith(
              (ref) => Stream.value([
                _row('smoke', 'pass_basic', TestStatus.pass),
                _row('unit', 'alu', TestStatus.pass),
                _row('unit', 'fail', TestStatus.fail),
              ]),
            ),
          ],
        );
        // Suite headers.
        expect(find.text('smoke'), findsOneWidget);
        expect(find.text('unit'), findsOneWidget);
        // Test names (the rows under each suite).
        expect(find.text('pass_basic'), findsOneWidget);
        expect(find.text('alu'), findsOneWidget);
        expect(find.text('fail'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a test row drives selectedTestIdProvider',
      (tester) async {
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              activeConfigProvider.overrideWith(_StubActiveConfig.new),
              dashboardRowsProvider.overrideWith(
                (ref) => Stream.value([
                  _row('smoke', 'pass_basic', TestStatus.pass),
                ]),
              ),
            ],
            child: Consumer(
              builder: (ctx, ref, _) {
                container = ProviderScope.containerOf(ctx, listen: false);
                return const MaterialApp(
                  localizationsDelegates: [
                    L10N.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                  ],
                  supportedLocales: L10N.supportedLocales,
                  home: Scaffold(body: TestBrowserPanel()),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(container.read(selectedTestIdProvider), isNull);
        await tester.tap(find.text('pass_basic'));
        await tester.pump();
        expect(container.read(selectedTestIdProvider), 'smoke/pass_basic');
      },
    );
  });
}

class _StubActiveConfig extends ActiveConfigNotifier {
  @override
  RegressionConfig? build() => _config();
}
