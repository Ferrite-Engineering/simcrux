// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_details.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

SelectedTest _selection({
  int? exitCode,
  String? stdoutPath,
  String? waveformPath,
}) {
  final result = TestResult(
    testId: 'smoke/pass_basic',
    runId: 'r1',
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    exitCode: exitCode,
    stdoutPath: stdoutPath,
    waveformPath: waveformPath,
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
  WidgetTester tester,
  SelectedTest selection, {
  Locale locale = const Locale('en'),
  double? width,
}) async {
  Widget details = SingleChildScrollView(
    child: InspectorDetails(selection: selection),
  );
  if (width != null) {
    details = Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: width, child: details),
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(body: details),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('InspectorDetails', () {
    testWidgets('renders localized labels and values for a full result', (
      tester,
    ) async {
      await _pump(
        tester,
        _selection(
          exitCode: 0,
          stdoutPath: '/work/smoke/pass_basic/sim_stdout.log',
          waveformPath: '/work/smoke/pass_basic/wave.fst',
        ),
      );
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));

      expect(find.text(l10n.inspectorSectionDetails), findsOneWidget);
      expect(find.text(l10n.inspectorFieldSuite), findsOneWidget);
      expect(find.text('smoke'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldSimulator), findsOneWidget);
      expect(find.text('icarus'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldDuration), findsOneWidget);
      expect(find.text('50 ms'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldExitCode), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldStartedAt), findsOneWidget);
      expect(find.text('2026-05-01T00:00:00.000Z'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldWorkingDirectory), findsOneWidget);
      expect(find.text('/work/smoke/pass_basic'), findsOneWidget);
      expect(find.text(l10n.inspectorFieldWaveform), findsOneWidget);
      expect(find.text('/work/smoke/pass_basic/wave.fst'), findsOneWidget);
    });

    testWidgets('omits optional rows and dashes a missing exit code', (
      tester,
    ) async {
      await _pump(tester, _selection());
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));

      // No exit code — placeholder dash.
      expect(find.text('—'), findsOneWidget);
      // No stdout path / waveform path — those rows are absent.
      expect(find.text(l10n.inspectorFieldWorkingDirectory), findsNothing);
      expect(find.text(l10n.inspectorFieldWaveform), findsNothing);
    });

    group('in a narrow panel', () {
      const longDir =
          '/work/regression/ack_handshake/prove_bug_with_a_long_name/run_0007';

      SelectedTest narrowSelection() => _selection(
        exitCode: 1,
        stdoutPath: '$longDir/sim_stdout.log',
      );

      testWidgets('a value never gets a column a few pixels wide: it '
          'stacks under its label', (tester) async {
        await _pump(tester, narrowSelection(), width: 150);
        expect(tester.takeException(), isNull);
        final l10n = L10N.of(tester.element(find.byType(Scaffold)));

        final label = find.text(l10n.inspectorFieldSuite);
        final value = find.text('smoke');
        // Under its label, left-aligned with it, on one line.
        expect(
          tester.getTopLeft(value).dy,
          greaterThan(tester.getBottomLeft(label).dy - 1),
        );
        expect(tester.getTopLeft(value).dx, tester.getTopLeft(label).dx);
        expect(tester.getSize(value).height, lessThan(20));

        // The long path is wrapped at the panel's width, not at a sliver.
        final dir = find.text(longDir);
        expect(tester.getSize(dir).width, greaterThan(100));
        expect(
          find.text(l10n.inspectorFieldWorkingDirectory),
          findsOneWidget,
        );
      });

      testWidgets('a roomy panel keeps the value beside its label', (
        tester,
      ) async {
        await _pump(tester, narrowSelection(), width: 500);
        final l10n = L10N.of(tester.element(find.byType(Scaffold)));
        expect(
          tester.getTopLeft(find.text('smoke')).dy,
          tester.getTopLeft(find.text(l10n.inspectorFieldSuite)).dy,
        );
        expect(
          tester.getTopLeft(find.text('smoke')).dx,
          greaterThan(
            tester.getTopLeft(find.text(l10n.inspectorFieldSuite)).dx,
          ),
        );
      });
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(
          tester,
          _selection(
            exitCode: 1,
            stdoutPath: '/work/smoke/pass_basic/sim_stdout.log',
            waveformPath: '/work/smoke/pass_basic/wave.fst',
          ),
          locale: locale,
        );
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}
