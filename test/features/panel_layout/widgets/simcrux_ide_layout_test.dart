// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/panel_layout/widgets/simcrux_ide_layout.dart';
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
