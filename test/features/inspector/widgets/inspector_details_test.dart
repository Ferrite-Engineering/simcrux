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
}) async {
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
        home: Scaffold(
          body: SingleChildScrollView(
            child: InspectorDetails(selection: selection),
          ),
        ),
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
