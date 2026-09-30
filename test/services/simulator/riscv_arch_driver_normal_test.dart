// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

// `mode: normal` and `mode: riscof_passthrough`, driven against a scripted
// launcher so no RISC-V toolchain is needed to test the argv construction,
// the two-spawn compile stage, the traceback reduction and the
// missing-binary guidance.
//
// The comparison TAIL is identical to demo mode's and is covered there,
// end to end through the real scheduler. What is asserted here is the part
// demo mode skips: the spawns.

class _FakeProcess implements TestProcess {
  _FakeProcess({this.stderrLines = const <String>[], this.exit = 0});

  static const List<String> stdoutLines = <String>[];
  final List<String> stderrLines;
  final int exit;

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => Stream<String>.fromIterable(stderrLines);

  @override
  Future<int> get exitCode async => exit;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Recorder {
  _Recorder({
    this.processes = const <String, _FakeProcess>{},
    this.onSpawn,
    this.missing = const <String>{},
  });

  /// Executable basename → scripted process.
  final Map<String, _FakeProcess> processes;
  final void Function(String executable, List<String> args)? onSpawn;
  final Set<String> missing;

  final List<({String executable, List<String> args})> spawns = [];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    spawns.add((executable: executable, args: args));
    onSpawn?.call(executable, args);
    if (missing.contains(p.basename(executable))) {
      throw ProcessException(executable, args, 'No such file or directory', 2);
    }
    return processes[p.basename(executable)] ?? _FakeProcess();
  }
}

void main() {
  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('simcrux_riscv_normal_');
  });

  tearDown(() {
    if (workDir.existsSync()) workDir.deleteSync(recursive: true);
  });

  const signature = 'deadbeef\n0000000f\n12345678\ncafebabe\n';

  RiscvConfig normalConfig({List<String>? targetCommand}) => RiscvConfig(
    isa: 'rv32imc',
    testPath: 'rv32i_m/I/src/add-01.S',
    archTest: const RiscvArchTestConfig(
      suitePath: '/checkout/riscv-test-suite',
      revision: 'abc1234',
    ),
    compile: const RiscvCompileConfig(
      linkScript: '/checkout/env/link.ld',
      includeDirs: ['/checkout/env'],
    ),
    target: RiscvTargetConfig(
      command:
          targetCommand ??
          const ['./mycore', '--elf', '{elf}', '--signature', '{signature}'],
    ),
    extension: 'I',
  );

  TestSpec specFor(RiscvConfig cfg) => TestSpec(
    id: 'arch/add-01',
    name: 'add-01',
    suiteName: 'arch',
    simulatorId: RiscvArchDriver.kId,
    top: 'add-01',
    riscv: cfg,
  );

  CompileRequest compileRequest(RiscvConfig cfg) => CompileRequest(
    test: specFor(cfg),
    workingDirectory: workDir.path,
    binaryConfig: const SimulatorBinaryConfig(
      simulatorId: RiscvArchDriver.kId,
    ),
  );

  ExecuteRequest executeRequest(RiscvConfig cfg) => ExecuteRequest(
    test: specFor(cfg),
    workingDirectory: workDir.path,
    compileResult: null,
    binaryConfig: const SimulatorBinaryConfig(
      simulatorId: RiscvArchDriver.kId,
    ),
  );

  group('identity', () {
    test('claims the bare `riscv_arch` id and declares no HDL languages', () {
      final driver = RiscvArchDriver();
      expect(driver.id, 'riscv_arch');
      // It cross-compiles RISC-V assembly, not HDL. Declaring an HDL
      // language here would be a lie about what the driver does.
      expect(driver.capabilities.supportedLanguages, isEmpty);
      expect(driver.capabilities.requiresSeparateCompileStep, isTrue);
    });
  });

  group('compile stage — cross-compile, then the reference model', () {
    test(
      'spawns the compiler and then the reference model, in order',
      () async {
        final recorder = _Recorder(
          onSpawn: (executable, args) {
            // The compiler is expected to produce the ELF; fake it so the
            // existence check passes and the reference run is reached.
            if (executable.endsWith('gcc')) {
              File(
                p.join(workDir.path, RiscvArchDriver.kElfName),
              ).writeAsStringSync('elf');
            }
          },
        );
        final driver = RiscvArchDriver(launcher: recorder.launch);
        final result = await driver.compile(compileRequest(normalConfig()));
        expect(result.success, isTrue);
        expect(recorder.spawns, hasLength(2));
        expect(recorder.spawns.first.executable, endsWith('gcc'));
        expect(recorder.spawns.last.executable, 'spike');
      },
    );

    test('derives the gcc command line from the riscv block', () async {
      final recorder = _Recorder(
        onSpawn: (executable, args) {
          if (executable.endsWith('gcc')) {
            File(
              p.join(workDir.path, RiscvArchDriver.kElfName),
            ).writeAsStringSync('elf');
          }
        },
      );
      await RiscvArchDriver(
        launcher: recorder.launch,
      ).compile(compileRequest(normalConfig()));
      final args = recorder.spawns.first.args;
      expect(args, contains('-march=rv32imc'));
      expect(args, contains('-mabi=ilp32'));
      expect(args, contains('-nostdlib'));
      expect(args, contains('-T'));
      expect(args, contains('/checkout/env/link.ld'));
      expect(args, contains('-I/checkout/env'));
      // The test source is resolved against arch_test.suite_path, so the
      // spawn does not depend on the process cwd.
      //
      // Matched with p.equals rather than string containment: this is the one
      // argument the driver JOINS (suite_path + the relative test path), so on
      // Windows it comes back separator-native while the configured values
      // above pass through verbatim. What matters is that it resolved against
      // suite_path, not which slash the host spells it with.
      expect(
        args.any(
          (a) =>
              p.equals(a, '/checkout/riscv-test-suite/rv32i_m/I/src/add-01.S'),
        ),
        isTrue,
        reason: 'test source must resolve against suite_path; got $args',
      );
    });

    test(
      'the reference model gets the conventional Spike invocation',
      () async {
        final recorder = _Recorder(
          onSpawn: (executable, args) {
            if (executable.endsWith('gcc')) {
              File(
                p.join(workDir.path, RiscvArchDriver.kElfName),
              ).writeAsStringSync('elf');
            }
          },
        );
        await RiscvArchDriver(
          launcher: recorder.launch,
        ).compile(compileRequest(normalConfig()));
        final args = recorder.spawns.last.args;
        expect(args, contains('--isa=rv32imc'));
        expect(args.any((a) => a.startsWith('+signature=')), isTrue);
        expect(args, contains('+signature-granularity=4'));
        expect(args.last, endsWith(RiscvArchDriver.kElfName));
      },
    );

    test('a Sail reference model gets --test-signature instead', () async {
      final recorder = _Recorder(
        onSpawn: (executable, args) {
          if (executable.endsWith('gcc')) {
            File(
              p.join(workDir.path, RiscvArchDriver.kElfName),
            ).writeAsStringSync('elf');
          }
        },
      );
      final cfg = normalConfig().copyWith(
        reference: const RiscvReferenceConfig(model: RiscvReferenceModel.sail),
      );
      await RiscvArchDriver(
        launcher: recorder.launch,
      ).compile(compileRequest(cfg));
      expect(recorder.spawns.last.executable, 'riscv_sim_RV32');
      expect(recorder.spawns.last.args, contains('--test-signature'));
    });

    test(
      'a compiler that exits 0 but writes no ELF fails the compile',
      () async {
        final recorder = _Recorder();
        final result = await RiscvArchDriver(
          launcher: recorder.launch,
        ).compile(compileRequest(normalConfig()));
        expect(result.success, isFalse);
        expect(result.stderr, contains('produced no test.elf'));
        // The reference model is never reached.
        expect(recorder.spawns, hasLength(1));
      },
    );

    test('a missing cross-compiler surfaces ACTIONABLE guidance', () async {
      final recorder = _Recorder(missing: {'riscv32-unknown-elf-gcc'});
      final driver = RiscvArchDriver(launcher: recorder.launch);
      // The exception is what the scheduler renders as log lines; the
      // per-component, per-platform remediation went into the compile
      // stderr capture, which the scheduler replays into the inspector.
      await expectLater(
        driver.compile(compileRequest(normalConfig())),
        throwsA(
          isA<SimulatorNotAvailableException>().having(
            (e) => e.simulatorId,
            'simulatorId',
            'riscv_arch',
          ),
        ),
      );
    });

    test('demo mode never reaches the compiler', () async {
      final recorder = _Recorder();
      await RiscvArchDriver(launcher: recorder.launch).compile(
        compileRequest(
          const RiscvConfig(
            mode: RiscvRunMode.demo,
            demoSignatures: 'verification/fixtures/golden_compare',
            demoCase: 'clean_pass',
          ),
        ),
      );
      expect(recorder.spawns, isEmpty);
    });

    test('riscof passthrough has no compile stage at all', () async {
      final recorder = _Recorder();
      final result = await RiscvArchDriver(launcher: recorder.launch).compile(
        compileRequest(
          const RiscvConfig(
            mode: RiscvRunMode.riscofPassthrough,
            riscof: RiscvRiscofConfig(command: ['riscof', 'run']),
          ),
        ),
      );
      expect(result.success, isTrue);
      expect(recorder.spawns, isEmpty);
      expect(result.stdout, contains('riscof_passthrough'));
    });
  });

  group('execute stage', () {
    Future<TestExecutionFinished> execute(
      RiscvArchDriver driver,
      RiscvConfig cfg,
    ) async {
      final events = await driver.execute(executeRequest(cfg)).toList();
      return events.whereType<TestExecutionFinished>().single;
    }

    test('expands {elf} and {signature} in the target command', () async {
      final recorder = _Recorder();
      final driver = RiscvArchDriver(launcher: recorder.launch);
      await execute(driver, normalConfig());
      final spawn = recorder.spawns.single;
      expect(spawn.executable, './mycore');
      expect(
        spawn.args,
        contains(p.join(workDir.path, RiscvArchDriver.kElfName)),
      );
      expect(
        spawn.args,
        contains(p.join(workDir.path, 'signature.dut.sig')),
      );
    });

    test('an unknown placeholder stays verbatim, not blanked', () async {
      final recorder = _Recorder();
      await execute(
        RiscvArchDriver(launcher: recorder.launch),
        normalConfig(targetCommand: ['./mycore', '{typo}']),
      );
      expect(recorder.spawns.single.args, contains('{typo}'));
    });

    test('the passthrough mode spawns the configured RISCOF command', () async {
      final recorder = _Recorder();
      await execute(
        RiscvArchDriver(launcher: recorder.launch),
        const RiscvConfig(
          mode: RiscvRunMode.riscofPassthrough,
          riscof: RiscvRiscofConfig(
            command: ['riscof', 'run', '--testfile={test}'],
          ),
          testPath: '/abs/add-01.S',
        ),
      );
      expect(recorder.spawns.single.executable, 'riscof');
      expect(
        recorder.spawns.single.args,
        contains('--testfile=/abs/add-01.S'),
      );
    });

    test('a Python traceback is reduced to one dashboard line', () async {
      // Never surface a raw traceback. The full trace still reaches
      // the stream as TestLogLine events and the retained stderr log.
      final recorder = _Recorder(
        processes: {
          'riscof': _FakeProcess(
            exit: 1,
            stderrLines: const [
              'Traceback (most recent call last):',
              '  File "/venv/bin/riscof", line 8, in <module>',
              '    sys.exit(cli())',
              "FileNotFoundError: [Errno 2] No such file: '/opt/riscv/spike'",
            ],
          ),
        },
      );
      final driver = RiscvArchDriver(launcher: recorder.launch);
      final events = await driver
          .execute(
            executeRequest(
              const RiscvConfig(
                mode: RiscvRunMode.riscofPassthrough,
                riscof: RiscvRiscofConfig(command: ['riscof', 'run']),
              ),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.failureMessage, startsWith('FileNotFoundError:'));
      expect(finished.failureMessage, isNot(contains('Traceback')));
      expect(finished.failureMessage, isNot(contains('\n')));
      // …and the whole trace is still on the stream, one click away.
      final logLines = events.whereType<TestLogLine>().map((e) => e.line);
      expect(logLines, contains('Traceback (most recent call last):'));
      expect(logLines, contains('    sys.exit(cli())'));
    });

    test('a DUT that exits 0 with no signature fails, never passes', () async {
      // The exit-0 trap on the normal path: no signature, clean exit.
      final finished = await execute(
        RiscvArchDriver(launcher: _Recorder().launch),
        normalConfig(),
      );
      expect(finished.status, TestStatus.fail);
      expect(finished.status, isNot(TestStatus.unknown));
      expect(finished.status, isNot(TestStatus.vacuous));
    });

    test('a non-zero exit fails even when the signatures agree', () async {
      // A core that crashed after writing a correct prefix is not
      // compatible.
      File(p.join(workDir.path, 'signature.dut.sig')).writeAsStringSync(
        signature,
      );
      File(p.join(workDir.path, 'signature.ref.sig')).writeAsStringSync(
        signature,
      );
      final finished = await execute(
        RiscvArchDriver(
          launcher: _Recorder(
            processes: {'mycore': _FakeProcess(exit: 3)},
          ).launch,
        ),
        normalConfig(),
      );
      expect(finished.status, TestStatus.fail);
      expect(finished.exitCode, 3);
      expect(finished.failureMessage, contains('exited 3'));
    });

    test(
      'matching signatures and a clean exit pass, with provenance',
      () async {
        File(p.join(workDir.path, 'signature.dut.sig')).writeAsStringSync(
          signature,
        );
        File(p.join(workDir.path, 'signature.ref.sig')).writeAsStringSync(
          signature,
        );
        final finished = await execute(
          RiscvArchDriver(launcher: _Recorder().launch),
          normalConfig(),
        );
        expect(finished.status, TestStatus.pass);
        expect(finished.metrics[RiscvArchDriver.kMetricMode], 'normal');
        expect(
          finished.metrics[RiscvArchDriver.kMetricReferenceModel],
          'spike',
        );
        // Provenance is the feature of the Pro compatibility report: what was
        // run, with what versions, against what suite revision.
        expect(
          finished.metrics[RiscvArchDriver.kMetricArchTestRevision],
          'abc1234',
        );
        expect(finished.metrics[RiscvArchDriver.kMetricExtension], 'I');
      },
    );

    test(
      'a config the loader would refuse fails loudly, not silently',
      () async {
        final finished = await execute(
          RiscvArchDriver(launcher: _Recorder().launch),
          const RiscvConfig(),
        );
        expect(finished.status, TestStatus.fail);
        expect(finished.failureMessage, contains('riscv.target.command'));
      },
    );
  });

  group('detectVersion', () {
    test('returns a summary line, never throws', () async {
      // Four independent dependencies collapsed into the one `String?` the
      // interface offers. Probes $PATH — there is no project config at
      // diagnostics time.
      final driver = RiscvArchDriver(
        launcher: _Recorder(
          missing: const {
            'riscv32-unknown-elf-gcc',
            'spike',
            'riscof',
            'sby',
          },
        ).launch,
      );
      expect(
        await driver.detectVersion(
          const SimulatorBinaryConfig(simulatorId: RiscvArchDriver.kId),
        ),
        isNull,
      );
    });
  });
}
