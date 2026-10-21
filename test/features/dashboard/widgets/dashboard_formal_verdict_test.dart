// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/core/theme/simcrux_colors.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_column_layout_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

// The four-bucket Verdict column in the open-core results table, rendered at
// Open Core with the beta period off and no Pro overrides: every formal
// verdict is visible, worded for what it may claim, spoken in the row's
// label, and an Inconclusive row is never painted error red.

final Map<String, (TestStatus, Map<String, String>)> _rows = {
  'proofs/bmc_pass': (
    TestStatus.pass,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'PASS',
      'formal.mode': 'bmc',
      'formal.depth_configured': '20',
    },
  ),
  'proofs/prove_pass': (
    TestStatus.pass,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'PASS',
      'formal.mode': 'prove',
      'formal.properties': '2',
    },
  ),
  'proofs/vacuous': (
    TestStatus.pass,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'PASS',
      'formal.mode': 'prove',
      'formal.properties': '0',
    },
  ),
  'proofs/undecided': (
    TestStatus.fail,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'UNKNOWN',
      'formal.mode': 'prove',
    },
  ),
  'proofs/tooling': (
    TestStatus.fail,
    const {'formal.tool': 'sby', 'formal.verdict': 'ERROR'},
  ),
  'riscv/insn_add_ch0': (
    TestStatus.fail,
    const {
      'riscv.formal.verdict': 'FAIL',
      'formal.tool': 'sby',
      'formal.verdict': 'FAIL',
      'formal.mode': 'bmc',
    },
  ),
  'proofs/temporal': (
    TestStatus.fail,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'ERROR',
      'formal.frontend': 'slang',
      'formal.not_run_reason': 'sva_unsupported',
      'formal.sva.class': 'implication',
      'formal.sva.construct': '|=>',
      'formal.sva.location': 'rtl/handshake.sv:42',
    },
  ),
  'proofs/drain': (
    TestStatus.pass,
    const {
      'formal.tool': 'sby',
      'formal.verdict': 'PASS',
      'formal.mode': 'cover',
      'formal.properties': '2',
      'formal.pretrace.kind': 'cover',
      'formal.pretrace.depth': '4',
      'formal.pretrace.step': '2',
      'formal.pretrace.location': 'rtl/fifo.sv:47',
    },
  ),
  'unit/alu': (TestStatus.pass, const <String, String>{}),
};

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pumpTable(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.binding.setSurfaceSize(const Size(1600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final run = TestRun(
      id: 'r1',
      startedAt: DateTime.utc(2026, 10),
      testIds: _rows.keys.toList(),
    );
    final store = InMemoryResultStore.forRun(run);
    for (final MapEntry(key: id, value: (status, metrics)) in _rows.entries) {
      await store.recordResult(
        TestResult(
          testId: id,
          runId: 'r1',
          status: status,
          startedAt: DateTime.utc(2026, 10),
          finishedAt: DateTime.utc(2026, 10, 1, 0, 0, 1),
          metrics: metrics,
        ),
      );
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // The tier law: Open Core, beta off, no Pro overrides.
          betaPeriodProvider.overrideWithValue(false),
          licenseTierProvider.overrideWith((_) => LicenseTier.openCore),
          resultStoreProvider.overrideWith(
            () => _ImmediateResultStoreNotifier(store),
          ),
          dashboardColumnLayoutSettingsServiceProvider.overrideWithValue(
            SettingsService<DashboardColumnLayout>(
              dashboardColumnLayoutProviders.codec,
              prefsOverride: prefs,
            ),
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
          home: const Scaffold(body: DashboardResultsTable()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(
      tester.element(find.byType(DashboardResultsTable)),
    );
  }

  L10N l10nOf(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(DashboardResultsTable)));

  testWidgets('every formal verdict renders at Open Core, worded for what it '
      'may claim', (tester) async {
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.dashboardColumnVerdict), findsOneWidget);
    expect(find.text(l10n.formalVerdictProvedOverSteps(20)), findsOneWidget);
    expect(find.text(l10n.formalVerdictProved), findsOneWidget);
    expect(find.text(l10n.formalVerdictNoPropertiesChecked), findsOneWidget);
    expect(find.text(l10n.formalVerdictInconclusive), findsOneWidget);
    expect(find.text(l10n.formalVerdictDidNotRun), findsOneWidget);
    expect(find.text(l10n.formalVerdictCounterexample), findsOneWidget);
    expect(
      find.text('Proved'),
      findsOneWidget,
      reason: 'the bounded row never says a bare "Proved"',
    );
  });

  testWidgets('the verdict is in the row label, not only in colour', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    final undecided = tester.widget<Checkbox>(
      find.byWidgetPredicate(
        (w) => w is Checkbox && (w.semanticLabel ?? '').contains('undecided'),
      ),
    );
    expect(
      undecided.semanticLabel,
      startsWith('${l10n.formalVerdictInconclusive}:'),
    );
    final simulation = tester.widget<Checkbox>(
      find.byWidgetPredicate(
        (w) => w is Checkbox && (w.semanticLabel ?? '').contains('alu'),
      ),
    );
    expect(simulation.semanticLabel, startsWith('${l10n.testStatusPass}:'));
    handle.dispose();
  });

  testWidgets('the SVA diagnostic and the pre-trace marker render at Open '
      'Core, in words as well as a glyph', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    expect(find.text(l10n.formalVerdictDidNotRunSva), findsOneWidget);
    expect(find.byKey(const ValueKey('formalPretraceMarker')), findsOneWidget);
    final drain = tester.widget<Checkbox>(
      find.byWidgetPredicate(
        (w) => w is Checkbox && (w.semanticLabel ?? '').contains('drain'),
      ),
    );
    expect(
      drain.semanticLabel,
      startsWith(
        '${l10n.formalVerdictWithPretrace(l10n.formalVerdictReached)}:',
      ),
    );
    final temporal = tester.widget<Checkbox>(
      find.byWidgetPredicate(
        (w) => w is Checkbox && (w.semanticLabel ?? '').contains('temporal'),
      ),
    );
    expect(
      temporal.semanticLabel,
      startsWith('${l10n.formalVerdictDidNotRunSva}:'),
    );
    handle.dispose();
  });

  testWidgets('an Inconclusive row is never error red, in the glyph or the '
      'text', (tester) async {
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    final scheme = Theme.of(
      tester.element(find.byType(DashboardResultsTable)),
    ).colorScheme;
    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) =>
              w is DashboardStatusIcon && w.formal?.verdictToken == 'UNKNOWN',
        ),
        matching: find.byType(Icon),
      ),
    );
    expect(icon.color, scheme.onSurfaceVariant);
    expect(icon.color, isNot(SimcruxColors.statusFail));
    final text = tester.widget<Text>(
      find.text(l10n.formalVerdictInconclusive),
    );
    expect(text.style?.color, scheme.onSurfaceVariant);
    expect(text.style?.color, isNot(scheme.error));
  });

  testWidgets('sorting by Verdict puts the most urgent first and simulation '
      'rows last', (tester) async {
    final container = await pumpTable(tester);
    container
        .read(dashboardSortProvider.notifier)
        .toggleColumn(DashboardSortColumn.verdict);
    await tester.pumpAndSettle();
    final rows = container.read(dashboardRowsProvider).value!;
    expect(rows.first.testId, 'riscv/insn_add_ch0');
    expect(rows.last.testId, 'unit/alu');
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: the column renders without '
        'overflow', (tester) async {
      await pumpTable(tester, locale: locale);
      expect(tester.takeException(), isNull);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.formalVerdictInconclusive), findsOneWidget);
    });
  }
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
