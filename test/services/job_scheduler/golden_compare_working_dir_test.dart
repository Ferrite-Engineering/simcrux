// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

// End-to-end proof of the working-directory seam: the scheduler's single
// `classifyAsync` call site threads the test's working directory, so a
// filesystem-backed detector can actually see the dumps the run just
// produced.
//
// Every case here exits **0**. That is the point: without the detector
// the scheduler would report `pass` for all of them, including the run
// that wrote no dump at all.
//
// MUTATION: drop `workingDirectory: workDir` from
// `LocalJobScheduler._runExecute`'s classifyAsync call and every case
// below reports `fail` — including "matching dumps", which is how you
// tell this test is really exercising the seam.

/// Fake driver that writes whatever the test asks into the scheduler's
/// working directory, then exits 0.
class _DumpWritingDriver implements SimulatorDriver {
  _DumpWritingDriver(this.filesFor);

  /// testId → {filename: contents}. An absent filename is simply not
  /// written, which models a run that produced no dump.
  final Map<String, String> Function(String testId) filesFor;

  String? lastWorkingDirectory;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: false,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    return const CompileResult(
      success: true,
      artifactPath: 'noop',
      stdout: '',
      stderr: '',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) {
    lastWorkingDirectory = request.workingDirectory;
    final controller = StreamController<TestExecutionEvent>();
    final started = DateTime.now().toUtc();
    scheduleMicrotask(() async {
      filesFor(request.test.id).forEach((name, contents) {
        File(p.join(request.workingDirectory, name))
          ..createSync(recursive: true)
          ..writeAsStringSync(contents);
      });
      controller.add(
        TestExecutionFinished(
          // A clean exit — the driver's own verdict is `pass`.
          status: TestStatus.pass,
          exitCode: 0,
          startedAt: started,
          finishedAt: DateTime.now().toUtc(),
        ),
      );
      await controller.close();
    });
    return controller.stream;
  }

  @override
  void cancel(String testId) {}
}

void main() {
  const canonical = 'deadbeef\n0000000f\n12345678\ncafebabe\n';

  late Directory runRoot;

  setUp(() {
    runRoot = Directory.systemTemp.createTempSync('simcrux_sched_golden_');
  });

  tearDown(() {
    if (runRoot.existsSync()) runRoot.deleteSync(recursive: true);
  });

  TestSpec goldenSpec(String id) => TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'fake',
    top: 'tb',
    timeout: const Duration(seconds: 30),
    passFail: GoldenComparePassFailConfig.forProfile(
      GoldenCompareProfile.riscvSignature,
    ),
  );

  Future<TestResultStatuses> run(
    Map<String, String> Function(String testId) filesFor,
    List<String> ids,
  ) async {
    final driver = _DumpWritingDriver(filesFor);
    final scheduler = LocalJobScheduler(
      driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
      config: RegressionConfig(
        projectFilePath: '/fake/simcrux.yaml',
        schemaVersion: '1',
        suites: const [],
        simulatorBinaries: const {},
      ),
      runRoot: runRoot.path,
    );
    final events = await scheduler
        .submit(
          RegressionRequest(
            runId: 'r1',
            tests: ids.map(goldenSpec).toList(),
          ),
        )
        .toList();
    return (
      statuses: <String, TestStatus>{
        for (final f in events.whereType<TestFinished>())
          f.result.testId: f.result.status,
      },
      workingDirectory: driver.lastWorkingDirectory,
    );
  }

  test('matching dumps written into the work dir classify as pass', () async {
    final outcome = await run(
      (_) => {
        'signature.dut.sig': canonical,
        'signature.ref.sig': canonical,
      },
      ['arch/add'],
    );
    expect(outcome.statuses['arch/add'], TestStatus.pass);
    expect(outcome.workingDirectory, isNotNull);
  });

  test('divergent dumps fail even though the driver exited 0', () async {
    final outcome = await run(
      (_) => {
        'signature.dut.sig': 'deadbeef\n0000000f\nffffffff\ncafebabe\n',
        'signature.ref.sig': canonical,
      },
      ['arch/add'],
    );
    // The driver said pass. The detector overrules it — which is only
    // possible because it could read the work dir.
    expect(outcome.statuses['arch/add'], TestStatus.fail);
  });

  test('a run that wrote no dump fails, not passes', () async {
    final outcome = await run(
      (_) => {'signature.ref.sig': canonical},
      ['arch/add'],
    );
    final status = outcome.statuses['arch/add'];
    expect(status, TestStatus.fail);
    expect(status, isNot(TestStatus.unknown));
    expect(status, isNot(TestStatus.vacuous));
  });

  test('an empty dump fails, not passes', () async {
    final outcome = await run(
      (_) => {'signature.dut.sig': '', 'signature.ref.sig': canonical},
      ['arch/add'],
    );
    expect(outcome.statuses['arch/add'], TestStatus.fail);
  });

  test('each test is classified against its OWN working directory', () async {
    final outcome = await run(
      (id) => id.endsWith('good')
          ? {
              'signature.dut.sig': canonical,
              'signature.ref.sig': canonical,
            }
          : {
              'signature.dut.sig': 'deadbeef\n',
              'signature.ref.sig': canonical,
            },
      ['arch/good', 'arch/bad'],
    );
    expect(outcome.statuses['arch/good'], TestStatus.pass);
    expect(outcome.statuses['arch/bad'], TestStatus.fail);
  });
}

typedef TestResultStatuses = ({
  Map<String, TestStatus> statuses,
  String? workingDirectory,
});
