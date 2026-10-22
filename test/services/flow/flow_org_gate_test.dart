// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/core/cli/flow_exit_code.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/suite.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/ci/ci_org_flow_gate_provider.dart';
import 'package:simcrux/services/ci/ci_runner.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/export/exporter_registry.dart';
import 'package:simcrux/services/flow/flow_gate.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_org_gate.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// The organization's flow gate: evaluated beside the user's thresholds,
/// reported apart from them, exit 3 when only it fails. Expectations come
/// from the committed nextpnr fixtures' meaning: `path_ice40_met` reached
/// about 61 MHz, so `fmax__achieved__mhz<5000` holds (fails) and
/// `fmax__achieved__mhz<1` does not.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('flow_org_gate_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String runOf(String fixture) {
    final dir = Directory(p.join(tmp.path, fixture))..createSync();
    File(
      '$fixtures/$fixture/report.json',
    ).copySync(p.join(dir.path, 'report.json'));
    return dir.path;
  }

  FlowOrgGate gate(
    List<String> specs, {
    List<(FlowGateOutcome, String)>? log,
  }) => FlowOrgGate(
    thresholds: [for (final s in specs) FlowOrgGate.parseThreshold(s)!],
    onEvaluated: log == null
        ? null
        : (outcome, {required subject}) => log.add((outcome, subject)),
  );

  group('combineExitCode', () {
    test('the table: 2 stands, an unevaluable org gate is 2, a violated one '
        'is 3, a met one changes nothing', () {
      const met = FlowGateDecision.met;
      const violated = FlowGateDecision.violated;
      const unreadable = FlowGateDecision.couldNotEvaluate;
      expect(FlowOrgGate.combineExitCode(0, null), 0);
      expect(FlowOrgGate.combineExitCode(1, met), 1);
      expect(FlowOrgGate.combineExitCode(0, violated), 3);
      expect(FlowOrgGate.combineExitCode(1, violated), 3);
      expect(FlowOrgGate.combineExitCode(2, violated), 2);
      expect(FlowOrgGate.combineExitCode(0, unreadable), 2);
      expect(FlowOrgGate.combineExitCode(1, unreadable), 2);
    });

    test('worse ranks could not evaluate over violated over met', () {
      expect(
        FlowOrgGate.worse(FlowGateDecision.met, FlowGateDecision.violated),
        FlowGateDecision.violated,
      );
      expect(
        FlowOrgGate.worse(
          FlowGateDecision.couldNotEvaluate,
          FlowGateDecision.violated,
        ),
        FlowGateDecision.couldNotEvaluate,
      );
      expect(
        FlowOrgGate.worse(null, FlowGateDecision.met),
        FlowGateDecision.met,
      );
    });
  });

  test('parseThreshold takes the --fail-on grammar and names the threshold '
      'as the organization', () {
    final t = FlowOrgGate.parseThreshold('route__drc_errors>0')!;
    expect(t.metric, 'route__drc_errors');
    expect(t.op, FlowGateOp.gt);
    expect(t.limit, 0);
    expect(t.name, kFlowOrgThresholdName);
    expect(FlowOrgGate.parseThreshold('not a threshold'), isNull);
    expect(FlowOrgGate.parseThreshold(42), isNull);
  });

  group('flow gate', () {
    late List<String> out;
    late List<String> err;
    setUp(() {
      out = <String>[];
      err = <String>[];
    });

    FlowCli cli({FlowOrgGate? orgGate}) => FlowCli(
      stdoutSink: out.add,
      stderrSink: err.add,
      driverRegistry: SimulatorDriverRegistry(const {}),
      orgGate: orgGate,
    );

    test(
      'without an organization gate the open binary never exits 3',
      () async {
        expect(await cli().run(['gate', runOf('path_ice40_met')]), 0);
      },
    );

    test('an organization threshold that fails exits 3, separately from the '
        "user's own", () async {
      final log = <(FlowGateOutcome, String)>[];
      final code = await cli(
        orgGate: gate(['fmax__achieved__mhz<5000'], log: log),
      ).run(['gate', runOf('path_ice40_met'), '--json']);
      expect(code, FlowExitCode.orgThresholdViolated);
      final doc = jsonDecode(out.join('\n')) as Map<String, Object?>;
      expect((doc['gate']! as Map)['decision'], 'met');
      expect((doc['gate']! as Map)['exit_label'], 'org_threshold_violated');
      final org = doc['org_gate']! as Map<String, Object?>;
      expect(org['decision'], 'violated');
      expect(((org['thresholds']! as List).single as Map)['result'], 'failed');
      // Audited once, under the run tag, never a path.
      expect(log.single.$1.decision, FlowGateDecision.violated);
      expect(log.single.$2, isNot(contains(Platform.pathSeparator)));
    });

    test("3 outranks the user's own violated; 2 outranks both", () async {
      expect(
        await cli(
          orgGate: gate(['fmax__achieved__mhz<5000']),
        ).run(['gate', runOf('path_ice40_violated')]),
        3,
      );
      expect(
        await cli(
          orgGate: gate(['fmax__achieved__mhz<5000']),
        ).run([
          'gate',
          runOf('path_ice40_met'),
          '--fail-on-hold-wns',
          '0',
        ]),
        2,
        reason: "the user's threshold names a metric the run lacks",
      );
    });

    test('a met organization gate leaves the code, and the text output '
        'names it', () async {
      final code = await cli(
        orgGate: gate(['fmax__achieved__mhz<1']),
      ).run(['gate', runOf('path_ice40_met')]);
      expect(code, 0);
      expect(out.join('\n'), contains('organization fmax__achieved__mhz<1.0'));
    });

    test('an organization threshold whose metric the run lacks is 2', () async {
      expect(
        await cli(
          orgGate: gate(['timing__hold__wns<0']),
        ).run(['gate', runOf('path_ice40_met')]),
        FlowExitCode.couldNotEvaluate,
      );
    });
  });

  group('--ci', () {
    test('open core binds no organization gate', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(ciOrgFlowGateProvider), isNull);
    });

    Future<int> runCi(
      FlowOrgGate? orgGate, {
      TestStatus status = TestStatus.pass,
      FlowReading? reading,
    }) async {
      final runner = CiRunner(
        configLoader: ConfigLoader(),
        schedulerFactory: (_) => _FlowScheduler(status),
        exporterRegistry: const ExporterRegistry(),
        fileWriter: (_, _) async {},
        stdoutWriter: (_) {},
        stderrWriter: (_) {},
        orgFlowGate: orgGate,
        readFlowRun: (_) async => reading,
      );
      final outcome = await runner.run(
        args: const CliArgs(projectPaths: ['/p/simcrux.yaml']),
        config: RegressionConfig(
          projectFilePath: '/p/simcrux.yaml',
          schemaVersion: '1',
          suites: <Suite>[
            Suite(
              name: 'flow',
              tests: <TestSpec>[
                TestSpec(
                  id: 'flow/adder',
                  name: 'adder',
                  suiteName: 'flow',
                  simulatorId: 'nextpnr',
                  top: 'adder',
                ),
              ],
            ),
          ],
          simulatorBinaries: const {},
          defaultPassFail: const ExitCodePassFailConfig(),
        ),
      );
      return outcome.exitCode;
    }

    test(
      'a violated organization threshold makes a passing run exit 3',
      () async {
        final reading = await const NextpnrRunReader().readRunDir(
          runOf('path_ice40_met'),
          logFallback: true,
        );
        expect(await runCi(null, reading: reading), 0);
        expect(
          await runCi(gate(['fmax__achieved__mhz<5000']), reading: reading),
          3,
        );
        expect(
          await runCi(gate(['fmax__achieved__mhz<1']), reading: reading),
          0,
        );
      },
    );

    test(
      'a flow run that cannot be read again cannot be evaluated: 2',
      () async {
        expect(await runCi(gate(['fmax__achieved__mhz<1'])), 2);
      },
    );
  });
}

/// One flow result with the summary metrics a flow driver records.
class _FlowScheduler implements JobScheduler {
  _FlowScheduler(this.status);

  final TestStatus status;

  @override
  Map<String, ResourceLock> get heldLocks => const {};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: true,
  );

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) =>
      Stream<RegressionEvent>.multi((controller) async {
        final now = DateTime.now().toUtc();
        for (final spec in request.tests) {
          controller.add(
            TestFinished(
              runId: request.runId,
              result: TestResult(
                testId: spec.id,
                runId: request.runId,
                status: status,
                startedAt: now,
                finishedAt: now,
                exitCode: 0,
                metrics: const <String, String>{
                  FlowMetricKeys.verdict: 'met',
                  FlowMetricKeys.kind: 'nextpnr',
                  FlowMetricKeys.runDir: '/runs/adder/t',
                },
              ),
            ),
          );
        }
        controller.add(
          RegressionFinished(runId: request.runId, cancelled: false),
        );
        await controller.close();
      });

  @override
  Future<void> cancel(String runId) async {}
}
