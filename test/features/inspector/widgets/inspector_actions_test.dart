// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/regression_trigger.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/dialogs/log_viewer_dialog.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/widgets/inspector_actions.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../../support/answered_telemetry.dart';

TestSpec _spec() {
  return TestSpec(
    id: 'smoke/pass_basic',
    name: 'pass_basic',
    suiteName: 'smoke',
    simulatorId: 'icarus',
    top: 'tb_pass_basic',
    sources: const ['/proj/tb_pass_basic.v'],
  );
}

SelectedTest _selection({TestSpec? spec, String? waveformPath}) {
  final result = TestResult(
    testId: 'smoke/pass_basic',
    runId: 'r1',
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026, 5),
    finishedAt: DateTime.utc(2026, 5).add(const Duration(milliseconds: 50)),
    exitCode: 0,
    waveformPath: waveformPath,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    ),
    spec: spec,
  );
}

RegressionConfig _config(TestSpec spec) {
  return RegressionConfig(
    projectFilePath: '/proj/simcrux.yaml',
    schemaVersion: '1',
    suites: [
      Suite(name: 'smoke', tests: [spec]),
      // A second suite: re-running one test must not run this one.
      Suite(
        name: 'nightly',
        tests: [
          TestSpec(
            id: 'nightly/soak',
            name: 'soak',
            suiteName: 'nightly',
            simulatorId: 'icarus',
            top: 'tb_soak',
          ),
        ],
      ),
    ],
    simulatorBinaries: const {
      'icarus': SimulatorBinaryConfig(simulatorId: 'icarus'),
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  SelectedTest selection, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [...answeredTelemetryOverrides(), ...overrides],
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(body: InspectorActions(selection: selection)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

OutlinedButton _buttonWithLabel(WidgetTester tester, String label) {
  return tester.widget<OutlinedButton>(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(OutlinedButton),
    ),
  );
}

void main() {
  group('InspectorActions', () {
    testWidgets('renders every localized action button', (tester) async {
      await _pump(tester, _selection(spec: _spec()));
      expect(tester.takeException(), isNull);
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(find.text(l10n.inspectorActionOpenFullLog), findsOneWidget);
      expect(find.text(l10n.inspectorActionRerun), findsOneWidget);
      expect(
        find.text(l10n.inspectorActionRerunWithWaveform),
        findsOneWidget,
      );
      expect(find.text(l10n.inspectorActionOpenSource), findsOneWidget);
      expect(
        find.text(l10n.inspectorActionDebugInWavecrux),
        findsOneWidget,
      );
    });

    testWidgets('disables Open Source when the selection has no spec', (
      tester,
    ) async {
      await _pump(tester, _selection());
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      expect(
        _buttonWithLabel(tester, l10n.inspectorActionOpenSource).onPressed,
        isNull,
      );
      // With a spec the same button is wired up.
      await _pump(tester, _selection(spec: _spec()));
      expect(
        _buttonWithLabel(tester, l10n.inspectorActionOpenSource).onPressed,
        isNotNull,
      );
    });

    testWidgets('Open full log opens the log viewer dialog', (tester) async {
      await _pump(tester, _selection(spec: _spec()));
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      await tester.tap(find.text(l10n.inspectorActionOpenFullLog));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(LogViewerDialog), findsOneWidget);
      // No result store is published in this test, so the dialog shows
      // its localized empty state.
      expect(find.text(l10n.logViewerEmpty), findsOneWidget);
    });

    testWidgets(
      'Debug in WaveCrux without a captured waveform shows the '
      'no-waveform snackbar',
      (tester) async {
        await _pump(tester, _selection(spec: _spec()));
        final l10n = L10N.of(tester.element(find.byType(Scaffold)));
        await tester.tap(find.text(l10n.inspectorActionDebugInWavecrux));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text(l10n.debugInWavecruxNoWaveform), findsOneWidget);
        // Let the snackbar's dismissal timer elapse so the test ends
        // without pending timers.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
      },
    );

    testWidgets('Re-run submits only the selected test, not every suite', (
      tester,
    ) async {
      final spec = _spec();
      final runner = _RecordingRunner();
      await _pump(
        tester,
        _selection(spec: spec),
        overrides: [
          activeConfigProvider.overrideWith(
            () => _StubActiveConfigNotifier(_config(spec)),
          ),
          regressionRunnerProvider.overrideWith(() => runner),
        ],
      );
      final l10n = L10N.of(tester.element(find.byType(Scaffold)));
      await tester.tap(find.text(l10n.inspectorActionRerun));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        runner.started,
        isEmpty,
        reason:
            'start() submits every suite and replaces the active config; '
            'a one-test re-run must not go through it',
      );
      expect(runner.submitted, hasLength(1));
      expect(runner.concurrencies, [1]);
      final submitted = runner.submitted.single;
      expect(submitted.map((t) => t.id), ['smoke/pass_basic']);
      expect(
        submitted.single.waveform.capture,
        spec.waveform.capture,
        reason: 'plain re-run must not alter the waveform policy',
      );
    });

    testWidgets(
      'Re-run with waveform forces the always-capture policy',
      (tester) async {
        final spec = _spec();
        final runner = _RecordingRunner();
        await _pump(
          tester,
          _selection(spec: spec),
          overrides: [
            activeConfigProvider.overrideWith(
              () => _StubActiveConfigNotifier(_config(spec)),
            ),
            regressionRunnerProvider.overrideWith(() => runner),
          ],
        );
        final l10n = L10N.of(tester.element(find.byType(Scaffold)));
        await tester.tap(find.text(l10n.inspectorActionRerunWithWaveform));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(runner.started, isEmpty);
        final rerunSpec = runner.submitted.single.single;
        expect(rerunSpec.id, 'smoke/pass_basic');
        expect(rerunSpec.waveform.capture, WaveformCapturePolicy.always);
        expect(rerunSpec.waveform.format, spec.waveform.format);
      },
    );

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pump(tester, _selection(spec: _spec()), locale: locale);
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });
}

/// [ActiveConfigNotifier] stub that materializes with a fixed config
/// so the re-run action can find the suite to replace.
class _StubActiveConfigNotifier extends ActiveConfigNotifier {
  _StubActiveConfigNotifier(this._config);
  final RegressionConfig? _config;

  @override
  RegressionConfig? build() => _config;
}

/// [RegressionRunner] stub that records `start` and `submitSpecs`
/// invocations instead of scheduling real simulator jobs.
class _RecordingRunner extends RegressionRunner {
  final List<RegressionConfig> started = <RegressionConfig>[];
  final List<List<TestSpec>> submitted = <List<TestSpec>>[];
  final List<int> concurrencies = <int>[];

  @override
  Future<void> start(
    RegressionConfig config, {
    int concurrency = 4,
    RegressionTrigger trigger = RegressionTrigger.manual,
  }) async {
    started.add(config);
    concurrencies.add(concurrency);
  }

  @override
  Future<void> submitSpecs(
    List<TestSpec> specs, {
    int concurrency = 4,
    RegressionTrigger trigger = RegressionTrigger.manual,
  }) async {
    submitted.add(specs);
    concurrencies.add(concurrency);
  }
}
