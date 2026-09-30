// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/web/web_dashboard_screen.dart';
import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_results_loader.dart';
import 'package:simcrux/web/web_results_provider.dart';

/// In-memory loader returning a fixed document.
class _StaticWebResultsLoader extends WebResultsLoader {
  const _StaticWebResultsLoader(this.document);

  final WebResultsDocument document;

  @override
  Future<WebResultsDocument> load({String? resultsUrl}) async => document;
}

WebResultsDocument _fixtureDoc() {
  return WebResultsDocument(
    runId: 'run-1',
    startedAt: DateTime.utc(2026),
    finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 5),
    rows: const [
      WebResultRow(
        testId: 'axi/burst',
        testName: 'burst',
        suiteName: 'axi',
        simulatorId: 'icarus',
        status: TestStatus.pass,
        runtime: Duration(milliseconds: 1500),
      ),
      WebResultRow(
        testId: 'axi/wrap',
        testName: 'wrap',
        suiteName: 'axi',
        simulatorId: 'icarus',
        status: TestStatus.fail,
        runtime: Duration(milliseconds: 2300),
        failureMessage: 'expected 0x42, got 0x41',
      ),
    ],
    totals: const {TestStatus.pass: 1, TestStatus.fail: 1},
  );
}

Widget _harness({Locale? locale, WebResultsDocument? doc}) {
  return ProviderScope(
    overrides: [
      webResultsLoaderProvider.overrideWithValue(
        _StaticWebResultsLoader(doc ?? _fixtureDoc()),
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
      home: const WebDashboardScreen(),
    ),
  );
}

void main() {
  group('WebDashboardScreen', () {
    testWidgets('renders rows from the loaded document', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      expect(find.text('axi/burst'), findsOneWidget);
      expect(find.text('axi/wrap'), findsOneWidget);
      expect(find.text('PASS'), findsOneWidget);
      expect(find.text('FAIL'), findsOneWidget);
    });

    testWidgets('filter text field narrows the visible rows', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      expect(find.text('axi/burst'), findsOneWidget);
      expect(find.text('axi/wrap'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'burst');
      await tester.pumpAndSettle();
      expect(find.text('axi/burst'), findsOneWidget);
      expect(find.text('axi/wrap'), findsNothing);
    });

    testWidgets('renders empty state when zero rows', (tester) async {
      await tester.pumpWidget(
        _harness(
          doc: WebResultsDocument(
            runId: 'r',
            startedAt: DateTime.utc(2026),
            finishedAt: null,
            rows: const [],
            totals: const {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
    });

    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('locale sweep — ${locale.toLanguageTag()}', (tester) async {
        await tester.pumpWidget(_harness(locale: locale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('WebDashboardScreen — Open results file', () {
    testWidgets('exposes an "Open results file…" affordance', (tester) async {
      await tester.pumpWidget(_harness());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.upload_file), findsOneWidget);
      final l10n = await L10N.delegate.load(const Locale('en'));
      expect(find.text(l10n.webDashboardOpenFileButton), findsOneWidget);
    });

    testWidgets(
      'a user-opened document takes precedence over the fetched results',
      (tester) async {
        await tester.pumpWidget(_harness());
        await tester.pumpAndSettle();
        // The auto-fetched fixture is showing to begin with.
        expect(find.text('axi/burst'), findsOneWidget);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(WebDashboardScreen)),
        );
        container
            .read(webOpenedDocumentProvider.notifier)
            .set(
              WebResultsDocument(
                runId: 'opened',
                startedAt: DateTime.utc(2026),
                finishedAt: null,
                rows: const [
                  WebResultRow(
                    testId: 'opened/row',
                    testName: 'row',
                    suiteName: 'opened',
                    simulatorId: 'demo',
                    status: TestStatus.pass,
                    runtime: Duration(milliseconds: 7),
                  ),
                ],
                totals: const {TestStatus.pass: 1},
              ),
            );
        await tester.pumpAndSettle();

        // The opened document replaces the fetched one.
        expect(find.text('opened/row'), findsOneWidget);
        expect(find.text('axi/burst'), findsNothing);
      },
    );

    testWidgets(
      'a decoded NDJSON document feeds the viewer (the file-open path)',
      (tester) async {
        await tester.pumpWidget(_harness());
        await tester.pumpAndSettle();

        // The exact call openWebResultsFile makes once it has the file
        // bytes: decode (auto-detecting NDJSON) then publish.
        const ndjson =
            '{"type":"meta","run_id":"r2","started_at":"2026-01-01T00:00:00Z"}\n'
            '{"type":"result","id":"cpu/fetch","name":"fetch","suite":"cpu",'
            '"simulator":"demo","status":"pass","runtime_ms":12}\n'
            '{"type":"summary","finished_at":"2026-01-01T00:00:01Z",'
            '"totals":{"pass":1}}\n';
        final doc = WebResultsDocument.decode(ndjson);
        expect(doc.rows.single.testId, 'cpu/fetch');

        ProviderScope.containerOf(
          tester.element(find.byType(WebDashboardScreen)),
        ).read(webOpenedDocumentProvider.notifier).set(doc);
        await tester.pumpAndSettle();

        expect(find.text('cpu/fetch'), findsOneWidget);
      },
    );
  });
}
