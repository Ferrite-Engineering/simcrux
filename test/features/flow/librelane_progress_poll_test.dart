// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/trend_store/trend_store_provider.dart';

import '../../services/flow/librelane_run_builder.dart';
import '../../support/answered_telemetry.dart';
import '../../support/poll_until.dart';

/// A LibreLane process that runs until the test lets it exit.
class _GatedProcess implements TestProcess {
  final Completer<int> exit = Completer<int>();

  @override
  Stream<String> get stdout => const Stream<String>.empty();

  @override
  Stream<String> get stderr => const Stream<String>.empty();

  @override
  Future<int> get exitCode => exit.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exit.isCompleted) exit.complete(-15);
    return true;
  }
}

/// The desktop app's progress for a LibreLane run, end to end and live: the
/// real driver polls a run directory that grows while the run is in flight,
/// and each new step reaches the app's own log providers (the ones the log
/// panel and the inspector watch) through the real scheduler and
/// [RegressionRunner] before the run ends. Only the process is played: it
/// writes nothing and exits when told; the test writes the run directory
/// LibreLane would, one step at a time.
void main() {
  late Directory project;
  late Directory trends;
  late String design;

  setUp(() {
    project = Directory.systemTemp.createTempSync('flow_progress_proj_');
    trends = Directory.systemTemp.createTempSync('flow_progress_trends_');
    design = p.join(project.resolveSymbolicLinksSync(), 'design');
    Directory(design).createSync();
    File(p.join(design, 'config.yaml')).writeAsStringSync('DESIGN_NAME: c\n');
  });

  tearDown(() {
    project.deleteSync(recursive: true);
    trends.deleteSync(recursive: true);
  });

  test('each new step directory reaches the log providers while the run is '
      'still in flight', () async {
    final process = _GatedProcess();
    String? tag;
    final driver = LibreLaneFlowDriver(
      launcher: (executable, args, {environment, workingDirectory}) async {
        tag = args[args.indexOf('--run-tag') + 1];
        return process;
      },
      pollInterval: const Duration(milliseconds: 20),
      hostEnvironment: const <String, String>{},
    );
    final container = ProviderContainer(
      overrides: [
        ...answeredTelemetryOverrides(),
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({LibreLaneFlowDriver.kId: driver}),
        ),
        trendStoreDirectoryOverrideProvider.overrideWithValue(trends.path),
      ],
    );
    addTearDown(container.dispose);

    const importer = FlowRunImporter();
    final entry = importer.resolve(
      FlowEntry(
        name: 'adder',
        kind: FlowKind.librelane,
        config: 'design/config.yaml',
        pdk: 'sky130A',
      ),
      project.resolveSymbolicLinksSync(),
    );
    final spec = importer.specFor(entry);
    final config = RegressionConfig(
      projectFilePath: p.join(project.path, 'simcrux.yaml'),
      schemaVersion: '1',
      suites: [
        Suite(name: FlowRunImporter.kFlowSuiteName, tests: [spec]),
      ],
      simulatorBinaries: const {},
      flow: FlowConfig(entries: [entry]),
    );

    // What the log panel shows, as it watches it.
    final seen = <List<String>>[];
    final sub = container.listen<List<String>>(
      fullInspectorLogProvider(spec.id).select(
        (lines) => [
          for (final l in lines)
            if (l.line.startsWith('librelane: step')) l.line,
        ],
      ),
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    addTearDown(sub.close);
    List<String> shown() => sub.read();

    await container.read(regressionRunnerProvider.notifier).start(config);
    expect(await pollUntil(() => tag != null), isTrue);
    final run = LibreLaneRunBuilder(design, tag: tag!)
      ..step('Yosys.Synthesis', complete: false);
    expect(await pollUntil(() => shown().length == 1), isTrue);
    expect(shown(), ['librelane: step 01-Yosys.Synthesis']);
    expect(process.exit.isCompleted, isFalse);
    expect(
      container.read(regressionRunnerProvider).value?.isFinished,
      isNot(isTrue),
    );

    run.step('OpenROAD.Floorplan', complete: false);
    expect(await pollUntil(() => shown().length == 2), isTrue);
    expect(shown(), [
      'librelane: step 01-Yosys.Synthesis',
      'librelane: step 02-OpenROAD.Floorplan',
    ]);
    expect(process.exit.isCompleted, isFalse);

    run
      ..step('OpenROAD.GlobalPlacement')
      ..finalMetrics(cleanMetrics);
    process.exit.complete(0);
    expect(
      await pollUntil(
        () =>
            container.read(regressionRunnerProvider).value?.isFinished ?? false,
      ),
      isTrue,
    );
    // The step that appeared between the last poll and the exit comes from
    // the driver's final poll; the panel refreshes on its coalescing window.
    expect(await pollUntil(() => shown().length == 3), isTrue);
    expect(shown(), [
      'librelane: step 01-Yosys.Synthesis',
      'librelane: step 02-OpenROAD.Floorplan',
      'librelane: step 03-OpenROAD.GlobalPlacement',
    ]);
    // Each step was shown once, and the list only ever grew.
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].take(seen[i - 1].length), seen[i - 1]);
    }
  });
}
