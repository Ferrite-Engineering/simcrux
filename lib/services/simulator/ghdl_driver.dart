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

/// [SimulatorDriver] for [GHDL](https://ghdl.github.io/ghdl/).
///
/// GHDL is the open-source VHDL simulator. Its standard flow is three
/// sequential commands inside the per-test working directory:
///
/// 1. `ghdl -a [--std=08] [--ieee=synopsys] [--workdir=<wd>] <sources>` — analyze
/// 2. `ghdl -e [--std=08] [--workdir=<wd>] <top>`                      — elaborate
/// 3. `ghdl -r [--std=08] [--workdir=<wd>] <top> [--vcd=…|--fst=…|--wave=…]` — run
///
/// The analyze + elaborate stages constitute the "compile" pass; the
/// run stage is "execute". Both stages stream through the unified
/// log scrape so the inspector can show analyze errors alongside the
/// run output. The driver chooses the waveform output flag at execute
/// time based on the project's [WaveformPolicy.format]:
///
/// - [WaveformFormat.vcd] → `--vcd=<wd>/sim.vcd`
/// - [WaveformFormat.fst] → `--fst=<wd>/sim.fst`
/// - [WaveformFormat.ghw] → `--wave=<wd>/sim.ghw` (GHW native)
///
/// **Backend.** GHDL ships with three runtime back-ends: `mcode`
/// (in-process interpreter, default, no extra dependency); `llvm`
/// (compiles to native via LLVM); and `gcc` (compiles to native via
/// GCC). The driver uses whatever back-end the locally installed
/// `ghdl` binary was built with — the back-end selection happens at
/// distribution time, not on the command line. The user signals their
/// preference via the project's `simulators.ghdl.options.backend`
/// field (`mcode` / `llvm` / `gcc`); when set, the driver only
/// succeeds if `ghdl --version` reports the matching backend. This
/// keeps the override useful (a user can pin a particular install)
/// without spawning unsupported flags.
///
/// Pass/fail classification is **not** the driver's responsibility.
/// The driver reports a best-guess based on the `ghdl -r` exit code
/// ([TestStatus.pass] / [TestStatus.fail]); the scheduler re-classifies
/// through the configured `PassFailDetector` after the run.
///
/// Cancellation: [cancel] kills whichever subprocess is currently
/// alive for that test id (analyze, elaborate, or run). SIGTERM
/// first; SIGKILL after `killGrace` expires (see
/// [ProcessBackedSimulatorDriver]).
///
/// Binary unavailability surfaces as [SimulatorNotAvailableException]
/// (shared with the Icarus, Verilator, and Cocotb drivers).
class GhdlDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [GhdlDriver].
  ///
  /// [launcher] is injected so tests can drive the driver against a
  /// scripted `TestProcess`. [ghdlBinary] is the executable name
  /// resolved via the project's [SimulatorBinaryConfig]. [standard] is
  /// the VHDL revision passed to `--std` on every stage; defaults to
  /// `08` (VHDL-2008) — the modern revision most simulators target
  /// today.
  GhdlDriver({
    super.launcher,
    super.reaper,
    this.ghdlBinary = 'ghdl',
    this.standard = '08',
    this.ieee = 'synopsys',
    super.killGrace,
  });

  /// The `ghdl` executable name resolved when [SimulatorBinaryConfig]
  /// is `system` or `bundled`. Defaults to `ghdl` ($PATH).
  final String ghdlBinary;

  /// VHDL standard revision passed to `--std`. Default `08` for
  /// VHDL-2008. Users override per-project via the `simulators.ghdl`
  /// config block when they need `93` / `02`.
  final String standard;

  /// IEEE library variant passed to `--ieee`. Default `synopsys`
  /// (provides `std_logic_arith`, the de-facto industry standard).
  /// Some pure-2008 designs require `standard` instead; users override
  /// via project config.
  final String ieee;

  @override
  String get id => 'ghdl';

  @override
  String get displayName => 'GHDL';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.vhdl},
    supportsVcd: true,
    supportsFst: true,
    supportsCocotb: true,
    requiresSeparateCompileStep: true,
    emitsStructuredOutput: false,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) {
    // GHDL prints e.g. "GHDL 4.0.0-dev (…) [Dunoon edition]" followed by
    // GNAT + code-generator lines; the banner is the first line.
    return detectVersionOf(resolveBinary(config, ghdlBinary));
  }

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    final ghdl = resolveBinary(request.binaryConfig, ghdlBinary);
    final wd = request.workingDirectory;
    // Bounded line-by-line capture shared by both stages
    // (scheduler-supplied when running inside a regression) — a chatty
    // compile step cannot grow an unbounded buffer before the result
    // string is materialized.
    final stdoutCapture = request.stdoutCapture ?? BoundedLogCapture();
    final stderrCapture = request.stderrCapture ?? BoundedLogCapture();

    // Stage 1 — analyze.
    final analyzeArgs = <String>[
      '-a',
      '--std=$standard',
      '--ieee=$ieee',
      '--workdir=$wd',
      for (final inc in request.test.includeDirs) '-P$inc',
      ...request.test.sources,
    ];
    final analyzeOk = await _runStage(
      executable: ghdl,
      args: analyzeArgs,
      request: request,
      stdoutCapture: stdoutCapture,
      stderrCapture: stderrCapture,
    );
    if (!analyzeOk) {
      return CompileResult(
        success: false,
        artifactPath: null,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    }

    // Stage 2 — elaborate.
    final elabArgs = <String>[
      '-e',
      '--std=$standard',
      '--ieee=$ieee',
      '--workdir=$wd',
      request.test.top,
    ];
    final elabOk = await _runStage(
      executable: ghdl,
      args: elabArgs,
      request: request,
      stdoutCapture: stdoutCapture,
      stderrCapture: stderrCapture,
    );
    if (!elabOk) {
      return CompileResult(
        success: false,
        artifactPath: null,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    }

    // The elaborated artifact lives inside the working directory as a
    // binary named after the top entity (mcode) or as a native exe
    // (llvm/gcc). We treat the working directory itself as the
    // artifact reference — the execute stage re-invokes `ghdl -r`
    // pointing at the same workdir, which is the canonical pattern.
    return CompileResult(
      success: true,
      artifactPath: wd,
      stdout: stdoutCapture.text,
      stderr: stderrCapture.text,
    );
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final ghdl = resolveBinary(request.binaryConfig, ghdlBinary);
    final wd = request.workingDirectory;
    final startedAt = DateTime.now().toUtc();

    // VHDL has no standard runtime seed plusarg, so GHDL is report-only:
    // it surfaces the effective seed (requested, else clock-derived) for
    // the reproducibility tuple without injecting it.
    final effectiveSeed = resolveExecutionSeed(request.test.seed);

    final args = <String>[
      '-r',
      '--std=$standard',
      '--ieee=$ieee',
      '--workdir=$wd',
      request.test.top,
      ..._runWaveformArgs(request, wd),
    ];

    await runProcessStreaming(
      request: request,
      executable: ghdl,
      args: args,
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: ghdl,
      unavailableMessage:
          '$ghdl not available (${request.binaryConfig.source})',
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

  /// Run one of the three GHDL stages, streaming stdout/stderr into
  /// the shared bounded compile captures and returning `true` on a
  /// zero exit code. Throws [SimulatorNotAvailableException] when the
  /// binary cannot be invoked (the convention every driver follows).
  Future<bool> _runStage({
    required String executable,
    required List<String> args,
    required CompileRequest request,
    required BoundedLogCapture stdoutCapture,
    required BoundedLogCapture stderrCapture,
  }) async {
    try {
      final process = await reaper.spawnGrouped(
        executable,
        args,
        environment: augmentEnvironment(request.binaryConfig.extraEnv),
        workingDirectory: request.workingDirectory,
      );
      trackProcess(request.test.id, process);
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();
      final stdoutSub = process.stdout.listen(
        stdoutCapture.addLine,
        onDone: stdoutDone.complete,
      );
      final stderrSub = process.stderr.listen(
        stderrCapture.addLine,
        onDone: stderrDone.complete,
      );
      final exit = await process.exitCode;
      await Future.wait<void>([stdoutDone.future, stderrDone.future]);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      untrackProcess(request.test.id);
      return exit == 0;
    } on ProcessException catch (e) {
      untrackProcess(request.test.id);
      throw SimulatorNotAvailableException(
        simulatorId: id,
        binary: executable,
        source: request.binaryConfig.source,
        cause: e,
      );
    } on Object {
      untrackProcess(request.test.id);
      rethrow;
    }
  }

  List<String> _runWaveformArgs(ExecuteRequest request, String wd) {
    final policy = request.test.waveform;
    switch (policy.capture) {
      case WaveformCapturePolicy.onDemand:
      case WaveformCapturePolicy.never:
        return const <String>[];
      case WaveformCapturePolicy.always:
      case WaveformCapturePolicy.onFailure:
        switch (policy.format) {
          case WaveformFormat.vcd:
            return <String>['--vcd=${p.join(wd, 'sim.vcd')}'];
          case WaveformFormat.fst:
            return <String>['--fst=${p.join(wd, 'sim.fst')}'];
          case WaveformFormat.ghw:
            return <String>['--wave=${p.join(wd, 'sim.ghw')}'];
        }
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
      if (ext == '.fst' || ext == '.vcd' || ext == '.ghw') {
        candidates.add(entity);
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return candidates.first.path;
  }
}
