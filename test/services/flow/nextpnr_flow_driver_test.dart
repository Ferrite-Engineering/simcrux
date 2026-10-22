// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:crux_yosys/crux_yosys.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/nextpnr_flow_driver.dart';

import 'flow_fakes.dart';

/// The nextpnr driver against scripted processes: the verdict is the
/// report's (a fixture report the fake nextpnr leaves), never the exit code;
/// the run directory is fresh and inside the project; nothing is deleted.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory project;
  late Directory work;

  setUp(() {
    project = Directory.systemTemp.createTempSync('flow_nextpnr_proj_');
    work = Directory.systemTemp.createTempSync('flow_nextpnr_work_');
  });
  tearDown(() {
    project.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
  });

  FlowEntry entry({
    NextpnrFamily family = NextpnrFamily.ice40,
    String device = 'up5k',
    String? package = 'sg48',
    String? constraints,
    double? freq = 12,
    bool detailed = false,
    FlowFusesocConfig? fusesoc,
  }) => FlowEntry(
    name: 'adder',
    kind: FlowKind.nextpnr,
    family: fusesoc == null ? family : null,
    device: fusesoc == null ? device : null,
    package: fusesoc == null ? package : null,
    constraints: constraints,
    top: fusesoc == null ? 'path_adder' : null,
    sources: fusesoc == null
        ? <String>[p.join(project.path, 'path_adder.v')]
        : const <String>[],
    freqMhz: fusesoc == null ? freq : null,
    detailedTiming: detailed,
    fusesoc: fusesoc,
    projectRoot: project.resolveSymbolicLinksSync(),
  );

  TestSpec specFor(FlowEntry e) => const FlowRunImporter().specFor(e);

  NextpnrFlowDriver driver(
    FlowSpawnRecorder recorder, {
    YosysRunResult? synth,
    FakeYosysRunner? yosys,
  }) {
    final runner =
        yosys ??
        FakeYosysRunner(
          synth ??
              const YosysRunSuccess(
                rawJson: '{"modules": {}}',
                stdout: '',
                stderr: '',
              ),
        );
    return NextpnrFlowDriver(
      launcher: recorder.launch,
      yosysRunnerFor: (_) => runner,
      clock: () => DateTime.utc(2026, 10, 21, 12),
    );
  }

  /// Plays nextpnr: copies a fixture's report and log into the run
  /// directory (its working directory), then exits with [exit].
  FakeFlowProcess Function(FlowSpawn) nextpnrLeaving(
    String? fixture, {
    int exit = 0,
  }) => (spawn) {
    if (fixture != null) {
      for (final name in const ['report.json', 'pnr.log']) {
        File(
          '$fixtures/$fixture/$name',
        ).copySync(p.join(spawn.cwd!, name));
      }
    }
    return FakeFlowProcess(exit: exit);
  };

  Future<TestExecutionFinished> runOnce(
    NextpnrFlowDriver d,
    TestSpec spec, {
    SimulatorBinaryConfig? config,
  }) async {
    final binary =
        config ?? const SimulatorBinaryConfig(simulatorId: 'nextpnr');
    final compiled = await d.compile(
      CompileRequest(
        test: spec,
        workingDirectory: work.path,
        binaryConfig: binary,
      ),
    );
    expect(compiled.success, isTrue);
    return await finishedOf(
      d.execute(
        ExecuteRequest(
          test: spec,
          workingDirectory: work.path,
          compileResult: compiled,
          binaryConfig: binary,
        ),
      ),
    );
  }

  group('verdict from the report, never the exit code', () {
    test('exit 1 with a violated report is violated', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_violated', exit: 1),
      );
      final finished = await runOnce(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'violated');
      expect(finished.status, TestStatus.fail);
      expect(finished.metrics[FlowMetricKeys.processExitCode], '1');
      expect(finished.failureMessage, contains('findings, not signoff'));
    });

    test('exit 0 with a met report is met', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      final finished = await runOnce(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'met');
      expect(finished.status, TestStatus.pass);
      expect(finished.metrics[FlowMetricKeys.wnsPs], isNotNull);
      expect(finished.metrics[FlowMetricKeys.fmaxMhz], isNotNull);
    });

    test('exit 0 with no report is notRun', () async {
      final recorder = FlowSpawnRecorder(onSpawn: nextpnrLeaving(null));
      final finished = await runOnce(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
      expect(finished.status, TestStatus.fail);
    });

    test('exit 1 with a met report is still met', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met', exit: 1),
      );
      final finished = await runOnce(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'met');
    });
  });

  group('the command line', () {
    test('ice40: device, package, pcf, json, freq, report, write, log', () {
      const job = NextpnrJob(runDir: '/r', tag: 't');
      expect(
        NextpnrFlowDriver.nextpnrArgs(
          entry(constraints: '/p/board.pcf', detailed: true),
          job,
        ),
        <String>[
          '--up5k',
          '--package',
          'sg48',
          '--pcf',
          '/p/board.pcf',
          '--json',
          job.netlist,
          '--freq',
          '12',
          '--report',
          job.report,
          '--detailed-timing-report',
          '--write',
          job.post,
          '--log',
          job.log,
        ],
      );
    });

    test('ecp5 takes an lpf; gowin and gatemate go through himbaechel', () {
      const job = NextpnrJob(runDir: '/r', tag: 't');
      expect(
        NextpnrFlowDriver.nextpnrArgs(
          entry(
            family: NextpnrFamily.ecp5,
            device: '25k',
            package: 'CABGA256',
            constraints: '/p/b.lpf',
          ),
          job,
        ).take(5),
        ['--25k', '--package', 'CABGA256', '--lpf', '/p/b.lpf'],
      );
      expect(
        NextpnrFlowDriver.nextpnrArgs(
          entry(
            family: NextpnrFamily.gowin,
            device: 'GW1NR-LV9QN88PC6/I5',
            package: null,
            constraints: '/p/b.cst',
          ),
          job,
        ).take(4),
        ['--device', 'GW1NR-LV9QN88PC6/I5', '--vopt', 'cst=/p/b.cst'],
      );
      expect(NextpnrFamily.gatemate.binary, 'nextpnr-himbaechel');
      expect(
        NextpnrFlowDriver.synthCommand(entry(family: NextpnrFamily.gatemate)),
        'synth_gatemate -top path_adder -luttree',
      );
    });

    test('synthesis is synth_<family> through the Yosys runner', () async {
      final yosys = FakeYosysRunner(
        const YosysRunSuccess(rawJson: '{}', stdout: '', stderr: ''),
      );
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      await runOnce(driver(recorder, yosys: yosys), specFor(entry()));
      final request = yosys.requests.single;
      expect(request.extraCommands, ['synth_ice40 -top path_adder']);
      expect(request.topModule, 'path_adder');
      expect(recorder.spawns.single.executable, 'nextpnr-ice40');
    });
  });

  group('the run directory', () {
    test('is runs/<entry>/<prefix>-<UTC stamp> inside the project, '
        'holding the netlist and the report', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      final finished = await runOnce(driver(recorder), specFor(entry()));
      final runDir = finished.metrics[FlowMetricKeys.runDir]!;
      expect(
        runDir,
        p.join(
          project.resolveSymbolicLinksSync(),
          'runs',
          'adder',
          'simcrux-20261021T120000Z',
        ),
      );
      expect(File(p.join(runDir, 'synth.json')).existsSync(), isTrue);
      expect(File(p.join(runDir, 'report.json')).existsSync(), isTrue);
      expect(recorder.spawns.single.cwd, runDir);
      expect(finished.metrics[FlowMetricKeys.tag], 'simcrux-20261021T120000Z');
    });

    test('a second run never reuses or overwrites the first', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      final d = driver(recorder);
      final first = await runOnce(d, specFor(entry()));
      final firstReport = File(
        p.join(first.metrics[FlowMetricKeys.runDir]!, 'report.json'),
      );
      final before = firstReport.readAsStringSync();
      final second = await runOnce(d, specFor(entry()));
      expect(
        second.metrics[FlowMetricKeys.runDir],
        isNot(first.metrics[FlowMetricKeys.runDir]),
      );
      expect(second.metrics[FlowMetricKeys.tag], 'simcrux-20261021T120000Z-2');
      expect(firstReport.readAsStringSync(), before);
    });

    test('a runs directory that links out of the project is refused, and '
        'nothing is spawned', () async {
      final outside = Directory.systemTemp.createTempSync('flow_outside_');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(p.join(project.path, 'runs')).createSync(outside.path);
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      final finished = await runOnce(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
      expect(recorder.spawns, isEmpty);
      expect(outside.listSync(), isEmpty);
    }, testOn: '!windows');

    test('XDG_DATA_HOME is set to the work directory when absent', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: nextpnrLeaving('path_ice40_met'),
      );
      final d = driver(recorder);
      // The driver honours a host XDG_DATA_HOME; assert the absent case on
      // the helper with an empty host environment, and that the spawn
      // carries one either way.
      final env = FlowProcessDriver.flowEnvironment(
        work.path,
        const <String, String>{},
        hostEnvironment: const <String, String>{},
      );
      expect(env['XDG_DATA_HOME'], p.join(work.path, 'xdg'));
      expect(Directory(p.join(work.path, 'xdg')).existsSync(), isTrue);
      await runOnce(d, specFor(entry()));
      final spawned = recorder.spawns.single.environment ?? const {};
      expect(
        spawned['XDG_DATA_HOME'] ?? Platform.environment['XDG_DATA_HOME'],
        isNotNull,
      );
    });
  });

  group('when a step or tool fails', () {
    test(
      'a failed synthesis is stopped at synthesis; nextpnr never runs',
      () async {
        final recorder = FlowSpawnRecorder();
        final finished = await runOnce(
          driver(
            recorder,
            synth: const YosysRunFailure(
              kind: YosysFailureKind.nonZeroExit,
              exitCode: 1,
              stdout: '',
              stderr:
                  'ERROR: Module `missing` referenced in module `top` not '
                  'defined',
            ),
          ),
          specFor(entry()),
        );
        expect(finished.metrics[FlowMetricKeys.verdict], 'stopped');
        expect(finished.metrics[FlowMetricKeys.stoppedStep], 'synthesis');
        expect(recorder.spawns, isEmpty);
      },
    );

    test('a missing Yosys is notRun and names yosys', () async {
      final finished = await runOnce(
        driver(
          FlowSpawnRecorder(),
          synth: const YosysRunFailure(
            kind: YosysFailureKind.launch,
            exitCode: -1,
            stdout: '',
            stderr: 'Could not run the executable "yosys"',
          ),
        ),
        specFor(entry()),
      );
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
      expect(finished.metrics[FlowDriverMetricKeys.toolMissing], 'yosys');
    });

    test('a missing nextpnr is notRun and names nextpnr', () async {
      final finished = await runOnce(
        driver(FlowSpawnRecorder(missing: const {'nextpnr-ice40'})),
        specFor(entry()),
      );
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
      expect(finished.metrics[FlowDriverMetricKeys.toolMissing], 'nextpnr');
      expect(finished.status, TestStatus.fail);
    });

    test('cancel during synthesis stops Yosys', () async {
      final yosys = FakeYosysRunner(
        const YosysRunSuccess(rawJson: '{}', stdout: '', stderr: ''),
        hangUntilCancelled: true,
      );
      final recorder = FlowSpawnRecorder();
      final d = driver(recorder, yosys: yosys);
      final spec = specFor(entry());
      final compiling = d.compile(
        CompileRequest(
          test: spec,
          workingDirectory: work.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'nextpnr'),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      d.cancel(spec.id);
      final compiled = await compiling;
      final finished = await finishedOf(
        d.execute(
          ExecuteRequest(
            test: spec,
            workingDirectory: work.path,
            compileResult: compiled,
            binaryConfig: const SimulatorBinaryConfig(simulatorId: 'nextpnr'),
          ),
        ),
      );
      expect(finished.metrics[FlowMetricKeys.verdict], 'stopped');
      expect(recorder.spawns, isEmpty);
    });

    test('cancel during place and route terminates the tree', () async {
      final process = FakeFlowProcess(hang: true);
      final recorder = FlowSpawnRecorder(onSpawn: (_) => process);
      final reaper = RecordingReaper(recorder.launch);
      final d = NextpnrFlowDriver(
        reaper: reaper,
        killGrace: const Duration(milliseconds: 10),
        yosysRunnerFor: (_) => FakeYosysRunner(
          const YosysRunSuccess(rawJson: '{}', stdout: '', stderr: ''),
        ),
      );
      final spec = specFor(entry());
      const binary = SimulatorBinaryConfig(simulatorId: 'nextpnr');
      final compiled = await d.compile(
        CompileRequest(
          test: spec,
          workingDirectory: work.path,
          binaryConfig: binary,
        ),
      );
      final done = finishedOf(
        d.execute(
          ExecuteRequest(
            test: spec,
            workingDirectory: work.path,
            compileResult: compiled,
            binaryConfig: binary,
          ),
        ),
      );
      while (recorder.spawns.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      // Let the driver register the live process before cancelling it.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      d.cancel(spec.id);
      final finished = await done;
      expect(reaper.terminated, hasLength(1));
      expect(process.signals, isNotEmpty);
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
    });
  });

  test('a FuseSoC entry runs fusesoc and reads the log Edalize left', () async {
    final recorder = FlowSpawnRecorder(
      onSpawn: (spawn) {
        // Plays Edalize: a build tree with nextpnr's log and no report.
        final buildRoot = spawn.args[spawn.args.indexOf('--build-root') + 1];
        final dir = Directory(
          p.join(buildRoot, 'servant_1.4.0', 'icebreaker-icestorm'),
        )..createSync(recursive: true);
        File(
          'verification/fixtures/flow/fusesoc/build/next.log',
        ).copySync(p.join(dir.path, 'next.log'));
        return FakeFlowProcess();
      },
    );
    final finished = await runOnce(
      driver(recorder),
      specFor(
        entry(
          fusesoc: const FlowFusesocConfig(
            core: 'award-winning:serv:servant',
            target: 'icebreaker',
          ),
        ),
      ),
    );
    final spawn = recorder.spawns.single;
    expect(spawn.executable, 'fusesoc');
    expect(spawn.args.first, 'run');
    expect(spawn.args, contains('--target=icebreaker'));
    expect(spawn.args.last, 'award-winning:serv:servant');
    expect(spawn.cwd, project.resolveSymbolicLinksSync());
    expect(finished.metrics[FlowMetricKeys.reader], FlowReaderIds.nextpnrLog);
    expect(finished.metrics[FlowMetricKeys.verdict], 'met');
  });

  test('detectVersion asks one nextpnr binary for its version', () async {
    final recorder = FlowSpawnRecorder(
      onSpawn: (_) => FakeFlowProcess(stdoutLines: const ['nextpnr-ice40 0.9']),
    );
    final version = await driver(recorder).detectVersion(
      const SimulatorBinaryConfig(simulatorId: 'nextpnr'),
    );
    expect(version, 'nextpnr-ice40 0.9');
    expect(recorder.spawns.single.args, ['--version']);
  });
}
