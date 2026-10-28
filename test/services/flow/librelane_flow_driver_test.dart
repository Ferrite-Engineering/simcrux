// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/domain/models/flow_tool_settings.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/librelane_flow_driver.dart';

import 'flow_fakes.dart';
import 'librelane_run_builder.dart';

/// The LibreLane driver against scripted processes and hand-built run
/// directories: no LibreLane is installed, so a fake plays it, writing the
/// run directory the plan's contract documents. The verdict comes from those
/// records, never from the exit code.
void main() {
  late Directory project;
  late Directory work;
  late String design;

  setUp(() {
    project = Directory.systemTemp.createTempSync('flow_ll_proj_');
    work = Directory.systemTemp.createTempSync('flow_ll_work_');
    design = p.join(project.resolveSymbolicLinksSync(), 'librelane');
    Directory(design).createSync();
    File(p.join(design, 'config.yaml')).writeAsStringSync('DESIGN_NAME: c\n');
  });
  tearDown(() {
    project.deleteSync(recursive: true);
    work.deleteSync(recursive: true);
  });

  FlowEntry entry({
    FlowLauncher? launcher,
    String? config,
    String? pdk = 'sky130A',
  }) => FlowEntry(
    name: 'counter',
    kind: FlowKind.librelane,
    config: config ?? p.join(design, 'config.yaml'),
    launcher: launcher,
    pdk: pdk,
    projectRoot: project.resolveSymbolicLinksSync(),
  );

  TestSpec specFor(FlowEntry e) => const FlowRunImporter().specFor(e);

  SimulatorBinaryConfig binary({
    FlowToolSettings settings = const FlowToolSettings(),
    String? customPath,
  }) => SimulatorBinaryConfig(
    simulatorId: 'librelane',
    source: customPath == null
        ? SimulatorBinarySource.system
        : SimulatorBinarySource.custom,
    customPath: customPath,
    options: settings.toOptions(),
  );

  LibreLaneFlowDriver driver(FlowSpawnRecorder recorder) => LibreLaneFlowDriver(
    launcher: recorder.launch,
    clock: () => DateTime.utc(2026, 10, 21, 12),
    pollInterval: const Duration(milliseconds: 5),
    hostEnvironment: const <String, String>{},
    dockerUser: () => null,
  );

  /// Plays LibreLane: builds the run directory `--run-tag` names, then
  /// exits with [exit].
  FakeFlowProcess Function(FlowSpawn) librelaneWriting(
    void Function(LibreLaneRunBuilder run) build, {
    int exit = 0,
  }) => (spawn) {
    final tag = spawn.args[spawn.args.indexOf('--run-tag') + 1];
    build(LibreLaneRunBuilder(design, tag: tag));
    return FakeFlowProcess(exit: exit);
  };

  Future<TestExecutionFinished> run(
    LibreLaneFlowDriver d,
    TestSpec spec, {
    SimulatorBinaryConfig? config,
  }) => finishedOf(
    d.execute(
      ExecuteRequest(
        test: spec,
        workingDirectory: work.path,
        compileResult: null,
        binaryConfig: config ?? binary(),
      ),
    ),
  );

  group('verdict from the run records, never the exit code', () {
    test('non-zero exit with complete metrics showing violations is '
        'violated', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: librelaneWriting(
          (r) => r
            ..step('yosys-synthesis')
            ..step('openroad-stapostpnr')
            ..finalMetrics(<String, Object?>{
              ...cleanMetrics,
              'route__drc_errors': 3,
            }),
          exit: 2,
        ),
      );
      final finished = await run(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'violated');
      expect(finished.status, TestStatus.fail);
      expect(finished.metrics[FlowMetricKeys.processExitCode], '2');
      // The run states LibreLane 3.0.16, a release the 3.0 reader is
      // verified for.
      expect(finished.metrics[FlowMetricKeys.readerVerified], 'true');
      expect(finished.metrics[FlowMetricKeys.reader], FlowReaderIds.librelane);
    });

    test('a run that ends without final metrics is stopped', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: librelaneWriting(
          (r) => r
            ..step('yosys-synthesis')
            ..step('openroad-globalplacement', complete: false),
          exit: 1,
        ),
      );
      final finished = await run(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'stopped');
      expect(
        finished.metrics[FlowMetricKeys.stoppedStep],
        'openroad-globalplacement',
      );
    });

    test('exit 0 with clean metrics is met', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: librelaneWriting(
          (r) => r
            ..step('yosys-synthesis')
            ..finalMetrics(cleanMetrics),
        ),
      );
      final finished = await run(driver(recorder), specFor(entry()));
      expect(finished.metrics[FlowMetricKeys.verdict], 'met');
      expect(finished.status, TestStatus.pass);
      expect(finished.metrics[FlowMetricKeys.target], 'sky130');
    });
  });

  group('the command line', () {
    test('path launcher: --pdk-root, --pdk, --run-tag, then the config; '
        'never --overwrite or --last-run', () async {
      final recorder = FlowSpawnRecorder(
        onSpawn: librelaneWriting((r) => r.finalMetrics(cleanMetrics)),
      );
      await run(
        driver(recorder),
        specFor(entry()),
        config: binary(settings: const FlowToolSettings(pdkRoot: '/pdks')),
      );
      final spawn = recorder.spawns.single;
      expect(spawn.executable, 'librelane');
      expect(spawn.args, <String>[
        '--pdk-root',
        '/pdks',
        '--pdk',
        'sky130A',
        '--run-tag',
        'simcrux-20261021T120000Z',
        p.join(design, 'config.yaml'),
      ]);
      expect(spawn.args, isNot(contains('--overwrite')));
      expect(spawn.args, isNot(contains('--last-run')));
      expect(spawn.cwd, design);
      expect(spawn.environment?['PDK_ROOT'], '/pdks');
    });

    test('a tag whose run directory exists is never reused', () async {
      Directory(
        p.join(design, 'runs', 'simcrux-20261021T120000Z'),
      ).createSync(recursive: true);
      final recorder = FlowSpawnRecorder(
        onSpawn: librelaneWriting((r) => r.finalMetrics(cleanMetrics)),
      );
      final finished = await run(driver(recorder), specFor(entry()));
      expect(
        recorder.spawns.single.args,
        contains('simcrux-20261021T120000Z-2'),
      );
      expect(
        finished.metrics[FlowMetricKeys.runDir],
        p.join(design, 'runs', 'simcrux-20261021T120000Z-2'),
      );
    });

    test('nix launcher runs librelane in the checkout Settings names', () {
      final checkout = Directory(p.join(work.path, 'librelane-src'))
        ..createSync();
      final prepared = driver(FlowSpawnRecorder()).prepare(
        entry(),
        binary(
          settings: const FlowToolSettings(launcher: FlowLauncher.nix),
          customPath: checkout.path,
        ),
      );
      expect(prepared.invocation!.argv.take(5), <String>[
        'nix',
        'develop',
        checkout.path,
        '--command',
        'librelane',
      ]);
    });

    test(
      'nix launcher without a checkout is refused before spawning',
      () async {
        final recorder = FlowSpawnRecorder();
        final finished = await run(
          driver(recorder),
          specFor(entry()),
          config: binary(
            settings: const FlowToolSettings(launcher: FlowLauncher.nix),
          ),
        );
        expect(recorder.spawns, isEmpty);
        expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
        expect(finished.metrics[FlowDriverMetricKeys.toolMissing], 'nix');
      },
    );

    test('docker launcher names its container and mounts only the design '
        'and the PDK root', () {
      final prepared = driver(FlowSpawnRecorder()).prepare(
        entry(),
        binary(
          settings: const FlowToolSettings(
            launcher: FlowLauncher.docker,
            dockerImage: 'example/librelane:3.0',
            pdkRoot: '/pdks',
          ),
        ),
      );
      final argv = prepared.invocation!.argv;
      expect(argv.take(5), [
        'docker',
        'run',
        '--rm',
        '--name',
        'simcrux-simcrux-20261021T120000Z',
      ]);
      expect(argv, containsAllInOrder(['-v', '$design:$design']));
      expect(argv, containsAllInOrder(['-v', '/pdks:/pdks']));
      expect(argv, contains('example/librelane:3.0'));
      expect(
        prepared.invocation!.container,
        'simcrux-simcrux-20261021T120000Z',
      );
    });

    // A container run without the host's PDK root fetched the PDK into the
    // container, which `--rm` then threw away; and as root on Linux it left
    // a run directory the user could not delete.
    group('docker launcher, the PDK root and the user', () {
      const docker = FlowToolSettings(
        launcher: FlowLauncher.docker,
        dockerImage: 'example/librelane:3.0',
      );

      List<String> argvWith(
        Map<String, String> host, {
        String? user,
        FlowToolSettings settings = docker,
      }) => LibreLaneFlowDriver(
        clock: () => DateTime.utc(2026, 10, 21, 12),
        hostEnvironment: host,
        dockerUser: () => user,
      ).prepare(entry(), binary(settings: settings)).invocation!.argv;

      test('the host PDK_ROOT is mounted when Settings names none', () {
        final root = p.join(work.path, 'pdks');
        final argv = argvWith(<String, String>{'PDK_ROOT': root});
        expect(argv, containsAllInOrder(['-v', '$root:$root']));
        expect(argv, containsAllInOrder(['-e', 'PDK_ROOT=$root']));
      });

      test("else LibreLane's default, ~/.ciel, created when missing", () {
        final home = p.join(work.path, 'home');
        final ciel = p.join(home, '.ciel');
        final argv = argvWith(<String, String>{'HOME': home});
        expect(argv, containsAllInOrder(['-v', '$ciel:$ciel']));
        expect(argv, containsAllInOrder(['-e', 'PDK_ROOT=$ciel']));
        expect(Directory(ciel).existsSync(), isTrue);
      });

      test('the Settings PDK root outranks the host one', () {
        final argv = argvWith(
          <String, String>{'PDK_ROOT': p.join(work.path, 'other')},
          settings: FlowToolSettings(
            launcher: FlowLauncher.docker,
            dockerImage: 'example/librelane:3.0',
            pdkRoot: p.join(work.path, 'pdks'),
          ),
        );
        final root = p.join(work.path, 'pdks');
        expect(argv, containsAllInOrder(['-e', 'PDK_ROOT=$root']));
        expect(argv.where((a) => a.contains('other')), isEmpty);
      });

      test('--user runs the container as the host user, before the image', () {
        final argv = argvWith(const <String, String>{}, user: '1001:118');
        expect(argv, containsAllInOrder(['--user', '1001:118']));
        expect(
          argv.indexOf('--user'),
          lessThan(argv.indexOf('example/librelane:3.0')),
        );
        expect(argvWith(const <String, String>{}), isNot(contains('--user')));
      });

      test('the host user on Linux is UID:GID, and none elsewhere', () {
        final user = LibreLaneFlowDriver.hostDockerUser();
        if (Platform.isLinux) {
          expect(user, matches(RegExp(r'^\d+:\d+$')));
          final uid = (Process.runSync('id', ['-u']).stdout as String).trim();
          expect(user!.split(':').first, uid);
        } else {
          expect(user, isNull);
        }
      });
    });

    test('docker launcher without an image is refused', () {
      final prepared = driver(FlowSpawnRecorder()).prepare(
        entry(),
        binary(settings: const FlowToolSettings(launcher: FlowLauncher.docker)),
      );
      expect(prepared.invocation, isNull);
      expect(prepared.toolMissing, 'docker');
    });

    test('a project launcher (under consent) outranks Settings', () {
      final prepared = driver(FlowSpawnRecorder()).prepare(
        entry(launcher: FlowLauncher.path),
        binary(settings: const FlowToolSettings(launcher: FlowLauncher.docker)),
      );
      expect(prepared.invocation!.launcher, FlowLauncher.path);
    });
  });

  group('containment', () {
    test(
      'a configuration outside the project is refused; nothing runs',
      () async {
        final outside = Directory.systemTemp.createTempSync('flow_ll_out_');
        addTearDown(() => outside.deleteSync(recursive: true));
        File(p.join(outside.path, 'config.yaml')).writeAsStringSync('x: 1\n');
        final recorder = FlowSpawnRecorder();
        final finished = await run(
          driver(recorder),
          specFor(entry(config: p.join(outside.path, 'config.yaml'))),
        );
        expect(recorder.spawns, isEmpty);
        expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
      },
    );

    test('a runs directory that links out of the project is refused', () async {
      final outside = Directory.systemTemp.createTempSync('flow_ll_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      Link(p.join(design, 'runs')).createSync(outside.path);
      final recorder = FlowSpawnRecorder();
      final finished = await run(driver(recorder), specFor(entry()));
      expect(recorder.spawns, isEmpty);
      expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
    }, testOn: '!windows');

    test('a configuration path with NUL is refused', () {
      final prepared = driver(FlowSpawnRecorder()).prepare(
        entry(config: '${p.join(design, 'config.yaml')}\x00x'),
        binary(),
      );
      expect(prepared.invocation, isNull);
    });
  });

  test('XDG_DATA_HOME is set to a per-job directory when absent', () async {
    final recorder = FlowSpawnRecorder(
      onSpawn: librelaneWriting((r) => r.finalMetrics(cleanMetrics)),
    );
    await run(driver(recorder), specFor(entry()));
    expect(
      recorder.spawns.single.environment?['XDG_DATA_HOME'],
      p.join(work.path, 'xdg'),
    );
  });

  test('progress reports each new step directory once', () async {
    final recorder = FlowSpawnRecorder(
      onSpawn: librelaneWriting(
        (r) => r
          ..step('yosys-synthesis')
          ..step('openroad-floorplan')
          ..finalMetrics(cleanMetrics),
      ),
    );
    final lines = <String>[];
    await for (final event in driver(recorder).execute(
      ExecuteRequest(
        test: specFor(entry()),
        workingDirectory: work.path,
        compileResult: null,
        binaryConfig: binary(),
      ),
    )) {
      if (event is TestLogLine) lines.add(event.line);
    }
    expect(lines.where((l) => l.startsWith('librelane: step')).toList(), [
      'librelane: step 01-yosys-synthesis',
      'librelane: step 02-openroad-floorplan',
    ]);
  });

  test('a missing librelane is notRun and names it', () async {
    final finished = await run(
      driver(FlowSpawnRecorder(missing: const {'librelane'})),
      specFor(entry()),
    );
    expect(finished.metrics[FlowMetricKeys.verdict], 'not_run');
    expect(finished.metrics[FlowDriverMetricKeys.toolMissing], 'librelane');
  });

  group('cancel', () {
    test('kills the whole tree through the reaper', () async {
      final process = FakeFlowProcess(hang: true);
      final recorder = FlowSpawnRecorder(onSpawn: (_) => process);
      final reaper = RecordingReaper(recorder.launch);
      final d = LibreLaneFlowDriver(
        reaper: reaper,
        killGrace: const Duration(milliseconds: 10),
        hostEnvironment: const <String, String>{},
      );
      final spec = specFor(entry());
      final done = run(d, spec);
      while (recorder.spawns.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      d.cancel(spec.id);
      final finished = await done;
      expect(reaper.terminated, hasLength(1));
      expect(process.signals, isNotEmpty);
      expect(finished.metrics[FlowMetricKeys.verdict], isNot('met'));
    });

    test('the docker launcher also stops its container', () async {
      final process = FakeFlowProcess(hang: true);
      final recorder = FlowSpawnRecorder(
        onSpawn: (spawn) =>
            spawn.args.firstOrNull == 'stop' ? FakeFlowProcess() : process,
      );
      final d = driver(recorder);
      final spec = specFor(entry());
      final done = run(
        d,
        spec,
        config: binary(
          settings: const FlowToolSettings(
            launcher: FlowLauncher.docker,
            dockerImage: 'example/librelane:3.0',
          ),
        ),
      );
      while (recorder.spawns.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      d.cancel(spec.id);
      await done;
      final stop = recorder.spawns.firstWhere((s) => s.args.first == 'stop');
      expect(stop.executable, 'docker');
      expect(stop.args.last, 'simcrux-simcrux-20261021T120000Z');
    });
  });

  test('detectVersion never spawns nix or docker', () async {
    final recorder = FlowSpawnRecorder();
    final d = driver(recorder);
    for (final launcher in [FlowLauncher.nix, FlowLauncher.docker]) {
      expect(
        await d.detectVersion(
          binary(settings: FlowToolSettings(launcher: launcher)),
        ),
        isNull,
      );
    }
    expect(recorder.spawns, isEmpty);
  });
}
