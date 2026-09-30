// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/retry_policy.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Determinism. The first flaky retry must replay the seed the run
/// *actually used* (the effective, possibly clock-derived seed), so it
/// reproduces the original failure. MUTATION: a driver that reports the
/// requested seed (`null`) instead of the effective seed makes the replay
/// roll a fresh seed — the two attempts no longer match.
class _FakeProcess implements TestProcess {
  _FakeProcess(this.exit);
  final int exit;
  @override
  Stream<String> get stdout => const Stream<String>.empty();
  @override
  Stream<String> get stderr => const Stream<String>.empty();
  @override
  Future<int> get exitCode async => exit;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

/// Replays the recorded effective seed on the first retry.
class _ReplayPolicy implements RetryPolicy {
  @override
  bool shouldRetry({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
    required int maxAttempts,
  }) => attemptsSoFar < 2;

  @override
  int? nextSeedFor({
    required TestSpec spec,
    required TestResult lastResult,
    required int attemptsSoFar,
  }) => lastResult.executionSeed;
}

void main() {
  test('first retry replays the effective (clock-derived) seed', () async {
    final tmp = Directory.systemTemp.createTempSync('simcrux_seedreplay_');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    final vvpSeeds = <int>[];
    Future<TestProcess> launch(
      String executable,
      List<String> args, {
      Map<String, String>? environment,
      String? workingDirectory,
    }) async {
      if (executable.contains('iverilog')) {
        // Make compile succeed: produce the .vvp the driver checks for.
        File(p.join(workingDirectory!, 'sim.vvp')).createSync(recursive: true);
        return _FakeProcess(0);
      }
      // vvp (execute): capture the +seed=N it was launched with, then fail
      // so the retry policy is consulted.
      for (final a in args) {
        if (a.startsWith('+seed=')) {
          vvpSeeds.add(int.parse(a.substring('+seed='.length)));
        }
      }
      return _FakeProcess(1);
    }

    final driver = IcarusDriver(launcher: launch);
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: RegressionConfig(
        projectFilePath: '/p/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: tmp.path,
      retryPolicy: _ReplayPolicy(),
    );

    final spec = TestSpec(
      id: 'unit/alu',
      name: 'alu',
      suiteName: 'unit',
      simulatorId: 'icarus',
      top: 'tb',
      // No seed pinned ⇒ the driver derives + reports the effective seed.
    );
    final events = await scheduler
        .submit(RegressionRequest(runId: 'r1', tests: [spec]))
        .toList();

    // Two attempts ran (original + one retry).
    expect(vvpSeeds, hasLength(2));
    // The retry replayed the effective seed the first attempt actually ran
    // with — not a fresh roll, and not the requested null.
    expect(vvpSeeds[1], vvpSeeds[0]);

    final result = events.whereType<TestFinished>().single.result;
    expect(result.executionSeed, vvpSeeds[0]);
  });
}
