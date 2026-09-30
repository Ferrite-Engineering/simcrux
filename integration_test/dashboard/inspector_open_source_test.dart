// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// integration_test/dashboard/inspector_open_source_test.dart
//
// Inspector source navigation journey: a seeded run populates the
// dashboard, a row is selected, and the "Open Source" button in
// `InspectorActions` hands off to the injected `editorLauncherProvider`.
// Overrides that provider at the root container with an `EditorLauncher`
// wired to a recording `processStarter` fake (mirrors
// `test/features/inspector/services/editor_launcher_test.dart`'s
// `_RecordingStarter` / `_FakeProcess` shape) so no real editor process is
// ever spawned, then asserts the fake recorded the resolved testbench
// source path.

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../helpers/app_driver.dart';
import '../helpers/seeded_run.dart';

/// Records every process-start invocation instead of actually spawning
/// an editor process.
class _RecordingStarter {
  final List<({String executable, List<String> args})> calls =
      <({String executable, List<String> args})>[];

  Future<Process> start(String executable, List<String> args) async {
    calls.add((executable: executable, args: List.unmodifiable(args)));
    return _FakeProcess();
  }
}

class _FakeProcess implements Process {
  @override
  int get pid => 1;

  @override
  Future<int> get exitCode async => 0;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  IOSink get stdin => throw UnimplementedError();

  @override
  Stream<List<int>> get stdout => const Stream.empty();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  suppressPlatformSemanticsLeak();

  testWidgets(
    "Open Source button hands the selected test's source path off to the "
    'injected editor launcher',
    (tester) async {
      final project = await writeSeededProject(
        tests: const [
          SeededTest('smoke', 'alu_pass', [ScriptedOutcome.passed()]),
        ],
      );
      final driver = ScriptedDriver(project.outcomesByTestName);
      final recorder = _RecordingStarter();
      final fakeLauncher = EditorLauncher(
        template: 'code --goto {file}:{line}:{column}',
        processStarter: recorder.start,
        // The editor the template names is not installed on a CI runner, and
        // on Windows the launcher resolves the executable before it hands
        // off — correctly, because `CreateProcess` searches the launch
        // directory before `PATH`, so a bare name is exactly what must never
        // be spawned. This journey is about the hand-off, not about whether
        // an editor is installed, so the on-disk probe answers yes and the
        // resolution proceeds to the recorder. macOS and Linux never consult
        // it: resolution is a passthrough there, which is why this failed on
        // Windows alone.
        spawnHost: SpawnHost(
          windows: Platform.isWindows,
          environment: Platform.environment,
          exists: (_) => true,
        ),
      );

      await bootSimcrux(
        tester,
        args: [project.configPath],
        extraOverrides: [
          seededDriverRegistryOverride(driver),
          editorLauncherProvider.overrideWithValue(fakeLauncher),
        ],
      );
      await pumpUntil(tester, () => tabCount(tester) == 1);
      final tab = tabContainerFor(tester);
      await startSeededRun(tester, tab);
      await pumpUntilRunFinished(tester, tab, expectedResults: 1);

      final l10n = L10N.of(tester.element(find.byType(Scaffold).first));

      // Select the seeded row so the inspector's Open Source button
      // enables (it is disabled until `selection.spec` is non-null).
      final rowVisible = await pumpUntil(
        tester,
        () => find.text('alu_pass').evaluate().isNotEmpty,
      );
      expect(rowVisible, isTrue);
      await tester.tap(find.text('alu_pass').first);
      final selected = await pumpUntil(
        tester,
        () => tab.read(selectedTestIdProvider) == 'smoke/alu_pass',
      );
      expect(selected, isTrue, reason: 'row tap must select smoke/alu_pass');

      final openSourceButton = find.widgetWithText(
        OutlinedButton,
        l10n.inspectorActionOpenSource,
      );
      final buttonShown = await pumpUntil(
        tester,
        () => openSourceButton.evaluate().isNotEmpty,
      );
      expect(buttonShown, isTrue, reason: 'Open Source button must render');

      await tester.tap(openSourceButton);
      final dispatched = await pumpUntil(
        tester,
        () => recorder.calls.isNotEmpty,
      );
      expect(
        dispatched,
        isTrue,
        reason: 'Open Source must hand off to the injected editor launcher',
      );

      final expectedSource = p.normalize(p.join(project.dir.path, 'tb.v'));
      expect(recorder.calls, hasLength(1));
      // The launcher starts what the resolution returned, which on Windows
      // is a full path (`…\\code.COM`) and elsewhere the name as written.
      // Both are "the editor the template named", and pinning the bare name
      // would be pinning the absence of the resolution.
      expect(
        p.basenameWithoutExtension(recorder.calls.single.executable),
        'code',
      );
      expect(
        recorder.calls.single.args,
        <String>['--goto', '$expectedSource:1:1'],
      );

      expect(tester.takeException(), isNull);
    },
  );
}
