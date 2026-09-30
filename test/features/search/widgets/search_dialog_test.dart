// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/search/widgets/search_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

TestSpec _test(String suite, String name, {String sim = 'icarus'}) => TestSpec(
  id: '$suite.$name',
  name: name,
  suiteName: suite,
  simulatorId: sim,
  top: 'tb_$name',
  sources: const ['tb.sv'],
);

void main() {
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester, {Locale? locale}) async {
    container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(activeConfigProvider.notifier)
        .replace(
          RegressionConfig(
            projectFilePath: '/tmp/simcrux.yaml',
            schemaVersion: '1',
            simulatorBinaries: const {},
            suites: [
              Suite(name: 'cpu', tests: [_test('cpu', 'alu_smoke')]),
              Suite(
                name: 'uart',
                tests: [
                  _test('uart', 'tx_basic'),
                  _test('uart', 'rx_overrun', sim: 'verilator'),
                ],
              ),
            ],
          ),
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: L10N.localizationsDelegates,
          supportedLocales: L10N.supportedLocales,
          home: const Scaffold(body: SimcruxSearchDialog()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('blank until queried, then filters by name and suite', (
    tester,
  ) async {
    await pump(tester);
    // Suite canon (CruxSearchDialog): an empty query shows no rows.
    expect(find.text('alu_smoke'), findsNothing);
    expect(find.text('tx_basic'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('simcruxSearchField')),
      'uart',
    );
    await tester.pump(kCruxSearchDebounceInterval * 2);
    expect(find.text('alu_smoke'), findsNothing);
    expect(find.text('tx_basic'), findsOneWidget);
    expect(find.text('rx_overrun'), findsOneWidget);
  });

  testWidgets('matches by simulator id too', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('simcruxSearchField')),
      'verilator',
    );
    await tester.pump(kCruxSearchDebounceInterval * 2);
    expect(find.text('rx_overrun'), findsOneWidget);
    expect(find.text('tx_basic'), findsNothing);
  });

  testWidgets('tapping a row selects the test in the shared provider', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('simcruxSearchField')),
      'tx',
    );
    await tester.pump(kCruxSearchDebounceInterval * 2);
    await tester.tap(
      find.byKey(const ValueKey('simcruxSearchResult-uart.tx_basic')),
    );
    await tester.pump();
    expect(container.read(selectedTestIdProvider), 'uart.tx_basic');
  });

  // The dialog's own chrome is entirely localized — the search field hint, the
  // blank-state line and the result-count summary — while the assertions above
  // match fixture test names, which are locale-invariant. Additive sweep so a
  // CJK rendering that overflows or throws is caught here rather than by a
  // user.
  for (final locale in L10N.supportedLocales) {
    testWidgets('renders and filters without exceptions in '
        '${locale.toLanguageTag()}', (tester) async {
      await pump(tester, locale: locale);

      await tester.enterText(
        find.byKey(const ValueKey('simcruxSearchField')),
        'uart',
      );
      await tester.pump(kCruxSearchDebounceInterval * 2);

      expect(tester.takeException(), isNull);
      expect(find.text('tx_basic'), findsOneWidget);
    });
  }
}
