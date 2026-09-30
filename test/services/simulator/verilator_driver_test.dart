// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

import '../../support/poll_until.dart';

class _FakeProcess implements TestProcess {
  _FakeProcess({
    this.stdoutLines = const <String>[],
    this.stderrLines = const <String>[],
    this.exit = 0,
    this.hangForever = false,
  });

  final List<String> stdoutLines;
  final List<String> stderrLines;
  final int exit;
  final bool hangForever;

  final Completer<int> _exitCompleter = Completer<int>();
  bool killed = false;
  ProcessSignal? killSignal;

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => Stream<String>.fromIterable(stderrLines);

  @override
  Future<int> get exitCode async {
    if (_exitCompleter.isCompleted) return await _exitCompleter.future;
    if (!hangForever) _exitCompleter.complete(exit);
    return await _exitCompleter.future;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    killSignal = signal;
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-15);
    return true;
  }
}

class _LaunchCall {
  _LaunchCall({
    required this.executable,
    required this.args,
    required this.workingDirectory,
  });
  final String executable;
  final List<String> args;
  final String? workingDirectory;
}

class _Recorder {
  _Recorder(this._factories);
  final Map<String, _FakeProcess Function()> _factories;
  final List<_LaunchCall> calls = <_LaunchCall>[];

  Future<TestProcess> launch(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) async {
    calls.add(
      _LaunchCall(
        executable: executable,
        args: List<String>.unmodifiable(args),
        workingDirectory: workingDirectory,
      ),
    );
    final factory = _factories[executable];
    if (factory == null) {
      throw ProcessException(executable, args, 'no such factory', -1);
    }
    return factory();
  }
}

TestSpec _spec({
  String id = 'unit/alu',
  String top = 'tb_alu',
  List<String> sources = const ['rtl/alu.sv', 'tb/alu_tb.sv'],
  WaveformPolicy waveform = const WaveformPolicy(),
}) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'verilator',
    top: top,
    sources: sources,
    waveform: waveform,
  );
}

Future<TestProcess> _missingBinary(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  throw ProcessException(executable, args, 'no such file', -1);
}

void main() {
  group('VerilatorDriver', () {
    test('id, displayName, and capabilities are reasonable', () {
      final driver = VerilatorDriver();
      expect(driver.id, 'verilator');
      expect(driver.displayName, 'Verilator');
      expect(driver.capabilities.requiresSeparateCompileStep, isTrue);
      expect(driver.capabilities.supportsFst, isTrue);
      expect(driver.capabilities.supportsVcd, isTrue);
    });

    test('detectVersion returns first non-empty banner on stdout', () async {
      final recorder = _Recorder({
        'verilator': () => _FakeProcess(
          stdoutLines: const <String>[
            'Verilator 5.022 2024-09-08 rev v5.022',
          ],
        ),
      });
      final driver = VerilatorDriver(launcher: recorder.launch);
      final version = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'verilator'),
      );
      expect(version, 'Verilator 5.022 2024-09-08 rev v5.022');
      expect(recorder.calls.single.args, <String>['--version']);
    });

    test('detectVersion returns null on missing binary', () async {
      final driver = VerilatorDriver(launcher: _missingBinary);
      expect(
        await driver.detectVersion(
          const SimulatorBinaryConfig(simulatorId: 'verilator'),
        ),
        isNull,
      );
    });

    test(
      'compile launches verilator with expected args and captures lint',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'simcrux_verilator_compile_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final wd = tempDir.path;
        // Create the obj_dir + artifact so compile() decides the build
        // succeeded.
        Directory(p.join(wd, 'obj_dir')).createSync(recursive: true);
        File(p.join(wd, 'obj_dir', 'Vtb_alu')).writeAsStringSync('fake');

        final recorder = _Recorder({
          'verilator': () => _FakeProcess(
            stdoutLines: const <String>[
              'verilator: compiling',
            ],
            stderrLines: const <String>[
              '%Warning-WIDTH: rtl/alu.sv:42:7: Bit extraction of foo requires 32 bits, 33 bits given',
              '%Warning-UNUSED: Signal bar is unused',
            ],
          ),
        });
        final driver = VerilatorDriver(launcher: recorder.launch);
        final result = await driver.compile(
          CompileRequest(
            test: _spec(),
            workingDirectory: wd,
            binaryConfig: const SimulatorBinaryConfig(simulatorId: 'verilator'),
          ),
        );
        expect(result.success, isTrue);
        expect(result.artifactPath, p.join(wd, 'obj_dir', 'Vtb_alu'));
        final compileCall = recorder.calls.singleWhere(
          (c) => !c.args.contains('--version'),
        );
        expect(compileCall.executable, 'verilator');
        final args = compileCall.args;
        expect(args, contains('--cc'));
        expect(args, contains('--build'));
        expect(args, contains('--top-module'));
        expect(args, contains('tb_alu'));
        expect(args, contains('-Wall'));
        // Warnings are reported, never fatal.
        expect(args, contains('-Wno-fatal'));
        // The banner above is not a version line, so no --timing.
        expect(args, isNot(contains('--timing')));
        // Default waveform policy is on_failure / fst → --trace-fst expected.
        expect(args, contains('--trace-fst'));
        // sim_main.cpp shim is written for --exe mode.
        expect(File(p.join(wd, 'sim_main.cpp')).existsSync(), isTrue);

        final lints = driver.parsedLintWarnings[_spec().id];
        expect(lints, isNotNull);
        expect(lints!.length, 2);
        expect(lints[0].code, 'WIDTH');
        expect(lints[0].filePath, 'rtl/alu.sv');
        expect(lints[0].line, 42);
        expect(lints[0].column, 7);
        expect(lints[1].code, 'UNUSED');
      },
    );

    group('Verilator 5 and extra flags', () {
      Future<List<String>> compileArgs({
        required String banner,
        Map<String, String> options = const <String, String>{},
        int probes = 1,
      }) async {
        final wd = Directory.systemTemp.createTempSync('simcrux_vl5_').path;
        addTearDown(() => Directory(wd).deleteSync(recursive: true));
        Directory(p.join(wd, 'obj_dir')).createSync(recursive: true);
        File(p.join(wd, 'obj_dir', 'Vtb_alu')).writeAsStringSync('fake');
        final recorder = _Recorder({
          'verilator': () => _FakeProcess(stdoutLines: <String>[banner]),
        });
        final driver = VerilatorDriver(launcher: recorder.launch);
        for (var i = 0; i < probes; i++) {
          await driver.compile(
            CompileRequest(
              test: _spec(),
              workingDirectory: wd,
              binaryConfig: SimulatorBinaryConfig(
                simulatorId: 'verilator',
                options: options,
              ),
            ),
          );
        }
        expect(
          recorder.calls.where((c) => c.args.contains('--version')),
          hasLength(1),
          reason: 'the version is probed once per binary, not per test',
        );
        return recorder.calls.lastWhere((c) => c.args.contains('--cc')).args;
      }

      test(
        'Verilator 5 builds with --timing and an event-driven main',
        () async {
          final args = await compileArgs(
            banner: 'Verilator 5.050 2026-07-01 rev v5.050',
            probes: 2,
          );
          expect(args, contains('--timing'));
        },
      );

      test('Verilator 4 builds without --timing', () async {
        final args = await compileArgs(banner: 'Verilator 4.228 2022-01-17');
        expect(args, isNot(contains('--timing')));
      });

      test('options.args are split like a shell line and passed before the '
          'sources', () async {
        final args = await compileArgs(
          banner: 'Verilator 5.050',
          options: const {'args': "-Wno-WIDTH -DMSG='hello world' -O3"},
        );
        expect(
          args,
          containsAllInOrder(<String>[
            '-Wno-fatal',
            '-Wno-WIDTH',
            '-DMSG=hello world',
            '-O3',
            'sim_main.cpp',
            'rtl/alu.sv',
          ]),
        );
      });

      test('sim_main.cpp drives a timing model and fails when no event is '
          r'left before $finish', () async {
        final wd = Directory.systemTemp.createTempSync('simcrux_vl_main_').path;
        addTearDown(() => Directory(wd).deleteSync(recursive: true));
        final driver = VerilatorDriver(
          launcher: _Recorder({
            'verilator': () => _FakeProcess(exit: 1),
          }).launch,
        );
        await driver.compile(
          CompileRequest(
            test: _spec(),
            workingDirectory: wd,
            binaryConfig: const SimulatorBinaryConfig(simulatorId: 'verilator'),
          ),
        );
        final main = File(p.join(wd, 'sim_main.cpp')).readAsStringSync();
        expect(main, contains('VERILATOR_VERSION_INTEGER >= 5000000'));
        expect(main, contains('top->eventsPending()'));
        expect(main, contains('ctx->time(top->nextTimeSlot())'));
        expect(main, contains(r'before $finish'));
        expect(main, contains('return 1;'));
        // Verilator 4 keeps the fixed-step loop.
        expect(main, contains('ctx->timeInc(1)'));
      });
    });

    test('compile reports failure when verilator exits non-zero', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'simcrux_verilator_fail_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final recorder = _Recorder({
        'verilator': () => _FakeProcess(
          stderrLines: const <String>['%Error: missing module'],
          exit: 1,
        ),
      });
      final driver = VerilatorDriver(launcher: recorder.launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tempDir.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'verilator'),
        ),
      );
      expect(result.success, isFalse);
      expect(result.artifactPath, isNull);
      expect(result.stderr, contains('missing module'));
    });

    test(
      'compile throws SimulatorNotAvailableException on missing verilator',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'simcrux_verilator_missing_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final driver = VerilatorDriver(launcher: _missingBinary);
        await expectLater(
          () => driver.compile(
            CompileRequest(
              test: _spec(),
              workingDirectory: tempDir.path,
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: 'verilator',
              ),
            ),
          ),
          throwsA(isA<SimulatorNotAvailableException>()),
        );
      },
    );

    test(
      'execute streams stdout / stderr / TestExecutionFinished and locates waveform',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'simcrux_verilator_exec_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final artifact = p.join(tempDir.path, 'obj_dir', 'Vtb_alu');
        Directory(p.dirname(artifact)).createSync(recursive: true);
        File(artifact).writeAsStringSync('fake');
        // Drop a fake FST dump so _locateWaveform finds it.
        final dumpPath = p.join(tempDir.path, 'sim.fst');
        File(dumpPath).writeAsStringSync('fake-dump');

        final recorder = _Recorder({
          artifact: () => _FakeProcess(
            stdoutLines: const <String>['Test passed'],
          ),
        });
        final driver = VerilatorDriver(launcher: recorder.launch);
        final spec = _spec(
          waveform: const WaveformPolicy(capture: WaveformCapturePolicy.always),
        );
        final events = await driver
            .execute(
              ExecuteRequest(
                test: spec,
                workingDirectory: tempDir.path,
                compileResult: CompileResult(
                  success: true,
                  artifactPath: artifact,
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'verilator',
                ),
              ),
            )
            .toList();
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.pass);
        expect(finished.exitCode, 0);
        expect(finished.waveformPath, dumpPath);
        final lines = events.whereType<TestLogLine>().toList();
        expect(lines.single.line, 'Test passed');
      },
    );

    test('execute reports fail status when artifact exits non-zero', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'simcrux_verilator_exec_fail_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final artifact = p.join(tempDir.path, 'obj_dir', 'Vtb_alu');
      Directory(p.dirname(artifact)).createSync(recursive: true);
      File(artifact).writeAsStringSync('fake');
      final recorder = _Recorder({
        artifact: () => _FakeProcess(exit: 1),
      });
      final driver = VerilatorDriver(launcher: recorder.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tempDir.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: artifact,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: 'verilator',
              ),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
    });

    test(
      'execute on missing artifact surfaces SimulatorNotAvailableException',
      () async {
        final tempDir = Directory.systemTemp.createTempSync(
          'simcrux_verilator_exec_missing_',
        );
        addTearDown(() => tempDir.deleteSync(recursive: true));
        final driver = VerilatorDriver(launcher: _missingBinary);
        final events = <TestExecutionEvent>[];
        Object? error;
        final done = Completer<void>();
        driver
            .execute(
              ExecuteRequest(
                test: _spec(),
                workingDirectory: tempDir.path,
                compileResult: const CompileResult(
                  success: true,
                  artifactPath: '/no/such/file',
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'verilator',
                ),
              ),
            )
            .listen(
              events.add,
              onError: (Object e) {
                error = e;
              },
              onDone: done.complete,
            );
        await done.future;
        expect(error, isA<SimulatorNotAvailableException>());
        expect(
          events.whereType<TestExecutionFinished>().single.status,
          TestStatus.unknown,
        );
      },
    );

    test('cancel kills the live process and escalates after grace', () async {
      final tempDir = Directory.systemTemp.createTempSync(
        'simcrux_verilator_cancel_',
      );
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final artifact = p.join(tempDir.path, 'obj_dir', 'Vtb_alu');
      Directory(p.dirname(artifact)).createSync(recursive: true);
      File(artifact).writeAsStringSync('fake');
      final hung = _FakeProcess(hangForever: true);
      final recorder = _Recorder({artifact: () => hung});
      final driver = VerilatorDriver(
        launcher: recorder.launch,
        killGrace: const Duration(milliseconds: 5),
      );
      final spec = _spec();
      final stream = driver.execute(
        ExecuteRequest(
          test: spec,
          workingDirectory: tempDir.path,
          compileResult: CompileResult(
            success: true,
            artifactPath: artifact,
            stdout: '',
            stderr: '',
          ),
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'verilator'),
        ),
      );
      final eventsFuture = stream.toList();
      // Wait until the process is registered as live.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      driver.cancel(spec.id);
      final killed = await pollUntil(() => hung.killed);
      expect(killed, isTrue);
      // Drain the stream.
      await eventsFuture;
    });
  });
}
