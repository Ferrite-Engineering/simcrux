// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a keyboard and screen-reader user meets in the inspector for an EQY
// row: how many partitions were proved equivalent, then each partition with
// its own result, the ones that need attention first, a counterexample with
// its trace file. Every line is a named Tab stop, rendered at Open Core (every
// partition is free).
//
// The transcript under `goldens/` is what the focus walk records, in text
// and independent of the renderer. Rewrite it with
// `flutter test --update-goldens test/accessibility/eqy_partitions_focus_walk_test.dart`
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

/// alu_pass as the eqy driver records it: a correct netlist EQY FAILs at
/// its default configuration, z not proved, y and r proved.
const Map<String, String> _partial = {
  'formal.tool': 'eqy',
  'formal.verdict': 'FAIL',
  'formal.mode': 'equiv',
  'formal.properties': '4',
  'formal.properties_failed': '1',
  'formal.properties_undecided': '1',
  'formal.property.0.kind': 'partition',
  'formal.property.0.label': 'alu.z',
  'formal.property.0.status': 'counterexample',
  'formal.property.0.trace': 'strategies/alu.z/sby/alu.z/engine_0/trace.vcd',
  'formal.property.1.kind': 'partition',
  'formal.property.1.label': 'alu.y',
  'formal.property.1.status': 'proved',
  'formal.property.2.kind': 'partition',
  'formal.property.2.label': 'alu.r',
  'formal.property.2.status': 'proved',
  'formal.property.3.kind': 'partition',
  'formal.property.3.label': 'alu.q',
  'formal.property.3.status': 'inconclusive',
};

SelectedTest _selection(Map<String, String> metrics, TestStatus status) =>
    SelectedTest(
      row: DashboardRow(
        result: TestResult(
          testId: 'equiv/alu_pass',
          runId: 'r',
          status: status,
          startedAt: DateTime.utc(2026, 10),
          finishedAt: DateTime.utc(2026, 10),
          metrics: metrics,
        ),
        suiteName: 'equiv',
        simulatorId: 'eqy',
        testName: 'alu_pass',
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
    'the partitions: the count first, then each, the unproved ones first',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _selection(_partial, TestStatus.fail));
      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'Inspector, EQY partitions');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/eqy_partitions.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('which partitions were proved is said, and none is called '
      'verified', (tester) async {
    await _pump(tester, _selection(_partial, TestStatus.fail));
    final l10n = L10N.of(tester.element(find.byType(InspectorFormalNotes)));
    final lines = formalNoteLines(
      l10n,
      FormalResultSummary.fromMetrics(_partial)!,
      partitions: FormalResultSummary.partitionsOf(_partial),
    );
    expect(lines.map((l) => l.text), [
      l10n.formalEqyPartitionsHeading(2, 4),
      l10n.formalEqyPartitionCounterexample(
        'alu.z',
        'strategies/alu.z/sby/alu.z/engine_0/trace.vcd',
      ),
      l10n.formalEqyPartitionUndecided('alu.q'),
      l10n.formalEqyPartitionProved('alu.y'),
      l10n.formalEqyPartitionProved('alu.r'),
    ]);
    for (final line in lines) {
      expect(line.text.toLowerCase(), isNot(contains('verified')));
      expect(line.text, isNot(contains('—')), reason: 'no em dashes');
    }
  });

  testWidgets('a long list is cut, and says how many it left out', (
    tester,
  ) async {
    final many = <String, String>{
      'formal.tool': 'eqy',
      'formal.verdict': 'PASS',
      'formal.properties': '30',
      for (var n = 0; n < 30; n++) ...{
        'formal.property.$n.kind': 'partition',
        'formal.property.$n.label': 'm.p$n',
        'formal.property.$n.status': 'proved',
      },
    };
    await _pump(tester, _selection(many, TestStatus.pass));
    final l10n = L10N.of(tester.element(find.byType(InspectorFormalNotes)));
    final lines = formalNoteLines(
      l10n,
      FormalResultSummary.fromMetrics(many)!,
      partitions: FormalResultSummary.partitionsOf(many),
    );
    expect(lines, hasLength(kInspectorMaxPartitionLines + 2));
    expect(
      lines.last.text,
      l10n.formalEqyPartitionsMore(30 - kInspectorMaxPartitionLines),
    );
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: the partitions render', (
      tester,
    ) async {
      await _pump(
        tester,
        _selection(_partial, TestStatus.fail),
        locale: locale,
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('alu.z'), findsOneWidget);
    });
  }
}
