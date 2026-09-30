// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/test_detail/screens/test_detail_screen.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: const [
      L10N.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: L10N.supportedLocales,
    home: child,
  );
}

void main() {
  group('TestDetailScreen', () {
    testWidgets('renders the localized title and placeholder body', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const TestDetailScreen(
            projectId: 'demo',
            runId: 'run-1',
            testId: 'test-1',
          ),
        ),
      );
      expect(find.text('Test detail'), findsOneWidget);
      expect(find.textContaining('results table'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final locale in const [
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without exception for ${locale.toLanguageTag()}', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(
            const TestDetailScreen(
              projectId: 'demo',
              runId: 'run-1',
              testId: 'test-1',
            ),
            locale: locale,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
