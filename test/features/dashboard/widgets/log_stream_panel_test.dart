// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/dashboard/widgets/log_stream_panel.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';

void main() {
  group('LogStreamPanel', () {
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
            home: const Scaffold(body: LogStreamPanel()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // Locale sweep on the empty state — no test selected.
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders empty state cleanly in $locale', (tester) async {
        await pump(
          tester,
          locale,
          overrides: [
            selectedTestProvider.overrideWith((_) => null),
          ],
        );
      });
    }

    testWidgets(
      'renders log lines when a test is selected and the buffer has content',
      (tester) async {
        final result = TestResult(
          runId: 'r1',
          testId: 'smoke/pass_basic',
          status: TestStatus.pass,
          startedAt: DateTime.utc(2026),
          finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
          exitCode: 0,
        );
        final row = DashboardRow(
          result: result,
          suiteName: 'smoke',
          simulatorId: 'icarus',
          testName: 'pass_basic',
        );
        await pump(
          tester,
          const Locale('en'),
          overrides: [
            selectedTestProvider.overrideWith(
              (_) => SelectedTest(row: row),
            ),
            fullInspectorLogProvider('smoke/pass_basic').overrideWith(
              (_) => const [
                LogLine(line: 'hello world', fromStderr: false),
                LogLine(line: 'TEST PASSED', fromStderr: false),
                LogLine(line: 'stderr noise', fromStderr: true),
              ],
            ),
          ],
        );
        expect(find.text('hello world'), findsOneWidget);
        expect(find.text('TEST PASSED'), findsOneWidget);
        expect(find.text('stderr noise'), findsOneWidget);
      },
    );
  });
}
