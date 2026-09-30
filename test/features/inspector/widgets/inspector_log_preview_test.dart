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
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/log_preview_settings_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_log_preview.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

const String _kTestId = 'smoke/pass_basic';

SelectedTest _selection() {
  final result = TestResult(
    testId: _kTestId,
    runId: 'r1',
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    exitCode: 0,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Pin the tail-line count so the widget never watches the
        // async app-settings provider in tests.
        logPreviewLineCountProvider.overrideWithValue(50),
        ...overrides,
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
        home: Scaffold(body: InspectorLogPreview(selection: _selection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('InspectorLogPreview', () {
    testWidgets('renders the localized empty state with no buffered log', (
      tester,
    ) async {
      // Default result store is null → empty snapshot.
      await _pump(tester);
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorSectionLog), findsOneWidget);
      expect(find.text(l10n.inspectorLogPreviewEmpty), findsOneWidget);
    });

    testWidgets(
      'renders buffered lines, the line-count caption and severity color',
      (tester) async {
        final store = InMemoryResultStore.forRun(
          TestRun(
            id: 'r1',
            startedAt: DateTime.utc(2026, 5),
            testIds: const [_kTestId],
          ),
        );
        // Append before the widget subscribes so the snapshot is
        // populated at first build and no coalescing timer is armed.
        store.logBufferStore.bufferFor(_kTestId)
          ..append(line: 'hello world', fromStderr: false)
          ..append(line: 'ERROR: bad value', fromStderr: true);

        await _pump(
          tester,
          overrides: [
            resultStoreProvider.overrideWith(
              () => _StubResultStoreNotifier(store),
            ),
          ],
        );
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(Scaffold));
        final l10n = L10N.of(context);
        expect(find.text('hello world'), findsOneWidget);
        expect(find.text('ERROR: bad value'), findsOneWidget);
        expect(
          find.text(l10n.inspectorLogPreviewLineCount(2)),
          findsOneWidget,
        );
        expect(find.text(l10n.inspectorLogPreviewEmpty), findsNothing);
        // Severity heuristics color error-looking lines.
        final errorLine = tester.widget<Text>(find.text('ERROR: bad value'));
        expect(errorLine.style?.color, Theme.of(context).colorScheme.error);
      },
    );

    testWidgets('renders the dropped-lines caption when lines were elided', (
      tester,
    ) async {
      const args = InspectorLogArgs(testId: _kTestId, tailLineCount: 50);
      await _pump(
        tester,
        overrides: [
          inspectorLogSnapshotProvider(args).overrideWith(
            (_) => InspectorLogSnapshot(
              tailLines: const [
                LogLine(line: 'tail line', fromStderr: false),
              ],
              totalLineCount: 1,
              droppedCount: 3,
            ),
          ),
        ],
      );
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text('tail line'), findsOneWidget);
      expect(find.text(l10n.inspectorLogPreviewDropped(3)), findsOneWidget);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(tester, locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

/// Test-only [ResultStoreNotifier] that materializes with a
/// hand-built store.
class _StubResultStoreNotifier extends ResultStoreNotifier {
  _StubResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
