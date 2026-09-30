// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/domain/models/waveform_policy.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// Scripted [TestProcess] for driver tests. Tests author the stdout /
/// stderr / exit code sequence and optionally a deliberate hang.
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

  @override
  Stream<String> get stdout => Stream<String>.fromIterable(stdoutLines);

  @override
  Stream<String> get stderr => Stream<String>.fromIterable(stderrLines);

  @override
  Future<int> get exitCode async {
    if (_exitCompleter.isCompleted) return _exitCompleter.future;
    if (!hangForever) _exitCompleter.complete(exit);
    return _exitCompleter.future;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-15);
    return true;
  }
}

/// Records every launch call so tests can assert the args / env / cwd
/// passed to the simulator. Returns a configurable [_FakeProcess]
/// keyed by the executable name.
class _RecordingLauncher {
  _RecordingLauncher(this._byExecutable);
  final Map<String, _FakeProcess Function()> _byExecutable;
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
        environment: environment == null
            ? null
            : Map<String, String>.unmodifiable(environment),
        workingDirectory: workingDirectory,
      ),
    );
    final factory = _byExecutable[executable];
    if (factory == null) {
      throw ProcessException(executable, args, 'no such factory', -1);
    }
    return factory();
  }
}

class _LaunchCall {
  _LaunchCall({
    required this.executable,
    required this.args,
    required this.environment,
    required this.workingDirectory,
  });
  final String executable;
  final List<String> args;
  final Map<String, String>? environment;
  final String? workingDirectory;
}

Future<TestProcess> _missingBinary(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  throw ProcessException(executable, args, 'no such file', -1);
}

TestSpec _spec({
  String id = 'unit/alu_basic',
  String top = 'tb_alu',
  List<String> sources = const ['rtl/alu.v', 'tb/alu_tb.v'],
  List<String> includes = const [],
  Map<String, String> defines = const {},
  WaveformPolicy waveform = const WaveformPolicy(),
}) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'icarus',
    top: top,
    sources: sources,
    includeDirs: includes,
    defines: defines,
    waveform: waveform,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_icarus_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('IcarusDriver — metadata', () {
    test('declares its id and display name', () {
      final driver = IcarusDriver(launcher: _RecordingLauncher({}).launch);
      expect(driver.id, 'icarus');
      expect(driver.displayName, 'Icarus Verilog');
      expect(driver.capabilities.supportsVcd, isTrue);
      expect(driver.capabilities.supportsFst, isTrue);
      expect(driver.capabilities.requiresSeparateCompileStep, isTrue);
    });
  });

  group('IcarusDriver — detectVersion', () {
    test('returns the iverilog -V banner on success', () async {
      final rec = _RecordingLauncher({
        'iverilog': () => _FakeProcess(
          stdoutLines: const [
            'Icarus Verilog version 12.0 (stable)',
            '',
          ],
        ),
      });
      final driver = IcarusDriver(launcher: rec.launch);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'icarus'),
      );
      expect(v, 'Icarus Verilog version 12.0 (stable)');
      expect(rec.calls.single.args, ['-V']);
    });

    test('returns null when iverilog is not on PATH', () async {
      final driver = IcarusDriver(launcher: _missingBinary);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'icarus'),
      );
      expect(v, isNull);
    });

    test('returns null on nonzero exit code', () async {
      final rec = _RecordingLauncher({
        'iverilog': () => _FakeProcess(exit: 1, stderrLines: const ['boom']),
      });
      final driver = IcarusDriver(launcher: rec.launch);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'icarus'),
      );
      expect(v, isNull);
    });
  });

  group('IcarusDriver — compile', () {
    test('builds the iverilog command line and reports success', () async {
      File(p.join(tmp.path, 'sim.vvp')).createSync();

      final rec = _RecordingLauncher({
        'iverilog': () => _FakeProcess(stdoutLines: const ['compiled']),
      });
      final driver = IcarusDriver(launcher: rec.launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(
            sources: ['rtl/alu.v'],
            includes: ['rtl/include'],
            defines: {'SIM': '1'},
          ),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
        ),
      );
      expect(result.success, isTrue);
      expect(result.artifactPath, p.join(tmp.path, 'sim.vvp'));
      expect(result.stdout.trim(), 'compiled');
      final call = rec.calls.single;
      expect(call.executable, 'iverilog');
      expect(call.args, contains('-o'));
      expect(call.args, contains(p.join(tmp.path, 'sim.vvp')));
      expect(call.args, contains('-s'));
      expect(call.args, contains('tb_alu'));
      expect(call.args, contains('-Irtl/include'));
      expect(call.args, contains('-DSIM=1'));
      expect(call.args, contains('rtl/alu.v'));
      expect(call.args.first, '-g2012');
    });

    test('reports failure when iverilog exits nonzero', () async {
      final rec = _RecordingLauncher({
        'iverilog': () =>
            _FakeProcess(exit: 1, stderrLines: const ['syntax error']),
      });
      final driver = IcarusDriver(launcher: rec.launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
        ),
      );
      expect(result.success, isFalse);
      expect(result.artifactPath, isNull);
      expect(result.stderr, contains('syntax error'));
    });

    test(
      'reports failure when iverilog succeeds but produces no .vvp',
      () async {
        final rec = _RecordingLauncher({
          'iverilog': _FakeProcess.new,
        });
        final driver = IcarusDriver(launcher: rec.launch);
        final result = await driver.compile(
          CompileRequest(
            test: _spec(),
            workingDirectory: tmp.path,
            binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
          ),
        );
        expect(result.success, isFalse);
        expect(result.artifactPath, isNull);
      },
    );

    test(
      'throws SimulatorNotAvailableException when iverilog is missing',
      () async {
        final driver = IcarusDriver(launcher: _missingBinary);
        expect(
          () => driver.compile(
            CompileRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
            ),
          ),
          throwsA(isA<SimulatorNotAvailableException>()),
        );
      },
    );
  });

  group('IcarusDriver — execute', () {
    test(
      'streams TestLogLine events and finishes with pass on exit 0',
      () async {
        final rec = _RecordingLauncher({
          'vvp': () => _FakeProcess(
            stdoutLines: const ['hello', 'TEST PASSED'],
            stderrLines: const ['warning: …'],
          ),
        });
        final driver = IcarusDriver(launcher: rec.launch);
        final events = await driver
            .execute(
              ExecuteRequest(
                test: _spec(),
                workingDirectory: tmp.path,
                compileResult: const CompileResult(
                  success: true,
                  artifactPath: 'sim.vvp',
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'icarus',
                ),
              ),
            )
            .toList();
        final lines = events.whereType<TestLogLine>().toList();
        expect(
          lines.map((l) => l.line),
          containsAll(<String>['hello', 'TEST PASSED']),
        );
        expect(lines.any((l) => l.fromStderr), isTrue);
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.pass);
        expect(finished.exitCode, 0);
      },
    );

    test('finishes with fail on nonzero exit code', () async {
      final rec = _RecordingLauncher({
        'vvp': () => _FakeProcess(exit: 2),
      });
      final driver = IcarusDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: const CompileResult(
                success: true,
                artifactPath: 'sim.vvp',
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.exitCode, 2);
    });

    test(
      'passes -fst when WaveformPolicy.fst is requested with capture',
      () async {
        final rec = _RecordingLauncher({
          'vvp': _FakeProcess.new,
        });
        final driver = IcarusDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(
                  waveform: const WaveformPolicy(
                    capture: WaveformCapturePolicy.always,
                  ),
                ),
                workingDirectory: tmp.path,
                compileResult: const CompileResult(
                  success: true,
                  artifactPath: 'sim.vvp',
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'icarus',
                ),
              ),
            )
            .toList();
        expect(rec.calls.single.args, contains('-fst'));
      },
    );

    test('does not pass waveform flags when capture is never', () async {
      final rec = _RecordingLauncher({
        'vvp': _FakeProcess.new,
      });
      final driver = IcarusDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(
                waveform: const WaveformPolicy(
                  capture: WaveformCapturePolicy.never,
                ),
              ),
              workingDirectory: tmp.path,
              compileResult: const CompileResult(
                success: true,
                artifactPath: 'sim.vvp',
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
            ),
          )
          .toList();
      expect(rec.calls.single.args, isNot(contains('-fst')));
      expect(rec.calls.single.args, isNot(contains('-vcd')));
    });

    test(
      'reports waveformPath when a .vcd / .fst lands in the working dir',
      () async {
        File(p.join(tmp.path, 'dump.vcd')).writeAsStringSync('vcd');
        final rec = _RecordingLauncher({
          'vvp': _FakeProcess.new,
        });
        final driver = IcarusDriver(launcher: rec.launch);
        final events = await driver
            .execute(
              ExecuteRequest(
                test: _spec(
                  waveform: const WaveformPolicy(
                    format: WaveformFormat.vcd,
                  ),
                ),
                workingDirectory: tmp.path,
                compileResult: const CompileResult(
                  success: true,
                  artifactPath: 'sim.vvp',
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'icarus',
                ),
              ),
            )
            .toList();
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.waveformPath, endsWith('dump.vcd'));
      },
    );

    test('emits a finished event with unknown when vvp is missing', () async {
      final driver = IcarusDriver(launcher: _missingBinary);
      final stream = driver.execute(
        ExecuteRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          compileResult: const CompileResult(
            success: true,
            artifactPath: 'sim.vvp',
            stdout: '',
            stderr: '',
          ),
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
        ),
      );
      final errors = <Object>[];
      final events = <TestExecutionEvent>[];
      await stream.handleError(errors.add).listen(events.add).asFuture<void>();
      expect(errors.single, isA<SimulatorNotAvailableException>());
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.unknown,
      );
    });
  });

  group('IcarusDriver — cancel', () {
    test('kills the in-flight vvp process', () async {
      final fake = _FakeProcess(hangForever: true);
      final rec = _RecordingLauncher({'vvp': () => fake});
      final driver = IcarusDriver(launcher: rec.launch);
      final spec = _spec();
      final streamFuture = driver
          .execute(
            ExecuteRequest(
              test: spec,
              workingDirectory: tmp.path,
              compileResult: const CompileResult(
                success: true,
                artifactPath: 'sim.vvp',
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'icarus'),
            ),
          )
          .toList();
      // Yield so the launcher fires and the driver registers the process.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      driver.cancel(spec.id);
      final events = await streamFuture;
      expect(fake.killed, isTrue);
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.fail,
      );
    });

    test('cancel is a no-op when no process is in flight', () {
      final driver = IcarusDriver(launcher: _RecordingLauncher({}).launch);
      expect(() => driver.cancel('unit/nope'), returnsNormally);
    });
  });

  group('IcarusDriver — binary resolution', () {
    test('uses customPath as a directory containing iverilog/vvp', () async {
      final rec = _RecordingLauncher({
        p.join('/opt/iverilog-12/bin', 'iverilog'): _FakeProcess.new,
      });
      final driver = IcarusDriver(launcher: rec.launch);
      File(p.join(tmp.path, 'sim.vvp')).writeAsStringSync('');
      await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(
            simulatorId: 'icarus',
            source: SimulatorBinarySource.custom,
            customPath: '/opt/iverilog-12/bin',
          ),
        ),
      );
      expect(
        rec.calls.single.executable,
        p.join('/opt/iverilog-12/bin', 'iverilog'),
      );
    });
  });
}
