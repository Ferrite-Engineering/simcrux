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
import 'package:simcrux/services/simulator/ghdl_driver.dart';
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
    required this.environment,
    required this.workingDirectory,
  });
  final String executable;
  final List<String> args;
  final Map<String, String>? environment;
  final String? workingDirectory;
}

/// Records every launch call and dispenses a fake process for each
/// invocation. GHDL has three stages (analyze / elaborate / run) so
/// the recorder accepts a *queue* of factories per binary key — each
/// successive call to `ghdl` pulls the next one.
class _Recorder {
  _Recorder(Map<String, List<_FakeProcess Function()>> byExecutable)
    : _queues = {
        for (final entry in byExecutable.entries)
          entry.key: List<_FakeProcess Function()>.from(entry.value),
      };

  final Map<String, List<_FakeProcess Function()>> _queues;
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
    final queue = _queues[executable];
    if (queue == null || queue.isEmpty) {
      throw ProcessException(executable, args, 'no scripted factory', -1);
    }
    return queue.removeAt(0)();
  }
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
  String id = 'unit/counter',
  String top = 'tb_counter',
  List<String> sources = const ['rtl/counter.vhd', 'tb/counter_tb.vhd'],
  List<String> includes = const [],
  WaveformPolicy waveform = const WaveformPolicy(),
}) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'ghdl',
    top: top,
    sources: sources,
    includeDirs: includes,
    waveform: waveform,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_ghdl_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('GhdlDriver — metadata', () {
    test('declares its id, displayName, and capabilities', () {
      final driver = GhdlDriver(launcher: _Recorder({}).launch);
      expect(driver.id, 'ghdl');
      expect(driver.displayName, 'GHDL');
      expect(driver.capabilities.supportsVcd, isTrue);
      expect(driver.capabilities.supportsFst, isTrue);
      expect(driver.capabilities.supportsCocotb, isTrue);
      expect(driver.capabilities.requiresSeparateCompileStep, isTrue);
    });
  });

  group('GhdlDriver — detectVersion', () {
    test('returns the ghdl --version banner on success', () async {
      final rec = _Recorder({
        'ghdl': [
          () => _FakeProcess(
            stdoutLines: const [
              'GHDL 4.0.0-dev (5.0.0.r123.g4567890) [Dunoon edition]',
              ' Compiled with GNAT Version: 13.2',
              ' mcode code generator',
            ],
          ),
        ],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'ghdl'),
      );
      expect(v, startsWith('GHDL 4.0.0-dev'));
      expect(rec.calls.single.args, ['--version']);
    });

    test('returns null when ghdl is missing', () async {
      final driver = GhdlDriver(launcher: _missingBinary);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'ghdl'),
      );
      expect(v, isNull);
    });

    test('returns null on nonzero exit code', () async {
      final rec = _Recorder({
        'ghdl': [() => _FakeProcess(exit: 1)],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'ghdl'),
      );
      expect(v, isNull);
    });
  });

  group('GhdlDriver — compile', () {
    test(
      'runs analyze + elaborate stages with --std/--ieee/--workdir',
      () async {
        final rec = _Recorder({
          'ghdl': [
            _FakeProcess.new, // analyze
            _FakeProcess.new, // elaborate
          ],
        });
        final driver = GhdlDriver(launcher: rec.launch);
        final result = await driver.compile(
          CompileRequest(
            test: _spec(
              sources: ['rtl/counter.vhd', 'tb/counter_tb.vhd'],
              includes: ['libs/work'],
            ),
            workingDirectory: tmp.path,
            binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
          ),
        );
        expect(result.success, isTrue);
        expect(result.artifactPath, tmp.path);
        expect(rec.calls.length, 2);
        final analyze = rec.calls[0];
        expect(analyze.args.first, '-a');
        expect(analyze.args, contains('--std=08'));
        expect(analyze.args, contains('--ieee=synopsys'));
        expect(analyze.args, contains('--workdir=${tmp.path}'));
        expect(analyze.args, contains('-Plibs/work'));
        expect(analyze.args, contains('rtl/counter.vhd'));
        expect(analyze.args, contains('tb/counter_tb.vhd'));

        final elab = rec.calls[1];
        expect(elab.args.first, '-e');
        expect(elab.args, contains('--std=08'));
        expect(elab.args, contains('tb_counter'));
      },
    );

    test('returns failure when analyze exits nonzero', () async {
      final rec = _Recorder({
        'ghdl': [
          () => _FakeProcess(
            exit: 1,
            stderrLines: const ['counter.vhd:10:5: parse error'],
          ),
        ],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
        ),
      );
      expect(result.success, isFalse);
      expect(result.artifactPath, isNull);
      expect(result.stderr, contains('parse error'));
      // Only one stage attempted.
      expect(rec.calls.length, 1);
    });

    test('returns failure when elaborate exits nonzero', () async {
      final rec = _Recorder({
        'ghdl': [
          _FakeProcess.new, // analyze ok
          () => _FakeProcess(
            exit: 1,
            stderrLines: const ['tb_counter: cannot find unit'],
          ),
        ],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
        ),
      );
      expect(result.success, isFalse);
      expect(result.stderr, contains('cannot find unit'));
      expect(rec.calls.length, 2);
    });

    test(
      'throws SimulatorNotAvailableException when ghdl is missing',
      () async {
        final driver = GhdlDriver(launcher: _missingBinary);
        expect(
          () => driver.compile(
            CompileRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          ),
          throwsA(isA<SimulatorNotAvailableException>()),
        );
      },
    );
  });

  group('GhdlDriver — execute', () {
    test('streams log lines and finishes with pass on exit 0', () async {
      final rec = _Recorder({
        'ghdl': [
          () => _FakeProcess(
            stdoutLines: const ['counter started', 'TEST PASSED'],
          ),
        ],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      final lines = events.whereType<TestLogLine>().toList();
      expect(
        lines.map((l) => l.line),
        containsAll(<String>['counter started', 'TEST PASSED']),
      );
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.pass);
      expect(finished.exitCode, 0);
      // Stage signature
      final call = rec.calls.single;
      expect(call.args.first, '-r');
      expect(call.args, contains('--workdir=${tmp.path}'));
      expect(call.args, contains('tb_counter'));
    });

    test('finishes with fail on nonzero exit', () async {
      final rec = _Recorder({
        'ghdl': [() => _FakeProcess(exit: 2)],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.exitCode, 2);
    });

    test('passes --vcd when WaveformFormat.vcd is requested', () async {
      final rec = _Recorder({
        'ghdl': [_FakeProcess.new],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(
                waveform: const WaveformPolicy(
                  capture: WaveformCapturePolicy.always,
                  format: WaveformFormat.vcd,
                ),
              ),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      expect(
        rec.calls.single.args,
        contains('--vcd=${p.join(tmp.path, 'sim.vcd')}'),
      );
    });

    test('passes --fst when WaveformFormat.fst is requested', () async {
      final rec = _Recorder({
        'ghdl': [_FakeProcess.new],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(
                waveform: const WaveformPolicy(
                  capture: WaveformCapturePolicy.always,
                ),
              ),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      expect(
        rec.calls.single.args,
        contains('--fst=${p.join(tmp.path, 'sim.fst')}'),
      );
    });

    test(
      'passes --wave (GHW native) when WaveformFormat.ghw is requested',
      () async {
        final rec = _Recorder({
          'ghdl': [_FakeProcess.new],
        });
        final driver = GhdlDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(
                  waveform: const WaveformPolicy(
                    capture: WaveformCapturePolicy.always,
                    format: WaveformFormat.ghw,
                  ),
                ),
                workingDirectory: tmp.path,
                compileResult: CompileResult(
                  success: true,
                  artifactPath: tmp.path,
                  stdout: '',
                  stderr: '',
                ),
                binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
              ),
            )
            .toList();
        expect(
          rec.calls.single.args,
          contains('--wave=${p.join(tmp.path, 'sim.ghw')}'),
        );
      },
    );

    test('does not pass any waveform flag when capture is never', () async {
      final rec = _Recorder({
        'ghdl': [_FakeProcess.new],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(
                waveform: const WaveformPolicy(
                  capture: WaveformCapturePolicy.never,
                ),
              ),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      final args = rec.calls.single.args;
      expect(args.where((a) => a.startsWith('--vcd=')), isEmpty);
      expect(args.where((a) => a.startsWith('--fst=')), isEmpty);
      expect(args.where((a) => a.startsWith('--wave=')), isEmpty);
    });

    test('reports waveformPath when a .ghw lands in the working dir', () async {
      File(p.join(tmp.path, 'sim.ghw')).writeAsStringSync('ghw');
      final rec = _Recorder({
        'ghdl': [_FakeProcess.new],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(
                waveform: const WaveformPolicy(
                  capture: WaveformCapturePolicy.always,
                  format: WaveformFormat.ghw,
                ),
              ),
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.waveformPath, endsWith('sim.ghw'));
    });

    test('emits unknown when ghdl binary is missing during execute', () async {
      final driver = GhdlDriver(launcher: _missingBinary);
      final stream = driver.execute(
        ExecuteRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          compileResult: CompileResult(
            success: true,
            artifactPath: tmp.path,
            stdout: '',
            stderr: '',
          ),
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
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

  group('GhdlDriver — cancel', () {
    test('kills the in-flight ghdl -r process', () async {
      final fake = _FakeProcess(hangForever: true);
      final rec = _Recorder({
        'ghdl': [() => fake],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      final spec = _spec();
      final streamFuture = driver
          .execute(
            ExecuteRequest(
              test: spec,
              workingDirectory: tmp.path,
              compileResult: CompileResult(
                success: true,
                artifactPath: tmp.path,
                stdout: '',
                stderr: '',
              ),
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'ghdl'),
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
      final driver = GhdlDriver(launcher: _Recorder({}).launch);
      expect(() => driver.cancel('unit/nope'), returnsNormally);
    });
  });

  group('GhdlDriver — binary resolution', () {
    test('uses customPath as a directory containing ghdl', () async {
      final rec = _Recorder({
        p.join('/opt/ghdl-4/bin', 'ghdl'): [
          _FakeProcess.new,
          _FakeProcess.new,
        ],
      });
      final driver = GhdlDriver(launcher: rec.launch);
      await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(
            simulatorId: 'ghdl',
            source: SimulatorBinarySource.custom,
            customPath: '/opt/ghdl-4/bin',
          ),
        ),
      );
      expect(rec.calls.first.executable, p.join('/opt/ghdl-4/bin', 'ghdl'));
    });

    test(
      'uses customPath as the binary itself when basename matches',
      () async {
        final rec = _Recorder({
          '/opt/ghdl-4/bin/ghdl': [_FakeProcess.new, _FakeProcess.new],
        });
        final driver = GhdlDriver(launcher: rec.launch);
        await driver.compile(
          CompileRequest(
            test: _spec(),
            workingDirectory: tmp.path,
            binaryConfig: const SimulatorBinaryConfig(
              simulatorId: 'ghdl',
              source: SimulatorBinarySource.custom,
              customPath: '/opt/ghdl-4/bin/ghdl',
            ),
          ),
        );
        expect(rec.calls.first.executable, '/opt/ghdl-4/bin/ghdl');
      },
    );
  });
}
