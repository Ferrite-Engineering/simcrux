// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/dialogs/confirm_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Widget _host({
  required void Function(BuildContext) onPressed,
  Locale locale = const Locale('en'),
}) {
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
        builder: (context) => TextButton(
          onPressed: () => onPressed(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  group('showConfirmDialog', () {
    testWidgets('resolves true when the confirm button is tapped', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          onPressed: (context) async {
            result = await showConfirmDialog(
              context: context,
              title: 'Close all?',
              body: 'Everything closes.',
              cancelLabel: 'Cancel',
              confirmLabel: 'Close All',
            );
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('confirmDialog')), findsOneWidget);
      expect(find.text('Close all?'), findsOneWidget);
      expect(find.text('Everything closes.'), findsOneWidget);

      await tester.tap(find.byKey(const Key('confirmDialogConfirm')));
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byKey(const Key('confirmDialog')), findsNothing);
    });

    testWidgets('resolves false when the cancel button is tapped', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          onPressed: (context) async {
            result = await showConfirmDialog(
              context: context,
              title: 'Close all?',
              body: 'Everything closes.',
              cancelLabel: 'Cancel',
              confirmLabel: 'Close All',
            );
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirmDialogCancel')));
      await tester.pumpAndSettle();
      expect(result, isFalse);
    });

    testWidgets('resolves false when the barrier dismisses the dialog', (
      tester,
    ) async {
      bool? result;
      await tester.pumpWidget(
        _host(
          onPressed: (context) async {
            result = await showConfirmDialog(
              context: context,
              title: 'Close all?',
              body: 'Everything closes.',
              cancelLabel: 'Cancel',
              confirmLabel: 'Close All',
            );
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(
        result,
        isFalse,
        reason: 'A dismissed confirmation must never read as a confirmation.',
      );
    });
  });
}
