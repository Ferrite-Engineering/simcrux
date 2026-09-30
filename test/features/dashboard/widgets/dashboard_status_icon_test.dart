// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

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
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

String _expectedTooltip(L10N l10n, TestStatus status) {
  switch (status) {
    case TestStatus.pass:
      return l10n.testStatusPass;
    case TestStatus.fail:
      return l10n.testStatusFail;
    case TestStatus.running:
      return l10n.testStatusRunning;
    case TestStatus.skipped:
      return l10n.testStatusSkipped;
    case TestStatus.timeout:
      return l10n.testStatusTimeout;
    case TestStatus.cancelled:
      return l10n.testStatusCancelled;
    case TestStatus.vacuous:
      return l10n.testStatusVacuous;
    case TestStatus.cover:
      return l10n.testStatusCover;
    case TestStatus.unknown:
      return l10n.testStatusUnknown;
  }
}

void main() {
  group('DashboardStatusIcon', () {
    testWidgets('renders a localized tooltip for the pass status', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const DashboardStatusIcon(status: TestStatus.pass)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, l10n.testStatusPass);
      expect(find.byType(Icon), findsOneWidget);
    });

    testWidgets(
      'renders distinct iconography and localized tooltips for every '
      'TestStatus',
      (tester) async {
        final seenIcons = <IconData>{};
        for (final status in TestStatus.values) {
          await tester.pumpWidget(
            _wrap(DashboardStatusIcon(status: status)),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$status');
          final l10n = L10N.of(tester.element(find.byType(Scaffold)));
          final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
          expect(
            tooltip.message,
            _expectedTooltip(l10n, status),
            reason: '$status tooltip should be the localized status label',
          );
          final icon = tester.widget<Icon>(find.byType(Icon));
          expect(icon.icon, isNotNull, reason: '$status');
          seenIcons.add(icon.icon!);
        }
        expect(
          seenIcons,
          hasLength(TestStatus.values.length),
          reason: 'every status must map to a distinct IconData',
        );
      },
    );

    testWidgets('honors the size parameter', (tester) async {
      await tester.pumpWidget(
        _wrap(const DashboardStatusIcon(status: TestStatus.fail, size: 32)),
      );
      await tester.pumpAndSettle();
      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 32);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await tester.pumpWidget(
          _wrap(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final status in TestStatus.values)
                  DashboardStatusIcon(status: status),
              ],
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
