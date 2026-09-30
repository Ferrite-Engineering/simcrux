// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:simcrux/app.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/logging/severe_log_stderr_sink.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

class _Capture implements StreamConsumer<List<int>> {
  final buffer = StringBuffer();

  @override
  Future<void> addStream(Stream<List<int>> stream) =>
      stream.forEach((bytes) => buffer.write(utf8.decode(bytes)));

  @override
  Future<void> close() async {}
}

/// A process stdio stream, installed through [IOOverrides], whose bytes land
/// in a [_Capture].
class _StdioStandIn implements Stdout {
  _StdioStandIn(_Capture capture) : _sink = IOSink(capture);

  final IOSink _sink;

  @override
  void write(Object? object) => _sink.write(object);

  @override
  void writeln([Object? object = '']) => _sink.writeln(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  @override
  void add(List<int> data) => _sink.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _sink.addStream(stream);

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> get done => _sink.done;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What one run wrote to the process's stdout and stderr, and through
/// `print`.
class _Streams {
  final out = _Capture();
  final err = _Capture();
  final printed = <String>[];

  String get stdoutText => out.buffer.toString();
  String get stderrText => err.buffer.toString();

  /// Runs [body] with stdout, stderr and `print` captured.
  Future<void> capture(Future<void> Function() body) async {
    final stdoutStandIn = _StdioStandIn(out);
    final stderrStandIn = _StdioStandIn(err);
    await IOOverrides.runZoned(
      () => runZoned(
        () async {
          await body();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      ),
      stdout: () => stdoutStandIn,
      stderr: () => stderrStandIn,
    );
  }
}

/// Passes its one test and logs a SEVERE record while it runs, the way an
/// uncaught error during a `--ci` run reaches the log.
class _SevereLoggingDriver implements SimulatorDriver {
  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Logs SEVERE (diagnostic sinks test)';

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
    Logger('flutter').severe('Uncaught: Bad state: mid-run failure');
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

Future<String> _writeConfig() async {
  final dir = await Directory.systemTemp.createTemp('simcrux_sinks_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  File('${dir.path}/tb.v').writeAsStringSync('module tb; endmodule\n');
  File('${dir.path}/simcrux.yaml').writeAsStringSync(
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
    '    description: sinks test\n'
    '    tests:\n'
    '      - name: alu\n'
    '        top: tb\n'
    '        sources:\n'
    '          - tb.v\n',
  );
  return '${dir.path}/simcrux.yaml';
}

/// The uncaught-error path, end to end: what `bootstrap()` attaches must carry
/// a framework error and an uncaught async error to stderr, and put nothing on
/// stdout.
///
/// Until the stderr sink existed, both reached only the issue reporter's
/// in-memory buffer, so on a user's machine they were gone with the session.
/// stdout is off limits: a `--ci` run writes its summary there, and `--json`
/// its results, for a CI job to parse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The handlers `captureFlutterErrors` chains to. The test binding's own
    // would fail these tests for the errors they report on purpose.
    final previousFlutter = FlutterError.onError;
    final previousDispatcher = PlatformDispatcher.instance.onError;
    FlutterError.onError = (_) {};
    PlatformDispatcher.instance.onError = (_, _) => true;
    addTearDown(() {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousDispatcher;
    });
    // Each test attaches the process-wide sink to its own stand-in stderr.
    addTearDown(SevereLogStderrSink.instance.detach);
  });

  test('uncaught framework and async errors reach stderr, and nothing '
      'reaches stdout', () async {
    final streams = _Streams();
    await streams.capture(() async {
      // No override: the process-wide sink, resolving the process's stderr
      // exactly as `bootstrap()` does.
      attachDiagnosticSinks();
      FlutterError.onError!(
        FlutterErrorDetails(exception: StateError('frame failed')),
      );
      PlatformDispatcher.instance.onError!(
        StateError('async failed'),
        StackTrace.current,
      );
      Logger('simcrux.test').warning('below the threshold');
    });

    expect(
      streams.stderrText,
      contains('SEVERE flutter: Bad state: frame failed'),
    );
    expect(
      streams.stderrText,
      contains('SEVERE flutter: Uncaught: Bad state: async failed'),
    );
    expect(streams.stderrText, isNot(contains('below the threshold')));
    expect(streams.stdoutText, isEmpty, reason: 'nothing on stdout');
    expect(streams.printed, isEmpty, reason: 'print() reaches stdout too');
  });

  for (final (flag, output, expected) in [
    (null, 'text', 'simcrux: 1 tests · 1 passed\n'),
    ('--json', 'JSON', '{"totals":{"pass":1}}\n'),
  ]) {
    test('a SEVERE record during a --ci run goes to stderr and leaves the '
        '$output result alone on stdout', () async {
      final configPath = await _writeConfig();
      final saved = exitCode;
      addTearDown(() => exitCode = saved);
      exitCode = 0;

      final streams = _Streams();
      await streams.capture(
        () => bootstrap(
          args: ['--ci', configPath, ?flag],
          extraOverrides: [
            simulatorDriverRegistryProvider.overrideWithValue(
              SimulatorDriverRegistry({'icarus': _SevereLoggingDriver()}),
            ),
          ],
        ),
      );

      expect(exitCode, 0);
      expect(streams.stdoutText, expected);
      expect(streams.printed, isEmpty);
      expect(
        streams.stderrText,
        contains('SEVERE flutter: Uncaught: Bad state: mid-run failure'),
      );
    });
  }
}
