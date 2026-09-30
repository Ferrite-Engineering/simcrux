// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_storage_stats.dart';
import 'package:simcrux/features/diagnostics/widgets/app_diagnostics_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

/// Minimal [TrendStore] whose only interesting answer is a canned
/// [TrendStorageStats] snapshot — the dialog's Trend store section is
/// the unit under test, not the store.
class _StatsOnlyTrendStore extends TrendStore {
  _StatsOnlyTrendStore(this._stats);
  final TrendStorageStats _stats;

  @override
  Future<void> recordTrendPoint(TrendPoint point) async {}

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) =>
      const Stream<TrendPoint>.empty();

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) =>
      const Stream<TrendDelta>.empty();

  @override
  Future<TrendStorageStats> storageStats() async => _stats;
}

Future<void> _pump(
  WidgetTester tester, {
  required TrendStorageStats stats,
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        trendStoreProvider.overrideWith(
          (_) async => _StatsOnlyTrendStore(stats),
        ),
      ],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(body: AppDiagnosticsDialog()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('AppDiagnosticsDialog — Trend store section', () {
    testWidgets('renders the storage summary for a populated store', (
      tester,
    ) async {
      await _pump(
        tester,
        stats: TrendStorageStats(
          dataPointCount: 1234,
          runCount: 17,
          oldestPointAt: DateTime.utc(2026),
          newestPointAt: DateTime.utc(2026, 7),
          approximateBytes: 2 * 1024 * 1024,
        ),
      );
      final l10n = L10N.of(
        tester.element(find.byType(AppDiagnosticsDialog)),
      );
      expect(
        find.textContaining(l10n.diagnosticsTrendStoreSection),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          l10n.diagnosticsTrendStoreSummary(1234, 17, '2.0 MB'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders the size-unknown label when bytes are null', (
      tester,
    ) async {
      await _pump(
        tester,
        stats: const TrendStorageStats(dataPointCount: 5, runCount: 1),
      );
      final l10n = L10N.of(
        tester.element(find.byType(AppDiagnosticsDialog)),
      );
      expect(
        find.textContaining(
          l10n.diagnosticsTrendStoreSummary(
            5,
            1,
            l10n.diagnosticsTrendStoreSizeUnknown,
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders the empty label for a fresh store', (tester) async {
      await _pump(tester, stats: TrendStorageStats.empty);
      final l10n = L10N.of(
        tester.element(find.byType(AppDiagnosticsDialog)),
      );
      expect(
        find.textContaining(l10n.diagnosticsTrendStoreEmpty),
        findsOneWidget,
      );
    });

    testWidgets('renders the suite-converged chrome: title, copy, close ×', (
      tester,
    ) async {
      await _pump(tester, stats: TrendStorageStats.empty);
      final l10n = L10N.of(
        tester.element(find.byType(AppDiagnosticsDialog)),
      );
      expect(find.text(l10n.diagnosticsAppDialogTitle), findsOneWidget);
      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    // Locale sweep: the section must render its localized strings
    // without throwing in every supported locale.
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without exceptions in $locale', (tester) async {
        await _pump(
          tester,
          stats: const TrendStorageStats(
            dataPointCount: 10,
            runCount: 2,
            approximateBytes: 4096,
          ),
          locale: locale,
        );
        final l10n = L10N.of(
          tester.element(find.byType(AppDiagnosticsDialog)),
        );
        expect(
          find.textContaining(l10n.diagnosticsTrendStoreSection),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
