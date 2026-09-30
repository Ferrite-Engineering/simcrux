// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

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
      final stdoutSub = process.stdout.listen(stdoutCapture.addLine);
      final stderrSub = process.stderr.listen(stderrCapture.addLine);
      final exit = await process.exitCode;
      await stdoutSub.cancel();
      await stderrSub.cancel();
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

    await runProcessStreaming(
      request: request,
      executable: vvp,
      args: args,
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: vvp,
      unavailableMessage: '$vvp not available (${request.binaryConfig.source})',
      buildFinished: (exitCode, process) async {
        final waveform = await _locateWaveform(request);
        final status = exitCode == 0 ? TestStatus.pass : TestStatus.fail;
        return TestExecutionFinished(
          status: status,
          exitCode: exitCode,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          waveformPath: waveform,
          killSignal: process.killSignal,
          effectiveSeed: effectiveSeed,
        );
      },
    );
  }

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
