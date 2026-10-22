// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_io/crux_io.dart' show ProcessStreamDrain;
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/enums/waveform_capture_policy.dart';
import 'package:simcrux/domain/enums/waveform_format.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/simulator/execution_seed.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// [SimulatorDriver] for [Icarus Verilog](https://github.com/steveicarus/iverilog).
///
/// Two-step flow:
///
/// 1. `iverilog -g<gen> -o <wd>/sim.vvp -s<top> [-Iinc] [-Dkey=val] sources…`
/// 2. `vvp <wd>/sim.vvp [-fst|-vcd]`
///
/// Waveform capture: Icarus testbenches drive `$dumpfile/$dumpvars`
/// themselves; the driver only flips between `-fst` and `-vcd` on the
/// `vvp` command line so the testbench's default extension lines up
/// with the project's [WaveformPolicy.format]. After execution, the
/// driver globs the working directory for a freshly produced
/// `.fst` / `.vcd` and reports its path as the waveform artifact.
///
/// Pass/fail classification is **not** the driver's responsibility.
/// The driver reports a best-guess based on `vvp`'s exit code
/// ([TestStatus.pass] / [TestStatus.fail]) and emits the captured
/// log stream verbatim. The scheduler re-classifies through the
/// configured `PassFailDetector` after the run completes.
///
/// **One thing the exit code cannot say.** `vvp` exits 0 when a test calls
/// `$error` and then `$finish`; upstream treats that as intended and points
/// at `$fatal` / `$finish_and_return`. It does print the failure, as an
/// `ERROR: <file>:<line>: <message>` line (and `FATAL:` for `$fatal`), so
/// the driver watches its own output for those and reports `fail` with the
/// first such line as the failure message even when the exit code is 0.
/// The default `exit_code` detector defers to that (see
/// `resolveFinalStatus` in the scheduler): a test that printed `ERROR:` and
/// exited 0 is a failing test, not a passing one.
///
/// Cancellation: `cancel(testId)` kills whichever subprocess is live
/// for that test — compile or execute. SIGTERM is sent first; the
/// scheduler is responsible for the SIGKILL escalation after a grace
/// period. (See [ProcessBackedSimulatorDriver] for the shared
/// process/reaper machinery.)
class IcarusDriver extends ProcessBackedSimulatorDriver {
  /// Creates an [IcarusDriver].
  ///
  /// [launcher] is injected so tests can drive the driver against a
  /// scripted [TestProcess]. Defaults to the production `Process.start`
  /// launcher reused from [LocalJobScheduler].
  ///
  /// [iverilogBinary] / [vvpBinary] are the executable names (or
  /// absolute paths) the driver resolves to when the project's
  /// [SimulatorBinaryConfig] uses `bundled` or `system`. The default
  /// values (`iverilog` / `vvp`) rely on the host's `$PATH`. A bundled
  /// build would override these with absolute paths into the
  /// bundled-binary tree.
  IcarusDriver({
    super.launcher,
    super.reaper,
    this.iverilogBinary = 'iverilog',
    this.vvpBinary = 'vvp',
    this.generation = '2012',
    super.killGrace,
  });

  /// The `iverilog` executable name used when [SimulatorBinaryConfig]
  /// is `system` or `bundled`. Defaults to `iverilog` ($PATH).
  final String iverilogBinary;

  /// The `vvp` executable name used when [SimulatorBinaryConfig] is
  /// `system` or `bundled`. Defaults to `vvp` ($PATH).
  final String vvpBinary;

  /// Verilog generation passed to `iverilog -g`. Defaults to `2012`
  /// (the de-facto-modern SystemVerilog level Icarus supports).
  final String generation;

  @override
  String get id => 'icarus';

  @override
  String get displayName => 'Icarus Verilog';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {
      HdlLanguage.verilog,
      HdlLanguage.systemVerilog,
    },
    supportsVcd: true,
    supportsFst: true,
    supportsCocotb: true,
    requiresSeparateCompileStep: true,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) {
    // Icarus prints the banner ("Icarus Verilog version 12.0 (stable)…")
    // in response to `-V`; older builds wrote to stderr, which
    // [detectVersionOf] already tolerates.
    return detectVersionOf(
      resolveBinary(config, iverilogBinary),
      versionArgs: const <String>['-V'],
    );
  }

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    final iverilog = resolveBinary(request.binaryConfig, iverilogBinary);
    final wd = request.workingDirectory;
    final artifact = p.join(wd, 'sim.vvp');

    final args = <String>[
      '-g$generation',
      '-o',
      artifact,
      '-s',
      request.test.top,
      // A generated second top (gate level's port dump, its supply tie).
      for (final extra in request.test.extraTops) ...<String>['-s', extra],
      for (final inc in request.test.includeDirs) '-I$inc',
      for (final entry in request.test.defines.entries)
        '-D${entry.key}=${entry.value}',
      ...request.test.sources,
    ];

    try {
      final process = await reaper.spawnGrouped(
        iverilog,
        args,
        environment: augmentEnvironment(request.binaryConfig.extraEnv),
        workingDirectory: wd,
      );
      trackProcess(request.test.id, process);
      // Bounded line-by-line capture (scheduler-supplied when running
      // inside a regression) — a chatty compile step cannot grow an
      // unbounded buffer before the result string is materialized.
      final stdoutCapture = request.stdoutCapture ?? BoundedLogCapture();
      final stderrCapture = request.stderrCapture ?? BoundedLogCapture();
      // Read to end-of-file, not until the exit code: the two reach Dart on
      // separate channels, and cancelling the subscriptions on the exit
      // dropped the one line a failed compile had to say, so the inspector
      // showed an empty diagnostic for it.
      final drains = <ProcessStreamDrain<String>>[
        ProcessStreamDrain<String>(process.stdout, stdoutCapture.addLine),
        ProcessStreamDrain<String>(process.stderr, stderrCapture.addLine),
      ];
      final exit = await process.exitCode;
      await drainCompileOutput(
        exitCode: exit,
        drains: drains,
        process: process,
        stderrCapture: stderrCapture,
        tool: iverilog,
      );
      untrackProcess(request.test.id);
      final success = exit == 0 && File(artifact).existsSync();
      return CompileResult(
        success: success,
        artifactPath: success ? artifact : null,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    } on ProcessException catch (e) {
      untrackProcess(request.test.id);
      throw SimulatorNotAvailableException(
        simulatorId: id,
        binary: iverilog,
        source: request.binaryConfig.source,
        cause: e,
      );
    } on Object {
      untrackProcess(request.test.id);
      rethrow;
    }
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final vvp = resolveBinary(request.binaryConfig, vvpBinary);
    final artifactPath =
        request.compileResult?.artifactPath ??
        p.join(request.workingDirectory, 'sim.vvp');
    final startedAt = DateTime.now().toUtc();

    // Resolve the effective seed (requested, else clock-derived) and pass
    // it to the testbench as a `+seed=` plusarg so the run is reproducible;
    // it is reported back via TestExecutionFinished.effectiveSeed.
    final effectiveSeed = resolveExecutionSeed(request.test.seed);
    final args = <String>[
      artifactPath,
      ..._vvpWaveformArgs(request),
      '+seed=$effectiveSeed',
    ];

    // The first `ERROR:` / `FATAL:` line vvp printed, if any. See the class
    // doc: with `$error` + `$finish` the exit code is 0 and this is the
    // only sign the test failed.
    String? firstErrorLine;

    await runProcessStreaming(
      request: request,
      executable: vvp,
      args: args,
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: vvp,
      unavailableMessage: '$vvp not available (${request.binaryConfig.source})',
      onLine: (line, {required fromStderr}) {
        if (firstErrorLine == null && isIcarusErrorLine(line)) {
          firstErrorLine = line.trim();
        }
      },
      buildFinished: (exitCode, process) async {
        final waveform = await _locateWaveform(request);
        final errorLine = firstErrorLine;
        final status = exitCode == 0 && errorLine == null
            ? TestStatus.pass
            : TestStatus.fail;
        return TestExecutionFinished(
          status: status,
          exitCode: exitCode,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          waveformPath: waveform,
          failureMessage: errorLine,
          killSignal: process.killSignal,
          effectiveSeed: effectiveSeed,
        );
      },
    );
  }

  /// Whether [line] is one of the severity lines Icarus prints for
  /// `$error` and `$fatal`.
  ///
  /// Icarus writes `ERROR: <file>:<line>: <message>` and
  /// `FATAL: <file>:<line>: <message>` at the start of a line (the
  /// continuation `Time: … Scope: …` line is indented). Anchored to the line
  /// start so a testbench `$display("no ERROR: here")` is not read as one.
  static bool isIcarusErrorLine(String line) => _icarusErrorLine.hasMatch(line);

  static final RegExp _icarusErrorLine = RegExp('^(ERROR|FATAL): ');

  // ── helpers ────────────────────────────────────────────────────────

  List<String> _vvpWaveformArgs(ExecuteRequest request) {
    final policy = request.test.waveform;
    switch (policy.capture) {
      case WaveformCapturePolicy.onDemand:
      case WaveformCapturePolicy.never:
        return const <String>[];
      case WaveformCapturePolicy.always:
      case WaveformCapturePolicy.onFailure:
        // `vvp -fst` requests an FST dump where the testbench would
        // otherwise emit VCD. Default (no flag) keeps the
        // testbench-declared format (typically VCD).
        return policy.format == WaveformFormat.fst
            ? const <String>['-fst']
            : const <String>[];
    }
  }

  Future<String?> _locateWaveform(ExecuteRequest request) async {
    final policy = request.test.waveform;
    if (policy.capture == WaveformCapturePolicy.never) return null;
    final wd = Directory(request.workingDirectory);
    if (!wd.existsSync()) return null;
    final candidates = <FileSystemEntity>[];
    for (final entity in wd.listSync()) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext == '.fst' || ext == '.vcd') {
        candidates.add(entity);
      }
    }
    if (candidates.isEmpty) return null;
    // Pick the most recently modified file as the produced waveform.
    candidates.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return candidates.first.path;
  }
}
