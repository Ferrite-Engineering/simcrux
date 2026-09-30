// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// A headless invocation's stdout is what a script reads, and its failures
// belong on stderr. A `--ci --json` run's stdout is the results document a
// pipeline parses; a release build presents a framework error through
// `debugPrint`, which prints to stdout, so an error during the run landed
// beside the JSON. The import and export-dashboard branches reported their
// failures with `print`, which is stdout too. These drive the real branches
// of `bootstrap` with stdout, stderr and `print` captured, and hold stdout to
// exactly what each meant to write there.

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/resource_lock.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// An in-process `icarus` driver that passes, reporting a framework error
/// through [FlutterError.reportError] while it runs.
class _ErrorReportingDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Framework error (stdout test)';

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
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fixed';

  @override
  Future<CompileResult> compile(CompileRequest request) async =>
      const CompileResult(
        success: true,
        artifactPath: 'noop',
        stdout: '',
        stderr: '',
      );

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('a framework error during the run'),
        stack: StackTrace.current,
        library: 'ci stdout test',
      ),
    );
    final now = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: now,
      finishedAt: now.add(const Duration(milliseconds: 1)),
    );
  }

  @override
  void cancel(String testId) {}
}

/// A scheduler whose run ends in an error, so `bootstrap` reports it.
class _ThrowingScheduler implements JobScheduler {
  @override
  Map<String, ResourceLock> get heldLocks => const {};

  @override
  RegressionStatus statusOf(String runId) => RegressionStatus(
    runId: runId,
    totalTests: 0,
    completedTests: 0,
    runningTests: 0,
    isFinished: false,
  );

  @override
  Stream<RegressionEvent> submit(RegressionRequest request) =>
      Stream<RegressionEvent>.error(StateError('the backend went away'));

  @override
  Future<void> cancel(String runId) async {}
}

/// A [io.Stdout] that keeps what is written to it.
class _CapturedStdout implements io.Stdout {
  final StringBuffer text = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  void write(Object? object) => text.write(object);

  @override
  void writeln([Object? object = '']) => text
    ..write(object)
    ..write('\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      text.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => text.writeCharCode(charCode);

  @override
  void add(List<int> data) => text.write(utf8.decode(data));

  @override
  Future<void> flush() async {}

  // Never completes: a sink that reports itself done is one the diagnostics
  // sink stops writing to.
  @override
  Future<void> get done => Completer<void>().future;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<String> _writeConfig() async {
  final dir = await io.Directory.systemTemp.createTemp('simcrux_ci_stdout_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  io.File('${dir.path}/tb.v').writeAsStringSync('module tb; endmodule\n');
  io.File('${dir.path}/simcrux.yaml').writeAsStringSync(
    "version: '1'\n"
    '\n'
    'defaults:\n'
    '  simulator: icarus\n'
    '  pass_fail:\n'
    '    type: exit_code\n'
    '  waveform:\n'
    '    capture: never\n'
    '\n'
    'suites:\n'
    '  smoke:\n'
    '    description: stdout test\n'
    '    tests:\n'
    '      - name: alu\n'
    '        top: tb\n'
    '        sources:\n'
    '          - tb.v\n',
  );
  return '${dir.path}/simcrux.yaml';
}

/// Runs `bootstrap` with the process's stdout and stderr captured, and
/// `print` counted as stdout, which is where it goes.
Future<({String stdout, String stderr})> _runCaptured(
  List<String> args,
  List<Override> overrides,
) async {
  final out = _CapturedStdout();
  final err = _CapturedStdout();
  await io.IOOverrides.runZoned(
    () => runZoned(
      () => bootstrap(args: args, extraOverrides: overrides),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => out.writeln(line),
      ),
    ),
    stdout: () => out,
    stderr: () => err,
  );
  return (stdout: out.text.toString(), stderr: err.text.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A release build presents a framework error with
  // `FlutterError.dumpErrorToConsole`, which prints it through `debugPrint`.
  // Under `flutter test` the widget inspector has replaced that with its
  // structured-error reporter, which posts to the VM service instead and
  // would hide the defect. Put the release handler back before the first
  // `bootstrap` in this file chains onto it.
  late FlutterExceptionHandler? savedOnError;
  setUpAll(() {
    savedOnError = FlutterError.onError;
    FlutterError.onError = FlutterError.dumpErrorToConsole;
  });
  tearDownAll(() => FlutterError.onError = savedOnError);

  late int savedExitCode;
  setUp(() => savedExitCode = io.exitCode);
  tearDown(() => io.exitCode = savedExitCode);

  test('a framework error during a --ci --json run leaves stdout exactly '
      'the JSON', () async {
    final configPath = await _writeConfig();
    io.exitCode = 0;

    final captured = await _runCaptured(
      ['--ci', '--json', configPath],
      [
        simulatorDriverRegistryProvider.overrideWithValue(
          SimulatorDriverRegistry({'icarus': _ErrorReportingDriver()}),
        ),
      ],
    );

    expect(
      captured.stdout,
      '{"totals":{"pass":1}}\n',
      reason:
          'stdout is the document a pipeline parses; the framework error '
          'dump belongs on stderr',
    );
    expect(
      captured.stderr,
      contains('a framework error during the run'),
      reason: 'moved off stdout, not swallowed',
    );
    expect(io.exitCode, 0);
  });

  test(
    'the GUI keeps its console: debugPrint is restored after the run',
    () async {
      final configPath = await _writeConfig();
      final before = debugPrint;

      await _runCaptured(
        ['--ci', '--json', configPath],
        [
          simulatorDriverRegistryProvider.overrideWithValue(
            SimulatorDriverRegistry({'icarus': _ErrorReportingDriver()}),
          ),
        ],
      );

      expect(debugPrint, same(before));
    },
  );

  test('a run that throws reports the error on stderr, not stdout', () async {
    final configPath = await _writeConfig();
    io.exitCode = 0;

    final captured = await _runCaptured(
      ['--ci', '--json', configPath],
      [
        ciSchedulerFactoryProvider.overrideWithValue(
          (_) => _ThrowingScheduler(),
        ),
      ],
    );

    expect(captured.stdout, isEmpty);
    expect(
      captured.stderr,
      contains('simcrux: Bad state: the backend went away'),
    );
    expect(io.exitCode, 2);
  });

  group('the import and export-dashboard branches report a failure on '
      'stderr', () {
    // Each reported its failure with `print`, under a comment calling that
    // stderr-equivalent. `print` is stdout: a script reading the command's
    // output got the error in it, and a log that keeps only stderr had
    // nothing. The standalone binary already sent these to stderr.
    late io.Directory dir;
    setUp(() async {
      dir = await io.Directory.systemTemp.createTemp('simcrux_headless_');
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    Future<void> expectFailureOnStderr(
      List<String> args,
      String message,
    ) async {
      io.exitCode = 0;
      final captured = await _runCaptured(args, const <Override>[]);
      expect(captured.stdout, isEmpty, reason: 'nothing was written');
      expect(captured.stderr, contains(message));
      expect(io.exitCode, 2);
    }

    test('--import-fusesoc, a file that is not a CAPI2 core', () async {
      final core = '${dir.path}/bad.core';
      io.File(core).writeAsStringSync('name: x\n');
      await expectFailureOnStderr(
        ['--import-fusesoc', core],
        'simcrux: FuseSoCImportException',
      );
    });

    test('--import-fusesoc, a core that does not exist', () async {
      await expectFailureOnStderr(
        ['--import-fusesoc', '${dir.path}/missing.core'],
        'simcrux: import-fusesoc failed:',
      );
    });

    test('import-riscv-arch-test, no checkout named', () async {
      await expectFailureOnStderr(
        ['import-riscv-arch-test'],
        'expects exactly one positional argument',
      );
    });

    test('import-riscv-arch-test, a checkout that is not there', () async {
      await expectFailureOnStderr(
        ['import-riscv-arch-test', '${dir.path}/nope'],
        'simcrux: RiscvImportException',
      );
    });

    test('export-dashboard, no output directory named', () async {
      await expectFailureOnStderr(
        ['export-dashboard'],
        'expects exactly one positional argument (the output directory)',
      );
    });

    test('export-dashboard, a results file that does not exist', () async {
      await expectFailureOnStderr(
        [
          'export-dashboard',
          '--results',
          '${dir.path}/missing.ndjson',
          '${dir.path}/out',
        ],
        'simcrux export-dashboard: PathNotFoundException',
      );
    });
  });
}
