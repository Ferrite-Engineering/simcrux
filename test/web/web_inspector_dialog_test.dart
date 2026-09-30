// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/web/web_inspector_dialog.dart';
import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_status_chip.dart';

Widget _wrap(WebResultRow row, {Locale? locale}) {
  return MaterialApp(
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
        builder: (context) => Center(
          child: ElevatedButton(
            onPressed: () {
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (_) => WebInspectorDialog(row: row),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

WebResultRow _row({
  String testId = 'axi/burst',
  TestStatus status = TestStatus.pass,
  Duration runtime = const Duration(milliseconds: 1500),
  int? exitCode,
  String? failureMessage,
  Map<String, String> metrics = const {},
}) {
  return WebResultRow(
    testId: testId,
    testName: 'burst',
    suiteName: 'axi',
    simulatorId: 'icarus',
    status: status,
    runtime: runtime,
    exitCode: exitCode,
    failureMessage: failureMessage,
    metrics: metrics,
  );
}

void main() {
  group('WebInspectorDialog', () {
    testWidgets('renders the title with the test id and the always-shown '
        'fields', (tester) async {
      await tester.pumpWidget(_wrap(_row()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Test details — axi/burst'), findsOneWidget);
      expect(find.text('Status'), findsOneWidget);
      expect(find.byType(WebStatusChip), findsOneWidget);
      expect(find.text('Runtime'), findsOneWidget);
      expect(find.text('Suite'), findsOneWidget);
      expect(find.text('axi'), findsOneWidget);
      expect(find.text('Simulator'), findsOneWidget);
      expect(find.text('icarus'), findsOneWidget);
    });

    testWidgets('exit code row is hidden when null, shown when present', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_row()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Exit code'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(_wrap(_row(exitCode: 1)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Exit code'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('failure message row is hidden when null/empty, shown when '
        'non-empty', (tester) async {
      await tester.pumpWidget(_wrap(_row(failureMessage: '')));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Failure'), findsNothing);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.pumpWidget(
        _wrap(_row(failureMessage: 'expected 0x42, got 0x41')),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Failure'), findsOneWidget);
      expect(find.text('expected 0x42, got 0x41'), findsOneWidget);
    });

    testWidgets('metrics section is hidden when empty, lists key = value '
        'when present', (tester) async {
      await tester.pumpWidget(
        _wrap(_row(metrics: const {'coverage': '87%', 'lines': '412'})),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Metrics'), findsOneWidget);
      expect(find.text('coverage = 87%'), findsOneWidget);
      expect(find.text('lines = 412'), findsOneWidget);
    });

    testWidgets('Close button pops the dialog', (tester) async {
      await tester.pumpWidget(_wrap(_row()));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(WebInspectorDialog), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.byType(WebInspectorDialog), findsNothing);
    });

    group('runtime formatting', () {
      testWidgets('sub-second runtimes render as milliseconds', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(_row(runtime: const Duration(milliseconds: 250))),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('250 ms'), findsOneWidget);
      });

      testWidgets('sub-minute runtimes render as seconds with 2 decimals', (
        tester,
      ) async {
        // `_row`'s default runtime (1500ms) is already the sub-minute
        // case under test.
        await tester.pumpWidget(_wrap(_row()));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('1.50 s'), findsOneWidget);
      });

      testWidgets('minute-plus runtimes render as Xm Ys', (tester) async {
        await tester.pumpWidget(
          _wrap(_row(runtime: const Duration(seconds: 75))),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.text('1m 15.0s'), findsOneWidget);
      });
    });

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('locale sweep — ${locale.toLanguageTag()}', (tester) async {
        await tester.pumpWidget(
          _wrap(
            _row(
              exitCode: 2,
              failureMessage: 'boom',
              metrics: const {'k': 'v'},
            ),
            locale: locale,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });
}
