// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_async/crux_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_filter_bar.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

TestSpec _spec({
  required String id,
  required String suiteName,
  required String name,
  String simulatorId = 'icarus',
}) {
  return TestSpec(
    id: id,
    name: name,
    suiteName: suiteName,
    simulatorId: simulatorId,
    top: 'tb',
  );
}

RegressionConfig _config() {
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(
        name: 'unit',
        tests: [
          _spec(id: 'unit/alu', suiteName: 'unit', name: 'alu'),
          _spec(
            id: 'unit/regfile',
            suiteName: 'unit',
            name: 'regfile',
            simulatorId: 'verilator',
          ),
        ],
      ),
      Suite(
        name: 'integration',
        tests: [
          _spec(id: 'integration/soc', suiteName: 'integration', name: 'soc'),
        ],
      ),
    ],
    simulatorBinaries: const {},
  );
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(body: DashboardFilterBar()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container({RegressionConfig? config}) {
  final container = ProviderContainer(
    overrides: [
      if (config != null)
        activeConfigProvider.overrideWith(
          () => _StubActiveConfigNotifier(config),
        ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

L10N _l10n(WidgetTester tester) =>
    L10N.of(tester.element(find.byType(DashboardFilterBar)));

/// The test-name field's debounce: the shared [Debouncer]'s default, which
/// the bar uses unchanged.
final Duration _window = Debouncer().duration;

void main() {
  group('DashboardFilterBar', () {
    testWidgets(
      'renders status chips only when no config is active; clear is disabled',
      (tester) async {
        final container = _container();
        await _pump(tester, container);
        final l10n = _l10n(tester);

        expect(find.text(l10n.dashboardFilterByStatus), findsOneWidget);
        expect(
          find.widgetWithText(FilterChip, l10n.testStatusPass),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(FilterChip, l10n.testStatusFail),
          findsOneWidget,
        );
        // No active config → no suite / simulator chip groups.
        expect(find.text(l10n.dashboardFilterBySuite), findsNothing);
        expect(find.text(l10n.dashboardFilterBySimulator), findsNothing);
        // Unset filter → the clear button is disabled.
        final clear = tester.widget<TextButton>(
          find
              .ancestor(
                of: find.text(l10n.dashboardFilterClear),
                matching: find.byType(TextButton),
              )
              .first,
        );
        expect(clear.onPressed, isNull);
      },
    );

    testWidgets('derives suite and simulator chips from the active config', (
      tester,
    ) async {
      final container = _container(config: _config());
      await _pump(tester, container);
      final l10n = _l10n(tester);

      expect(find.text(l10n.dashboardFilterBySuite), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'unit'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'integration'), findsOneWidget);
      expect(find.text(l10n.dashboardFilterBySimulator), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'icarus'), findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'verilator'), findsOneWidget);
    });

    testWidgets(
      'tapping a status chip toggles the filter and clear resets it',
      (
        tester,
      ) async {
        final container = _container();
        await _pump(tester, container);
        final l10n = _l10n(tester);

        final passChip = find.widgetWithText(FilterChip, l10n.testStatusPass);
        await tester.tap(passChip);
        await tester.pumpAndSettle();

        expect(
          container.read(dashboardFilterProvider).statuses,
          contains(TestStatus.pass),
        );
        expect(tester.widget<FilterChip>(passChip).selected, isTrue);

        // The filter is no longer unset, so clear is enabled; tapping it
        // resets the filter and deselects the chip.
        await tester.tap(
          find
              .ancestor(
                of: find.text(l10n.dashboardFilterClear),
                matching: find.byType(TextButton),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(container.read(dashboardFilterProvider).isUnset, isTrue);
        expect(tester.widget<FilterChip>(passChip).selected, isFalse);
      },
    );

    testWidgets('tapping a suite chip toggles the suite filter', (
      tester,
    ) async {
      final container = _container(config: _config());
      await _pump(tester, container);

      await tester.tap(find.widgetWithText(FilterChip, 'unit'));
      await tester.pumpAndSettle();
      expect(
        container.read(dashboardFilterProvider).suites,
        contains('unit'),
      );

      // Tapping again removes it.
      await tester.tap(find.widgetWithText(FilterChip, 'unit'));
      await tester.pumpAndSettle();
      expect(
        container.read(dashboardFilterProvider).suites,
        isNot(contains('unit')),
      );
    });

    testWidgets('typing in the search field updates the substring filter '
        'once typing settles', (tester) async {
      final container = _container();
      await _pump(tester, container);

      await tester.enterText(find.byType(TextField), 'alu');
      await tester.pump();
      expect(
        container.read(dashboardFilterProvider).testNameSubstring,
        isEmpty,
        reason: 'the field is debounced, so nothing applies at once',
      );
      await tester.pump(_window);
      expect(
        container.read(dashboardFilterProvider).testNameSubstring,
        'alu',
      );
    });

    // The doc always said debounced; the field called the setter on every
    // keystroke. MUTATION: calling `setTestNameSubstring` straight from
    // `onChanged` again records four updates here, not one.
    testWidgets('a burst of keystrokes is one filter update, with the last '
        'text typed', (tester) async {
      final container = _container();
      await _pump(tester, container);
      final updates = <String>[];
      container.listen<String>(
        dashboardFilterProvider.select((f) => f.testNameSubstring),
        (_, next) => updates.add(next),
      );

      final field = find.byType(TextField);
      for (final text in <String>['a', 'al', 'alu', 'alu_']) {
        await tester.enterText(field, text);
        // Each keystroke lands inside the window the previous one opened.
        await tester.pump(_window ~/ 2);
      }
      expect(updates, isEmpty, reason: 'still typing');

      await tester.pump(_window);
      expect(updates, <String>['alu_']);

      // A second burst, after the first settled, is a second update.
      await tester.enterText(field, 'alu_m');
      await tester.enterText(field, 'alu_mu');
      await tester.pump(_window);
      expect(updates, <String>['alu_', 'alu_mu']);
    });

    // A keystroke still waiting out the debounce would otherwise land after
    // Clear and put the text filter back. MUTATION: dropping the
    // `_nameDebouncer.cancel()` from Clear makes this red.
    testWidgets('clear drops a keystroke still waiting to apply', (
      tester,
    ) async {
      final container = _container();
      await _pump(tester, container);
      final l10n = _l10n(tester);

      // A status chip, so Clear is enabled before the text applies.
      await tester.tap(find.widgetWithText(FilterChip, l10n.testStatusFail));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'soc');
      await tester.pump();
      await tester.tap(
        find
            .ancestor(
              of: find.text(l10n.dashboardFilterClear),
              matching: find.byType(TextButton),
            )
            .first,
      );
      await tester.pump(_window * 2);
      expect(container.read(dashboardFilterProvider).isUnset, isTrue);
    });

    testWidgets('a keystroke pending when the bar goes away never applies', (
      tester,
    ) async {
      final container = _container();
      await _pump(tester, container);

      await tester.enterText(find.byType(TextField), 'soc');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const SizedBox.shrink(),
        ),
      );
      await tester.pump(_window * 2);
      expect(container.read(dashboardFilterProvider).testNameSubstring, '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        final container = _container(config: _config());
        await _pump(tester, container, locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

class _StubActiveConfigNotifier extends ActiveConfigNotifier {
  _StubActiveConfigNotifier(this._config);
  final RegressionConfig _config;

  @override
  RegressionConfig? build() => _config;
}
