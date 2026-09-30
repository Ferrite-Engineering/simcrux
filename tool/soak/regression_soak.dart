// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Long-run memory soak harness. Drives the real LocalJobScheduler with
// the in-process FakeProcessRunner over an N-test regression (no real
// simulator), streaming results to the bounded StreamingResultsWriter and a
// discarding sink, while sampling ProcessInfo.currentRss at start, every
// 1000 tests, and at end. Appends one JSON sample per checkpoint to
// build/soak/results.jsonl (gitignored). The fake runner makes a 10k-test
// soak finish in seconds.
//
//   dart run tool/soak/regression_soak.dart [N]
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/services/job_scheduler/fake_process_runner.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/orchestration_fixture.dart';
import 'package:simcrux/services/result_store/streaming_results_writer.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

Future<void> main(List<String> argv) async {
  final n = argv.isNotEmpty ? int.parse(argv.first) : 10000;
  final out = Directory('build/soak')..createSync(recursive: true);
  final samples = File('${out.path}/results.jsonl').openWrite();

  final fake = FakeProcessRunner(
    // Each fake test emits a handful of log lines and exits cleanly.
    resolveBehavior: (_) => const FakeProcessBehavior(
      stdout: <String>['sim start', 'PASS'],
    ),
  );
  final driver = OrchestrationFixtureDriver(reaper: fake);
  final scheduler = LocalJobScheduler(
    driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
    config: RegressionConfig(
      projectFilePath: '/soak/simcrux.yaml',
      schemaVersion: '1',
      suites: const [],
      simulatorBinaries: const {},
    ),
    runRoot: Directory.systemTemp.createTempSync('simcrux_soak_').path,
  );

  // The bounded at-scale path: results stream to ndjson (here, discarded)
  // while only O(1) aggregate counts stay in memory.
  final writer = StreamingResultsWriter(
    resultsPath: '${out.path}/results.ndjson',
    openSink: (_) async => _DiscardSink(),
    writeSummary: (_, __) async {},
  );
  await writer.start(runId: 'soak', startedAt: DateTime.now().toUtc());

  void sample(String mark, int done) {
    samples.writeln(
      jsonEncode(<String, Object?>{
        'mark': mark,
        'tests_done': done,
        'rss_bytes': ProcessInfo.currentRss,
        'recorded': writer.recordedCount,
      }),
    );
  }

  sample('start', 0);
  final specs = <TestSpec>[
    for (var i = 0; i < n; i++)
      TestSpec(
        id: 'soak/t$i',
        name: 't$i',
        suiteName: 'soak',
        simulatorId: 'fake',
        top: 'tb',
      ),
  ];

  var done = 0;
  await for (final event in scheduler.submit(
    RegressionRequest(runId: 'soak', tests: specs),
  )) {
    if (event is TestFinished) {
      await writer.recordRow(
        DashboardRow(
          result: event.result,
          suiteName: 'soak',
          simulatorId: 'fake',
          testName: event.result.testId,
        ),
      );
      done++;
      if (done % 1000 == 0) sample('checkpoint', done);
    }
  }
  await writer.recordRunCompletion(finishedAt: DateTime.now().toUtc());
  sample('end', done);
  await samples.flush();
  await samples.close();
  stdout.writeln(
    'soak complete: $done tests, peak RSS sampled to '
    '${out.path}/results.jsonl',
  );
}

/// IOSink that discards everything written to it — the soak keeps zero
/// per-row bytes in memory so the sampled RSS reflects the writer's own
/// O(1) footprint, not a test sink's accumulation.
class _DiscardSink implements IOSink {
  @override
  Encoding encoding = const Utf8Codec();
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> get done async {}
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}
