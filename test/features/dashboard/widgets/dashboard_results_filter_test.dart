// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_async/crux_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_bar.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_heatmap_view.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

// The results filter, driven through the real filter bar and results table:
// a run is found by the seed its row shows, a filter that excludes every row
// says so instead of claiming there are no results, and Clear filters works
// when only the text filter is set.

TestResult _result(String id, TestStatus status) => TestResult(
  testId: id,
  runId: 'r1',
  status: status,
  startedAt: DateTime.utc(2026, 5),
  finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
);

TestSpec _seeded(int seed) => TestSpec(
  id: 'cdc/cdc_capture_sweep+seed=$seed',
  name: 'cdc_capture_sweep',
  suiteName: 'cdc',
  simulatorId: 'verilator',
  top: 'tb',
  seed: seed,
  parentSpecId: 'cdc/cdc_capture_sweep',
);

TestSpec _plain(String name) => TestSpec(
  id: 'cdc/$name',
  name: name,
  suiteName: 'cdc',
  simulatorId: 'verilator',
  top: 'tb',
);

final RegressionConfig _config = RegressionConfig(
  projectFilePath: '/proj/simcrux.yaml',
  schemaVersion: '1',
  suites: [
    Suite(
      name: 'cdc',
      tests: [_seeded(21), _seeded(22), _seeded(121), _plain('smoke')],
    ),
  ],
  simulatorBinaries: const {},
);

class _StoreNotifier extends ResultStoreNotifier {
  _StoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}

class _ConfigNotifier extends ActiveConfigNotifier {
  _ConfigNotifier(this._config);
  final RegressionConfig _config;

  @override
  RegressionConfig? build() => _config;
}

/// The debounce the filter bar's text field applies, unchanged.
final Duration _window = Debouncer().duration;

const String _seed21 = 'cdc_capture_sweep · seed 21';
const String _seed22 = 'cdc_capture_sweep · seed 22';
const String _seed121 = 'cdc_capture_sweep · seed 121';

Future<void> _pump(
  WidgetTester tester, {
  Widget results = const DashboardResultsTable(),
  bool withRun = true,
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final overrides = <Override>[
    activeConfigProvider.overrideWith(() => _ConfigNotifier(_config)),
  ];
  if (withRun) {
    final ids = <String>[
      'cdc/cdc_capture_sweep+seed=21',
      'cdc/cdc_capture_sweep+seed=22',
      'cdc/cdc_capture_sweep+seed=121',
      'cdc/smoke',
    ];
    final store = InMemoryResultStore.forRun(
      TestRun(id: 'r1', startedAt: DateTime.utc(2026, 5), testIds: ids),
    );
    for (final id in ids) {
      await store.recordResult(_result(id, TestStatus.pass));
    }
    overrides.add(
      resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
    );
  }
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
        home: Scaffold(
          body: Column(
            children: [
              const DashboardFilterBar(),
              Expanded(child: results),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(DashboardFilterBar)));

L10N _l10n(WidgetTester tester) =>
    L10N.of(tester.element(find.byType(DashboardFilterBar)));

/// Types [text] into the filter field and lets the debounce land.
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(_window);
  await tester.pumpAndSettle();
}

/// The results-table row showing [label]; the filter field's own text never
/// counts.
Finder _row(String label) => find.descendant(
  of: find.byType(DashboardResultsTable),
  matching: find.text(label),
);

/// The filter bar's own Clear filters button.
Finder _barClear(WidgetTester tester) => find.descendant(
  of: find.byType(DashboardFilterBar),
  matching: find.widgetWithText(TextButton, _l10n(tester).dashboardFilterClear),
);

/// The Clear filters button the empty table offers.
Finder _tableClear(WidgetTester tester) => find.descendant(
  of: find.byType(DashboardResultsTable),
  matching: find.widgetWithText(TextButton, _l10n(tester).dashboardFilterClear),
);

void main() {
  group('the test-name filter finds a run by the seed its row shows', () {
    testWidgets('"seed 21" finds the row labelled with seed 21', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester, 'seed 21');

      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed22), findsNothing);
      expect(_row(_seed121), findsNothing);
      expect(_row('smoke'), findsNothing);
    });

    testWidgets('"21" finds it too', (tester) async {
      await _pump(tester);
      await _type(tester, '21');

      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed121), findsOneWidget, reason: '121 contains 21');
      expect(_row(_seed22), findsNothing);
    });

    testWidgets('the whole displayed label finds it', (tester) async {
      await _pump(tester);
      await _type(tester, _seed21);

      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed22), findsNothing);
    });

    testWidgets('the id forms keep working: seed_21 and seed=21', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester, 'seed_21');
      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed22), findsNothing);

      await _type(tester, 'seed=21');
      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed22), findsNothing);
    });

    testWidgets('the test name alone still finds every seed of the sweep', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester, 'capture_sweep');

      expect(_row(_seed21), findsOneWidget);
      expect(_row(_seed22), findsOneWidget);
      expect(_row('smoke'), findsNothing);
    });
  });

  group('when the filters exclude every row', () {
    testWidgets('the table says nothing matches, not that there are no '
        'results', (tester) async {
      await _pump(tester);
      final l10n = _l10n(tester);
      await _type(tester, 'no_such_test');

      expect(find.text(l10n.dashboardEmpty), findsNothing);
      expect(find.text(l10n.dashboardNoMatches), findsOneWidget);
      expect(_tableClear(tester), findsOneWidget);
    });

    testWidgets('the table offers Clear filters, which brings the rows back', (
      tester,
    ) async {
      await _pump(tester);
      await _type(tester, 'no_such_test');

      await tester.tap(_tableClear(tester));
      await tester.pumpAndSettle();

      expect(_container(tester).read(dashboardFilterProvider).isUnset, isTrue);
      expect(_row(_seed21), findsOneWidget);
      expect(_row('smoke'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a status chip that excludes every row says the same', (
      tester,
    ) async {
      await _pump(tester);
      final l10n = _l10n(tester);
      await tester.tap(find.widgetWithText(FilterChip, l10n.testStatusFail));
      await tester.pumpAndSettle();

      expect(find.text(l10n.dashboardEmpty), findsNothing);
      expect(find.text(l10n.dashboardNoMatches), findsOneWidget);
    });

    testWidgets('the heatmap says the same', (tester) async {
      await _pump(tester, results: const DashboardHeatmapView());
      final l10n = _l10n(tester);
      await _type(tester, 'no_such_test');

      expect(find.text(l10n.dashboardEmpty), findsNothing);
      expect(find.text(l10n.dashboardNoMatches), findsOneWidget);
    });

    testWidgets('with no results at all the table still says so', (
      tester,
    ) async {
      await _pump(tester, withRun: false);
      final l10n = _l10n(tester);

      expect(find.text(l10n.dashboardEmpty), findsOneWidget);
      expect(find.text(l10n.dashboardNoMatches), findsNothing);

      // A filter set before any result arrives does not make "no results
      // yet" into "nothing matches".
      await _type(tester, 'smoke');
      expect(find.text(l10n.dashboardEmpty), findsOneWidget);
      expect(find.text(l10n.dashboardNoMatches), findsNothing);
    });

    testWidgets('every locale renders the message without exceptions', (
      tester,
    ) async {
      for (final locale in L10N.supportedLocales) {
        await _pump(tester, locale: locale);
        await _type(tester, 'no_such_test');
        expect(tester.takeException(), isNull, reason: '$locale');
        expect(
          find.text(_l10n(tester).dashboardNoMatches),
          findsOneWidget,
          reason: '$locale',
        );
      }
    });
  });

  group('Clear filters with only the text filter set', () {
    testWidgets('responds once the typed text has applied', (tester) async {
      await _pump(tester);
      await _type(tester, 'seed 21');
      expect(
        _container(tester).read(dashboardFilterProvider).testNameSubstring,
        'seed 21',
      );

      await tester.tap(_barClear(tester));
      await tester.pumpAndSettle();

      expect(_container(tester).read(dashboardFilterProvider).isUnset, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(_row('smoke'), findsOneWidget);
    });

    // The button used to follow the applied filter alone, so for the
    // debounce after a keystroke it was disabled and the click did nothing,
    // while the typed text applied a moment later.
    testWidgets('responds while the typed text is still waiting to apply', (
      tester,
    ) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'seed 21');
      await tester.pump();

      final clear = tester.widget<TextButton>(_barClear(tester));
      expect(clear.onPressed, isNotNull, reason: 'text typed, filter pending');

      await tester.tap(_barClear(tester));
      await tester.pump(_window * 2);

      expect(_container(tester).read(dashboardFilterProvider).isUnset, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('is disabled again once the field is emptied by hand', (
      tester,
    ) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'seed 21');
      await tester.pump(_window);
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(_window);
      await tester.pumpAndSettle();

      expect(tester.widget<TextButton>(_barClear(tester)).onPressed, isNull);
    });
  });
}
