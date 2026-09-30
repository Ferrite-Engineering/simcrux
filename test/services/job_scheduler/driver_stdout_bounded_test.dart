// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/domain/models/regression_request.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// A driver that streams a fixed list of stdout lines then exits 0,
/// without spawning any process — exercises the scheduler's capture path.
class _ChattyDriver implements SimulatorDriver {
  _ChattyDriver(this.lines);

  final List<String> lines;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Chatty';

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
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

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
    final at = DateTime.now().toUtc();
    for (final line in lines) {
      yield TestLogLine(line: line, fromStderr: false, timestamp: at);
    }
    yield TestExecutionFinished(
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: at,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

/// A driver with a separate compile step that streams [compileLines]
/// into the request's bounded captures (the production driver shape
/// after the streamed-capture fix), then executes silently and passes.
class _CompilingDriver implements SimulatorDriver {
  _CompilingDriver({required this.compileLines});

  final List<String> compileLines;

  /// True once `compile` observed non-null captures on its request.
  bool sawRequestCaptures = false;

  @override
  String get id => 'fake-compile';

  @override
  String get displayName => 'Compiling';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.verilog},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    requiresSeparateCompileStep: true,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async => 'fake';

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    sawRequestCaptures =
        request.stdoutCapture != null && request.stderrCapture != null;
    final stdoutCapture = request.stdoutCapture ?? BoundedLogCapture();
    compileLines.forEach(stdoutCapture.addLine);
    return CompileResult(
      success: true,
      artifactPath: 'noop',
      stdout: stdoutCapture.text,
      stderr: '',
    );
  }

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) async* {
    final at = DateTime.now().toUtc();
    yield TestExecutionFinished(
      status: TestStatus.pass,
      exitCode: 0,
      startedAt: at,
      finishedAt: DateTime.now().toUtc(),
    );
  }

  @override
  void cancel(String testId) {}
}

void main() {
  group('BoundedLogCapture', () {
    test('1e6 lines stay bounded with a non-zero dropped counter', () {
      final cap = BoundedLogCapture(maxLines: 5000);
      for (var i = 0; i < 1000000; i++) {
        cap.addLine('line $i');
      }
      expect(cap.lineCount, 5000);
      expect(cap.droppedLines, 995000);
      // Head-dropped: the most recent line is retained, the oldest is gone.
      expect(cap.text, contains('line 999999'));
      expect(cap.text, isNot(contains('line 0\n')));
    });

    test('addBlob splits and bounds a multi-line blob', () {
      final cap = BoundedLogCapture(maxLines: 3)
        ..addBlob(List<String>.generate(10, (i) => 'l$i').join('\n'));
      expect(cap.lineCount, 3);
      expect(cap.droppedLines, 7);
    });

    test('at-capacity appends are O(1), not a full-list shift per line', () {
      // CPU-shaped companion to the flat-memory assertions above: once
      // the ring is full, each append must drop-head + add-tail in
      // constant time. The regression this guards (`removeRange` on a
      // plain List) shifts all retained lines per append — 100k lines ×
      // 200k appends ≈ 2e10 pointer moves, minutes of CPU; the
      // ListQueue ring finishes in milliseconds.
      final cap = BoundedLogCapture();
      for (var i = 0; i < BoundedLogCapture.kDefaultMaxCapturedLogLines; i++) {
        cap.addLine('fill $i');
      }
      final stopwatch = Stopwatch()..start();
      for (var i = 0; i < 200000; i++) {
        cap.addLine('line $i');
      }
      stopwatch.stop();
      expect(cap.lineCount, BoundedLogCapture.kDefaultMaxCapturedLogLines);
      expect(cap.droppedLines, 200000);
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(2000),
        reason:
            '200k at-capacity appends must be linear-time overall; '
            'a per-append head shift makes this take minutes',
      );
    });
  });

  group('compile output streams into the scheduler captures', () {
    test(
      'a compile-step driver receives the attempt captures and the '
      'ring bound applies while compile lines stream — an early '
      'compile fail token beyond the cap is dropped',
      () async {
        final driver = _CompilingDriver(
          compileLines: <String>[
            'ERROR_EARLY in compile banner', // line 0 — beyond the cap
            for (var i = 1; i < 10; i++) 'compile progress $i',
          ],
        );
        final scheduler = LocalJobScheduler(
          driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
          config: RegressionConfig(
            projectFilePath: '/p/simcrux.yaml',
            schemaVersion: '1',
            suites: const [],
            simulatorBinaries: const {},
          ),
          maxCapturedLogLines: 5,
        );
        final spec = TestSpec(
          id: 'unit/compiling',
          name: 'compiling',
          suiteName: 'unit',
          simulatorId: 'fake-compile',
          top: 'tb',
          passFail: const RegexPassFailConfig(failPattern: 'ERROR_EARLY'),
        );
        final events = await scheduler
            .submit(RegressionRequest(runId: 'r1', tests: [spec]))
            .toList();
        final result = events.whereType<TestFinished>().single.result;
        // The scheduler handed its bounded captures to compile().
        expect(driver.sawRequestCaptures, isTrue);
        // The bounded capture dropped the early ERROR_EARLY compile
        // line, so the regex fail-detector never sees it and the
        // exit-0 default stands. Reverting the streamed capture (or
        // re-adding the whole compile blob after the fact) makes the
        // token reappear and this goes red.
        expect(result.status, TestStatus.pass);
      },
    );
  });

  group('scheduler capture is bounded', () {
    test(
      'an early fail token beyond the cap is dropped, so it does not '
      'mis-classify — reverting to an unbounded buffer (the mutation) '
      'makes this red',
      () async {
        final lines = <String>[
          'UVM_ERROR: ERROR_EARLY at t=0', // line 0 — beyond the cap
          for (var i = 1; i < 10; i++) 'progress line $i',
        ];
        final driver = _ChattyDriver(lines);
        final scheduler = LocalJobScheduler(
          driverRegistry: SimulatorDriverRegistry({driver.id: driver}),
          config: RegressionConfig(
            projectFilePath: '/p/simcrux.yaml',
            schemaVersion: '1',
            suites: const [],
            simulatorBinaries: const {},
          ),
          // Keep only the most recent 5 lines: the early error is dropped.
          maxCapturedLogLines: 5,
        );
        final spec = TestSpec(
          id: 'unit/chatty',
          name: 'chatty',
          suiteName: 'unit',
          simulatorId: 'fake',
          top: 'tb',
          passFail: const RegexPassFailConfig(failPattern: 'ERROR_EARLY'),
        );
        final events = await scheduler
            .submit(RegressionRequest(runId: 'r1', tests: [spec]))
            .toList();
        final result = events.whereType<TestFinished>().single.result;
        // Bounded capture dropped the early ERROR_EARLY line, so the regex
        // fail-detector never sees it and the exit-0 default stands.
        expect(result.status, TestStatus.pass);
      },
    );
  });
}
