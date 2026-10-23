// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_column_layout_provider.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_results_table.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/features/flow/gls_labels.dart';
import 'package:simcrux/features/inspector/widgets/inspector_gls_notes.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

// Gate-level rows in the open-core results table, rendered at Open Core with
// the beta period off and no Pro overrides: the outcome and both counts are
// in the Verdict cell and in the row's spoken name, "X-asymmetry only" is a
// neutral note, "Differs" on a completed run is a finding and never error
// red, and a test that did not run says why.

Map<String, String> _metrics(
  String outcome, {
  int? real,
  int? x,
  String? reason,
  Map<String, String> extra = const <String, String>{},
}) => <String, String>{
  GlsMetricKeys.outcome: outcome,
  GlsMetricKeys.netlist: 'nl',
  GlsMetricKeys.delays: 'functional',
  GlsMetricKeys.simulator: 'icarus',
  GlsMetricKeys.target: 'sky130',
  GlsMetricKeys.pdk: 'sky130A',
  GlsMetricKeys.strictX: 'false',
  GlsMetricKeys.bannered: 'false',
  GlsMetricKeys.versionDiffers: 'false',
  GlsMetricKeys.rtlTest: 'cpu/alu',
  GlsMetricKeys.clock: 'clk',
  if (real != null) GlsMetricKeys.realDiffs: '$real',
  if (x != null) GlsMetricKeys.xDiffs: '$x',
  GlsMetricKeys.reason: ?reason,
  ...extra,
};

final Map<String, (TestStatus, Map<String, String>)> _rows = {
  'gls/cpu/equal': (TestStatus.pass, _metrics('equal', real: 0, x: 0)),
  'gls/cpu/xonly': (
    TestStatus.pass,
    _metrics(
      'x_only',
      real: 0,
      x: 12,
      extra: {GlsMetricKeys.firstDiffPs: '4000'},
    ),
  ),
  'gls/cpu/differs': (
    TestStatus.fail,
    _metrics(
      'differs',
      real: 3,
      x: 12,
      extra: {GlsMetricKeys.firstDiffPs: '90'},
    ),
  ),
  'gls/cpu/one': (TestStatus.fail, _metrics('differs', real: 1, x: 1)),
  'gls/cpu/notrun': (
    TestStatus.fail,
    _metrics('not_run', reason: 'port_shape'),
  ),
  'unit/alu': (TestStatus.pass, const <String, String>{}),
};

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    prefs = await SharedPreferences.getInstance();
  });

  Future<void> pumpTable(
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
          resultStoreProvider.overrideWith(() => _StoreNotifier(store)),
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
  }

  L10N l10nOf(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(DashboardResultsTable)));

  testWidgets('every outcome renders at Open Core with both counts, and a '
      'test that did not run renders its outcome alone', (tester) async {
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    expect(
      find.text(
        '${l10n.glsOutcomeEqual}: ${l10n.glsRealDifferences(0)}, '
        '${l10n.glsXAsymmetries(0)}',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '${l10n.glsOutcomeXOnly}: ${l10n.glsRealDifferences(0)}, '
        '${l10n.glsXAsymmetries(12)}',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '${l10n.glsOutcomeDiffers}: ${l10n.glsRealDifferences(3)}, '
        '${l10n.glsXAsymmetries(12)}',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Differs: 1 real difference, 1 X-asymmetry'),
      findsOneWidget,
    );
    expect(find.text(l10n.glsOutcomeNotRun), findsOneWidget);
  });

  testWidgets('the outcome, both counts and "gate level" are in the row '
      'name, not only in colour', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    String? label(String test) => tester
        .widgetList<Checkbox>(find.byType(Checkbox))
        .map((c) => c.semanticLabel)
        .whereType<String>()
        .firstWhere((s) => s.contains(test));
    expect(
      label('differs'),
      'Test cpu/differs, gate level, Differs, 3 real differences, '
      '12 X-asymmetries',
    );
    expect(
      label('notrun'),
      l10n.glsRowSpokenNotRun('cpu/notrun', l10n.glsReasonPortShape),
    );
    expect(label('xonly'), contains(l10n.glsOutcomeXOnly));
    handle.dispose();
  });

  testWidgets('"Differs" is a finding, never error red; "X-asymmetry only" '
      'is neutral', (tester) async {
    await pumpTable(tester);
    final scheme = Theme.of(
      tester.element(find.byType(DashboardResultsTable)),
    ).colorScheme;
    Icon iconOf(String outcome) => tester.widget<Icon>(
      find.descendant(
        of: find.byWidgetPredicate(
          (w) => w is DashboardStatusIcon && w.gls?.outcome.wireName == outcome,
        ),
        matching: find.byType(Icon),
      ),
    );
    expect(iconOf('x_only').color, scheme.onSurfaceVariant);
    expect(iconOf('x_only').icon, GlsLabels.icon(GlsOutcome.xOnly));
    expect(iconOf('not_run').color, scheme.onSurfaceVariant);
    expect(iconOf('equal').icon, GlsLabels.icon(GlsOutcome.equal));
    final differs = tester
        .widgetList<DashboardStatusIcon>(find.byType(DashboardStatusIcon))
        .where((w) => w.gls?.outcome == GlsOutcome.differs)
        .toList();
    expect(differs, hasLength(2));
    for (final w in differs) {
      final icon = tester.widget<Icon>(
        find.descendant(
          of: find.byWidget(w),
          matching: find.byType(Icon),
        ),
      );
      expect(icon.color, scheme.tertiary);
      expect(icon.color, isNot(scheme.error));
      expect(icon.icon, isNot(Icons.cancel));
    }
    // The outcome words are distinct shapes: the glyphs differ per outcome.
    final shapes = {
      for (final o in GlsOutcome.values) GlsLabels.icon(o).codePoint,
    };
    expect(shapes, hasLength(GlsOutcome.values.length));
  });

  testWidgets('the X-asymmetry tooltip says what X-asymmetry is', (
    tester,
  ) async {
    await pumpTable(tester);
    final l10n = l10nOf(tester);
    final cell = tester.widget<Text>(
      find.textContaining('${l10n.glsOutcomeXOnly}: '),
    );
    expect(cell.data, contains(l10n.glsXAsymmetries(12)));
    expect(
      l10n.glsOutcomeXOnlyTooltip,
      'The RTL was X where the gates resolved to 0 or 1.',
    );
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: the rows render without '
        'overflow', (tester) async {
      await pumpTable(tester, locale: locale);
      expect(tester.takeException(), isNull);
      final l10n = l10nOf(tester);
      expect(find.text(l10n.glsOutcomeNotRun), findsOneWidget);
    });
  }

  group('the inspector notes', () {
    L10N en() => lookupL10N(const Locale('en'));

    GlsResultView view(Map<String, String> metrics, {TestStatus? status}) =>
        GlsResultView.of(
          TestResult(
            testId: 'gls/cpu/alu',
            runId: 'r',
            status: status ?? TestStatus.pass,
            startedAt: DateTime.utc(2026),
            finishedAt: DateTime.utc(2026),
            metrics: metrics,
          ),
        )!;

    test('fact first: the outcome and both counts, then the note on X, '
        'then how it was simulated', () {
      final lines = glsNoteLines(
        en(),
        view(
          _metrics(
            'x_only',
            real: 0,
            x: 12,
            extra: {GlsMetricKeys.firstDiffPs: '4000'},
          ),
        ),
      ).map((l) => l.text).toList();
      expect(
        lines.first,
        'X-asymmetry only: 0 real differences, 12 X-asymmetries',
      );
      expect(lines[1], 'The RTL was X where the gates resolved to 0 or 1.');
      expect(lines, contains('Reruns the test cpu/alu.'));
      expect(lines, contains('Netlist: final/nl, without power pins.'));
      expect(
        lines,
        contains(
          'Functional simulation: every gate has a unit delay and there are '
          'no timing checks. The result is a finding about behaviour.',
        ),
      );
      expect(
        lines,
        contains(
          'Both the RTL run and the gate-level run used Icarus Verilog.',
        ),
      );
      expect(
        lines,
        contains(
          'Compared on the rising edge of clk, sampled just before the edge.',
        ),
      );
      expect(lines, contains('First difference at 4000 ps.'));
    });

    test('a test that did not run names its reason, and no clock', () {
      final lines = glsNoteLines(
        en(),
        view(_metrics('not_run', reason: 'fails_at_rtl')),
      ).map((l) => l.text).toList();
      expect(lines.first, 'Did not run');
      expect(lines[1], en().glsReasonFailsAtRtl);
      expect(lines.where((l) => l.startsWith('Compared on')), isEmpty);
    });

    test('a PDK that is not yet measured carries the banner, and a version '
        'that differs carries the warning', () {
      final lines = glsNoteLines(
        en(),
        view(
          _metrics(
            'equal',
            real: 0,
            x: 0,
            extra: {
              GlsMetricKeys.pdk: 'gf180mcuD',
              GlsMetricKeys.bannered: 'true',
              GlsMetricKeys.versionDiffers: 'true',
            },
          ),
        ),
      ).map((l) => l.text).toList();
      expect(
        lines,
        contains(en().glsPdkBanner('gf180mcuD')),
      );
      expect(lines, contains(en().glsVersionDiffers));
      expect(
        en().glsPdkBanner('gf180mcuD'),
        contains('not yet measured'),
      );
    });

    test("a row annotated from the run's delays leads with the note the "
        'edition that ran it supplies, and never says unit delays; without '
        'a note it says nothing about delays', () {
      final annotated = view(
        _metrics(
          'equal',
          real: 0,
          x: 0,
          extra: {GlsMetricKeys.delays: 'sdf'},
        ),
      );
      final unitDelays = en().glsNoteDelays;
      final noted = glsNoteLines(
        en(),
        annotated,
        annotatedNote: 'the edition note',
      );
      expect(noted.first.text, 'the edition note');
      expect(noted.first.title, isTrue);
      expect(noted[1].text, startsWith('Equal'));
      expect(noted.map((l) => l.text), isNot(contains(unitDelays)));
      final bare = glsNoteLines(en(), annotated).map((l) => l.text);
      expect(bare.first, startsWith('Equal'));
      expect(bare, isNot(contains(unitDelays)));
      // A functional row ignores a note and keeps the unit-delay sentence.
      final functional = glsNoteLines(
        en(),
        view(_metrics('equal', real: 0, x: 0)),
        annotatedNote: 'the edition note',
      ).map((l) => l.text);
      expect(functional, isNot(contains('the edition note')));
      expect(functional, contains(unitDelays));
    });

    test('a power-aware netlist says its power pins were tied', () {
      final lines = glsNoteLines(
        en(),
        view(
          _metrics(
            'equal',
            real: 0,
            x: 0,
            extra: {GlsMetricKeys.netlist: 'pnl'},
          ),
        ),
      ).map((l) => l.text);
      expect(lines, contains(en().glsNoteNetlistPnl));
    });
  });

  test('the run completion is spoken with each outcome counted, and only '
      'for a gate-level run', () {
    final l10n = lookupL10N(const Locale('en'));
    TestResult r(Map<String, String> metrics) => TestResult(
      testId: 't',
      runId: 'r',
      status: TestStatus.pass,
      startedAt: DateTime.utc(2026),
      finishedAt: DateTime.utc(2026),
      metrics: metrics,
    );
    final spoken = GlsLabels.completion(l10n, [
      r(_metrics('equal')),
      r(_metrics('equal')),
      r(_metrics('x_only')),
      r(_metrics('differs')),
      r(_metrics('not_run', reason: 'port_shape')),
      r(const <String, String>{}),
    ]);
    expect(
      spoken,
      'Gate-level simulation finished: 2 equal, 1 X-asymmetry only, '
      '1 differ, 1 did not run.',
    );
    expect(GlsLabels.completion(l10n, [r(const <String, String>{})]), isNull);
  });

  test('every reason has a sentence, and none is a bare token', () {
    final l10n = lookupL10N(const Locale('en'));
    for (final reason in GlsNotRunReason.values) {
      final text = GlsLabels.reason(l10n, reason);
      expect(text, isNotEmpty);
      expect(text, isNot(reason.wireName), reason: reason.name);
      expect(text, isNot(contains('_')), reason: reason.name);
    }
  });
}

class _StoreNotifier extends ResultStoreNotifier {
  _StoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
