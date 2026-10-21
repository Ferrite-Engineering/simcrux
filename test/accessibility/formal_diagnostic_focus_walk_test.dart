// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a keyboard and screen-reader user meets in the inspector's Formal
// result section: for a row the frontend refused, the refused construct and
// its location first, then why, then what can be done; for a row whose
// result depends on state before the trace began, the marker and its
// one-line explanation. Every line is a named Tab stop, rendered at Open
// Core (the diagnostic and the marker are free).
//
// The transcripts under `goldens/` are what the focus walk records, in text
// and independent of the renderer. Rewrite them with
// `flutter test --update-goldens test/accessibility/formal_diagnostic_focus_walk_test.dart`
// and read the diff before committing.

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/formal_result_summary.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_formal_notes.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

const Map<String, String> _refused = {
  'formal.tool': 'sby',
  'formal.verdict': 'ERROR',
  'formal.frontend': 'slang',
  'formal.not_run_reason': 'sva_unsupported',
  'formal.sva.class': 'implication',
  'formal.sva.construct': '|=>',
  'formal.sva.location': 'rtl/handshake.sv:42',
};

const Map<String, String> _pretrace = {
  'formal.tool': 'sby',
  'formal.verdict': 'PASS',
  'formal.mode': 'cover',
  'formal.properties': '2',
  'formal.pretrace.kind': 'cover',
  'formal.pretrace.depth': '4',
  'formal.pretrace.step': '2',
  'formal.pretrace.location': 'rtl/fifo.sv:47',
};

SelectedTest _selection(Map<String, String> metrics, TestStatus status) =>
    SelectedTest(
      row: DashboardRow(
        result: TestResult(
          testId: 'proofs/t',
          runId: 'r',
          status: status,
          startedAt: DateTime.utc(2026, 10),
          finishedAt: DateTime.utc(2026, 10),
          metrics: metrics,
        ),
        suiteName: 'proofs',
        simulatorId: 'sby',
        testName: 't',
      ),
    );

Future<void> _pump(
  WidgetTester tester,
  SelectedTest selection, {
  Locale locale = const Locale('en'),
}) async {
  tester.view
    ..physicalSize = const Size(900, 1200)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        L10N.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: InspectorFormalNotes(selection: selection),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  SemanticsOrphanTestBinding.ensureInitialized();

  testWidgets(
    'the SVA diagnostic: construct and location first, then why, then advice',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _selection(_refused, TestStatus.fail));
      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'Inspector, unsupported SVA');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/formal_sva_diagnostic.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the pre-trace marker and its explanation',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _selection(_pretrace, TestStatus.pass));
      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'Inspector, pre-trace marker');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/formal_pretrace_marker.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('the explanation never says passed and never hides', (
    tester,
  ) async {
    await _pump(tester, _selection(_refused, TestStatus.fail));
    final l10n = L10N.of(tester.element(find.byType(InspectorFormalNotes)));
    final lines = formalNoteLines(
      l10n,
      FormalResultSummary.fromMetrics(_refused)!,
    );
    expect(
      lines.first.text,
      l10n.formalSvaConstructAt(
        '|=>',
        'rtl/handshake.sv:42',
        l10n.formalSvaClassImplication,
      ),
      reason: 'the fact before the advice',
    );
    expect(lines.last.text, l10n.formalSvaAdvice);
    for (final line in lines) {
      expect(line.text.toLowerCase(), isNot(contains('passed')));
      expect(line.text, isNot(contains('—')), reason: 'no em dashes');
    }
  });

  testWidgets('a row with nothing to explain draws nothing', (tester) async {
    await _pump(
      tester,
      _selection(const {
        'formal.tool': 'sby',
        'formal.verdict': 'PASS',
        'formal.mode': 'prove',
      }, TestStatus.pass),
    );
    expect(find.byKey(const ValueKey('inspectorFormalNotes')), findsNothing);
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: both notes render', (tester) async {
      await _pump(
        tester,
        _selection(_refused, TestStatus.fail),
        locale: locale,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('inspectorFormalNotes')),
        findsOneWidget,
      );
      await _pump(
        tester,
        _selection(_pretrace, TestStatus.pass),
        locale: locale,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
