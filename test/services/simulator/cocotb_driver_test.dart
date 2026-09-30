// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// Scripted [TestProcess].
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

class _Recorder {
  _Recorder(this._byExecutable);
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

Future<TestProcess> _missingBinary(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  throw ProcessException(executable, args, 'no such file', -1);
}

/// The `results.xml` a Cocotb 1.9 run writes when one of two tests fails.
const String _failingResultsXml = '''
<testsuites name="results">
  <testsuite name="all" package="all">
    <testcase name="test_pass" classname="test_dff" file="test_dff.py" lineno="8" time="0.01" sim_time_ns="10.0" ratio_time="1000.0"/>
    <testcase name="test_fail" classname="test_dff" file="test_dff.py" lineno="13" time="0.01" sim_time_ns="20.0" ratio_time="2000.0">
      <failure message="Test failed with RANDOM_SEED=1"/>
    </testcase>
  </testsuite>
</testsuites>
''';

TestSpec _spec({
  String id = 'cocotb/dff',
  String top = 'dff',
  List<String> sources = const <String>[],
  Map<String, String> parameters = const <String, String>{},
  Map<String, HdlLanguage> sourceLanguages = const <String, HdlLanguage>{},
}) {
  return TestSpec(
    id: id,
    name: id.split('/').last,
    suiteName: id.split('/').first,
    simulatorId: 'cocotb',
    top: top,
    sources: sources,
    parameters: parameters,
    sourceLanguages: sourceLanguages,
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('simcrux_cocotb_test_');
  });

  tearDown(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('CocotbDriver — metadata', () {
    test('declares its id, displayName, and capabilities', () {
      final driver = CocotbDriver(launcher: _Recorder({}).launch);
      expect(driver.id, 'cocotb');
      expect(driver.displayName, 'Cocotb');
      expect(driver.capabilities.supportsCocotb, isTrue);
      expect(driver.capabilities.requiresSeparateCompileStep, isFalse);
      expect(driver.capabilities.emitsStructuredOutput, isTrue);
    });
  });

  group('CocotbDriver — detectVersion', () {
    test('returns cocotb-config --version on success', () async {
      final rec = _Recorder({
        'cocotb-config': () => _FakeProcess(stdoutLines: const ['2.0.0']),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'cocotb'),
      );
      expect(v, '2.0.0');
      expect(rec.calls.single.args, ['--version']);
    });

    test('returns null when cocotb-config is missing', () async {
      final driver = CocotbDriver(launcher: _missingBinary);
      final v = await driver.detectVersion(
        const SimulatorBinaryConfig(simulatorId: 'cocotb'),
      );
      expect(v, isNull);
    });
  });

  group('CocotbDriver — compile', () {
    test('reports vacuous success — Cocotb compiles inside make', () async {
      final driver = CocotbDriver(launcher: _Recorder({}).launch);
      final result = await driver.compile(
        CompileRequest(
          test: _spec(),
          workingDirectory: tmp.path,
          binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
        ),
      );
      expect(result.success, isTrue);
      expect(result.artifactPath, isNull);
    });
  });

  group('CocotbDriver — max_failures', () {
    test(
      'an invalid value ends the run naming the option, without make',
      () async {
        final rec = _Recorder({'make': _FakeProcess.new});
        final driver = CocotbDriver(launcher: rec.launch);
        final events = await driver
            .execute(
              ExecuteRequest(
                test: _spec(),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                  options: {'max_failures': 'abc'},
                ),
              ),
            )
            .toList()
            .timeout(const Duration(seconds: 5));
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.unknown);
        expect(finished.failureMessage, contains('max_failures'));
        expect(rec.calls, isEmpty, reason: 'make never starts');
      },
    );
  });

  group('CocotbDriver — execute', () {
    test('invokes make with SIM and TOPLEVEL Makefile vars', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          stdoutLines: const [
            '** TESTS=1 PASS=1 FAIL=0 SKIP=0 **',
          ],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      final call = rec.calls.single;
      expect(call.executable, 'make');
      expect(call.args, contains('SIM=icarus'));
      expect(call.args, contains('TOPLEVEL=dff'));
      expect(call.workingDirectory, tmp.path);
      expect(call.environment?['SIM'], 'icarus');
    });

    test('honors SimulatorBinaryConfig.options.sim override', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: 'cocotb',
                options: {'sim': 'verilator'},
              ),
            ),
          )
          .toList();
      expect(rec.calls.single.args, contains('SIM=verilator'));
    });

    test('per-test parameters.sim wins over project options.sim', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(parameters: const {'sim': 'ghdl'}),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(
                simulatorId: 'cocotb',
                options: {'sim': 'verilator'},
              ),
            ),
          )
          .toList();
      expect(rec.calls.single.args, contains('SIM=ghdl'));
    });

    test('parses pass summary and reports pass + structured metrics', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          stdoutLines: const [
            '0.00ns INFO running test_foo',
            '12.00ns INFO test_foo passed',
            '** test_foo                      PASS         12.00          0.01 **',
            '** TESTS=1 PASS=1 FAIL=0 SKIP=0 **',
          ],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.pass);
      expect(finished.metrics['cocotb.tests'], '1');
      expect(finished.metrics['cocotb.pass'], '1');
      expect(finished.metrics['cocotb.fail'], '0');
      expect(finished.metrics['cocotb.test.test_foo.status'], 'PASS');
      expect(finished.metrics['cocotb.test.test_foo.sim_time_ns'], '12.0');
    });

    test('parses fail summary and reports fail', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          exit: 1,
          stdoutLines: const [
            '** test_foo                      PASS         12.00 **',
            '** test_bar                      FAIL         24.00 **',
            '** TESTS=2 PASS=1 FAIL=1 SKIP=0 **',
          ],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      final finished = events.whereType<TestExecutionFinished>().single;
      expect(finished.status, TestStatus.fail);
      expect(finished.metrics['cocotb.tests'], '2');
      expect(finished.metrics['cocotb.pass'], '1');
      expect(finished.metrics['cocotb.fail'], '1');
      expect(finished.metrics['cocotb.test.test_bar.status'], 'FAIL');
    });

    test(
      'trusts structured summary over exit code 0 when failures are reported',
      () async {
        // Some Makefile flows let the underlying simulator return 0 even
        // with failing Cocotb tests; the structured summary is the
        // authoritative source.
        final rec = _Recorder({
          'make': () => _FakeProcess(
            stdoutLines: const [
              '** TESTS=2 PASS=1 FAIL=1 SKIP=0 **',
            ],
          ),
        });
        final driver = CocotbDriver(launcher: rec.launch);
        final events = await driver
            .execute(
              ExecuteRequest(
                test: _spec(),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.fail);
        // The contradicting 0 is withheld so the scheduler's default
        // exit-code detector cannot turn this failure into a pass.
        expect(finished.exitCode, isNull);
        expect(
          finished.metrics[CocotbDriver.kMetricProcessExitCode],
          '0',
        );
      },
    );

    test(
      'a failing results.xml with exit 0 withholds the exit code',
      () async {
        File('${tmp.path}/results.xml').writeAsStringSync(_failingResultsXml);
        final rec = _Recorder({'make': _FakeProcess.new});
        final driver = CocotbDriver(launcher: rec.launch);
        final events = await driver
            .execute(
              ExecuteRequest(
                test: _spec(),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        final finished = events.whereType<TestExecutionFinished>().single;
        expect(finished.status, TestStatus.fail);
        expect(finished.exitCode, isNull);
        expect(
          finished.metrics[CocotbDriver.kMetricProcessExitCode],
          '0',
        );
      },
    );

    test(
      'a passing verdict keeps exit code 0, a non-zero exit is kept',
      () async {
        final passing =
            await CocotbDriver(
                  launcher: _Recorder({
                    'make': () => _FakeProcess(
                      stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
                    ),
                  }).launch,
                )
                .execute(
                  ExecuteRequest(
                    test: _spec(),
                    workingDirectory: tmp.path,
                    compileResult: null,
                    binaryConfig: const SimulatorBinaryConfig(
                      simulatorId: 'cocotb',
                    ),
                  ),
                )
                .toList();
        final pass = passing.whereType<TestExecutionFinished>().single;
        expect(pass.exitCode, 0);
        expect(
          pass.metrics.containsKey(CocotbDriver.kMetricProcessExitCode),
          isFalse,
        );

        final failing =
            await CocotbDriver(
                  launcher: _Recorder({
                    'make': () => _FakeProcess(
                      exit: 1,
                      stdoutLines: const ['** TESTS=1 PASS=0 FAIL=1 SKIP=0 **'],
                    ),
                  }).launch,
                )
                .execute(
                  ExecuteRequest(
                    test: _spec(),
                    workingDirectory: tmp.path,
                    compileResult: null,
                    binaryConfig: const SimulatorBinaryConfig(
                      simulatorId: 'cocotb',
                    ),
                  ),
                )
                .toList();
        expect(failing.whereType<TestExecutionFinished>().single.exitCode, 1);
      },
    );

    test('falls back to exit code when summary is absent', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(exit: 2, stderrLines: const ['boom']),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      final events = await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.fail,
      );
    });

    test('emits unknown when make is missing', () async {
      final driver = CocotbDriver(launcher: _missingBinary);
      final errors = <Object>[];
      final events = <TestExecutionEvent>[];
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .handleError(errors.add)
          .listen(events.add)
          .asFuture<void>();
      expect(errors.single, isA<SimulatorNotAvailableException>());
      expect(
        events.whereType<TestExecutionFinished>().single.status,
        TestStatus.unknown,
      );
    });
  });

  group('CocotbDriver — TOPLEVEL_LANG routing (mixed-language)', () {
    test(
      'auto-derives TOPLEVEL_LANG=verilog from a .v-dominant source list',
      () async {
        final rec = _Recorder({
          'make': () => _FakeProcess(
            stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
          ),
        });
        final driver = CocotbDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(sources: const ['dff.v', 'wrap.sv']),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        expect(rec.calls.single.args, contains('TOPLEVEL_LANG=verilog'));
      },
    );

    test(
      'auto-derives TOPLEVEL_LANG=vhdl from a .vhd-dominant source list',
      () async {
        final rec = _Recorder({
          'make': () => _FakeProcess(
            stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
          ),
        });
        final driver = CocotbDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(sources: const ['dff.vhd', 'pkg.vhdl']),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        expect(rec.calls.single.args, contains('TOPLEVEL_LANG=vhdl'));
      },
    );

    test(
      'per-test TOPLEVEL_LANG parameter wins over auto-derivation',
      () async {
        final rec = _Recorder({
          'make': () => _FakeProcess(
            stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
          ),
        });
        final driver = CocotbDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(
                  sources: const ['dff.v'],
                  parameters: const {'TOPLEVEL_LANG': 'vhdl'},
                ),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        expect(rec.calls.single.args, contains('TOPLEVEL_LANG=vhdl'));
        expect(
          rec.calls.single.args.where((a) => a.startsWith('TOPLEVEL_LANG=')),
          hasLength(1),
        );
      },
    );

    test(
      'honors per-source language overrides when computing dominance',
      () async {
        // Disguised .txt is actually VHDL — override wins. Combined with
        // a single .v this still produces a VHDL majority.
        final rec = _Recorder({
          'make': () => _FakeProcess(
            stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
          ),
        });
        final driver = CocotbDriver(launcher: rec.launch);
        await driver
            .execute(
              ExecuteRequest(
                test: _spec(
                  sources: const ['legacy.txt', 'extra.txt'],
                  sourceLanguages: const {
                    'legacy.txt': HdlLanguage.vhdl,
                    'extra.txt': HdlLanguage.vhdl,
                  },
                ),
                workingDirectory: tmp.path,
                compileResult: null,
                binaryConfig: const SimulatorBinaryConfig(
                  simulatorId: 'cocotb',
                ),
              ),
            )
            .toList();
        expect(rec.calls.single.args, contains('TOPLEVEL_LANG=vhdl'));
      },
    );

    test('omits TOPLEVEL_LANG when the source list has no HDL files', () async {
      final rec = _Recorder({
        'make': () => _FakeProcess(
          stdoutLines: const ['** TESTS=1 PASS=1 FAIL=0 SKIP=0 **'],
        ),
      });
      final driver = CocotbDriver(launcher: rec.launch);
      await driver
          .execute(
            ExecuteRequest(
              test: _spec(sources: const ['tb.py']),
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      expect(
        rec.calls.single.args.where((a) => a.startsWith('TOPLEVEL_LANG=')),
        isEmpty,
      );
    });
  });

  group('CocotbDriver — cancel', () {
    test('kills the in-flight make process', () async {
      final fake = _FakeProcess(hangForever: true);
      final rec = _Recorder({'make': () => fake});
      final driver = CocotbDriver(launcher: rec.launch);
      final spec = _spec();
      final streamFuture = driver
          .execute(
            ExecuteRequest(
              test: spec,
              workingDirectory: tmp.path,
              compileResult: null,
              binaryConfig: const SimulatorBinaryConfig(simulatorId: 'cocotb'),
            ),
          )
          .toList();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      driver.cancel(spec.id);
      await streamFuture;
      expect(fake.killed, isTrue);
    });
  });

  group('parseCocotbSummary', () {
    test('parses a clean aggregate line', () {
      final s = parseCocotbSummary('** TESTS=4 PASS=3 FAIL=1 SKIP=0 **');
      expect(s, isNotNull);
      expect(s!.tests, 4);
      expect(s.passes, 3);
      expect(s.fails, 1);
      expect(s.skips, 0);
    });

    test('returns null when no aggregate is present', () {
      final s = parseCocotbSummary('boring log\nnothing to see');
      expect(s, isNull);
    });

    test('is tolerant of extra whitespace', () {
      final s = parseCocotbSummary(
        '   TESTS = 2   PASS = 2   FAIL = 0   SKIP = 0  ',
      );
      expect(s, isNotNull);
      expect(s!.tests, 2);
    });
  });

  group('parseCocotbPerTestRows', () {
    test('parses PASS / FAIL rows with timings', () {
      final rows = parseCocotbPerTestRows('''
** test_foo                      PASS         12.00          0.01 **
** test_bar                      FAIL         24.00          0.02 **
''');
      expect(rows, hasLength(2));
      expect(rows[0].name, 'test_foo');
      expect(rows[0].status, 'PASS');
      expect(rows[0].simTimeNs, 12.0);
      expect(rows[1].name, 'test_bar');
      expect(rows[1].status, 'FAIL');
      expect(rows[1].simTimeNs, 24.0);
    });

    test('parses SKIP rows without a SIM TIME column', () {
      final rows = parseCocotbPerTestRows('** test_baz   SKIP **');
      expect(rows, hasLength(1));
      expect(rows[0].name, 'test_baz');
      expect(rows[0].status, 'SKIP');
      expect(rows[0].simTimeNs, isNull);
    });

    test('returns empty list when no per-test rows are present', () {
      final rows = parseCocotbPerTestRows('** TESTS=0 PASS=0 FAIL=0 SKIP=0 **');
      expect(rows, isEmpty);
    });

    // The rows above use BARE test names, which Cocotb has never emitted: it
    // qualifies every name with the test module. The bare-name cases are kept
    // because they still parse, but they are not what a real run looks like,
    // and on their own they let this parser pass its tests while matching
    // nothing in production. The blobs below are copied verbatim from a real
    // cocotb 2.1.0 run against Icarus.
    group('real Cocotb output', () {
      const realDefault = '''
** TEST                          STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
**************************************************************************************
** test_mix.test_alpha_pass       PASS          10.00           0.00      86132.59  **
** test_mix.test_bravo_fail       FAIL          20.00           0.00     200400.68  **
** test_mix.test_charlie_skip     SKIP           0.00           0.00          -.--  **
** test_mix.test_delta_xfail      PASS          30.00           0.00     608518.95  **
**************************************************************************************
** TESTS=4 PASS=2 FAIL=1 SKIP=1                 60.00           0.03       1933.00  **
''';

      const realPreview = '''
** TEST                                  STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
**********************************************************************************************
** test_mix.test_alpha_pass               PASS          10.00           0.00     116550.18  **
** test_mix.test_bravo_fail               FAIL          20.00           0.00     196656.91  **
** test_mix.test_charlie_skip             SKIP           0.00           0.00          -.--  **
** test_mix.test_delta_xfail             XFAIL          30.00           0.00     514578.92  **
**********************************************************************************************
** TESTS=4 PASS=1 FAIL=1 SKIP=1 XFAIL=1                 60.00           0.03       2172.23  **
''';

      test('module-qualified names parse (they did not before)', () {
        final rows = parseCocotbPerTestRows(realDefault);
        expect(rows, hasLength(4));
        expect(rows[0].name, 'test_mix.test_alpha_pass');
        expect(rows[0].status, 'PASS');
        expect(rows[0].simTimeNs, 10.0);
        expect(rows[2].name, 'test_mix.test_charlie_skip');
        expect(rows[2].status, 'SKIP');
      });

      test('the header row is not mistaken for a test', () {
        final rows = parseCocotbPerTestRows(realDefault);
        expect(rows.map((r) => r.name), isNot(contains('TEST')));
      });

      test('xfail reports PASS by default — 2.1 without the preview flag', () {
        final summary = parseCocotbSummary(realDefault)!;
        expect(summary.tests, 4);
        expect(summary.passes, 2, reason: 'the xfailed test counts as PASS');
        expect(summary.xfails, 0, reason: 'no XFAIL counter without preview');
        expect(summary.expectedCompletions, 3);
      });

      test('XFAIL counter parses under COCOTB_PREVIEW', () {
        final summary = parseCocotbSummary(realPreview)!;
        expect(summary.tests, 4);
        expect(summary.passes, 1);
        expect(summary.fails, 1);
        expect(summary.skips, 1);
        expect(summary.xfails, 1);
      });

      test('XFAIL rows parse under COCOTB_PREVIEW', () {
        final rows = parseCocotbPerTestRows(realPreview);
        expect(rows, hasLength(4));
        expect(rows[3].name, 'test_mix.test_delta_xfail');
        expect(rows[3].status, 'XFAIL');
      });

      test('an all-xfail run is a PASS, not a residual failure', () {
        // The regression this guards: XFAIL counts toward TESTS but not
        // toward PASS or SKIP, so `passes + skips == tests` scored a run
        // that behaved exactly as declared as a SimCrux failure.
        final summary = parseCocotbSummary(
          '** TESTS=1 PASS=0 FAIL=0 SKIP=0 XFAIL=1   30.00   0.00   1.00 **',
        )!;
        expect(summary.fails, 0);
        expect(summary.expectedCompletions, summary.tests);
      });

      test('older output without XFAIL is unchanged', () {
        final summary = parseCocotbSummary(
          '** TESTS=4 PASS=3 FAIL=1 SKIP=0 **',
        )!;
        expect(summary.xfails, 0);
        expect(summary.expectedCompletions, 3);
      });
    });
  });
}
