// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/golden_compare_profile.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/kill_signal.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_reference_model.dart';
import 'package:simcrux/domain/enums/riscv_run_mode.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/riscv_config.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/pass_fail_detector/golden_compare_detector.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/python_traceback_reducer.dart';
import 'package:simcrux/services/simulator/riscv_toolchain_probe.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// [SimulatorDriver] that runs **one RISC-V
/// architectural-compatibility test per job**.
///
/// ## Why one test per job
///
/// The job model has no fan-out: one `TestSpec` yields exactly one
/// `TestExecutionFinished` and exactly one `TestResult`. RISCOF naturally
/// emits *N* results per invocation, so the impedance mismatch is resolved
/// **before** the scheduler by [RiscvArchTestImporter], which enumerates
/// the suite into one inspectable `TestSpec` per architectural test. This
/// driver then runs exactly one of them, reusing
/// [ProcessBackedSimulatorDriver]'s process-tree reaping, timeout
/// escalation and cancellation. No new subprocess handling is written here.
///
/// Shelling RISCOF once for the whole suite is **rejected** as the primary
/// path — it forfeits per-test scheduling,
/// per-test timeouts, cancellation and progress, and would show one
/// dashboard row that either passed or failed for twenty minutes. It
/// survives as the documented secondary
/// [RiscvRunMode.riscofPassthrough] mode.
///
/// ## The three modes share one code path
///
/// | Stage | `normal` | `demo` | `riscof_passthrough` |
/// |---|---|---|---|
/// | compile | cross-compile the test, then run the reference model | stage the committed reference signature | nothing |
/// | execute | run the DUT | stage the committed DUT signature | run the user's RISCOF command |
/// | **tail** | **read both signatures, compare, emit metrics, build the event** | **identical** | **identical** |
///
/// Demo mode skips only the *spawn* steps. It is emphatically **not** the
/// `SIMCRUX_DEMO_RUNNER` / `DemoSimulatorDriver` pattern: an env-gated
/// *separate driver* makes CI exercise a different code path than
/// production, which is the one thing demo mode must not do.
///
/// ## Metrics
///
/// A detector structurally cannot write metrics — `TestResult.metrics` is
/// fed solely from `TestExecutionFinished.metrics` — so this driver
/// calls the same pure [GoldenComparator] the `golden_compare` detector
/// calls and emits `GoldenComparison.toMetrics()`. Both sides therefore
/// agree by construction. On top of the reserved `golden.*` keys it emits
/// the `riscv.*` context the Pro surfaces need, including
/// [kMetricSignatureByteOffset] — the word offset multiplied by
/// `signature.word_size`, which is the byte the Pro diff viewer decodes the
/// divergent instruction at, and the reason `word_size` lives in the
/// `riscv:` block rather than on the (deliberately width-free) comparison
/// profile.
///
/// ## Tiering
///
/// **Never gated.** Not by `LicenseTier`, not by `FeatureGate`, not by a
/// row cap, and not after `kBetaPeriod` flips to `false`. The compatibility
/// verdict is open core because compatibility is RVI's own program and
/// monetizing the verdict itself would read as tolling a standard. The
/// same reasoning, and the deliberate asymmetry with the config loader's
/// `_parameterizationUnlocked` sweep gate, is recorded at
/// `config_loader_riscv.dart` and at `_readGoldenCompareConfig`.
class RiscvArchDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [RiscvArchDriver].
  ///
  /// [platform] overrides the host OS the toolchain guidance is phrased
  /// for; production leaves it null.
  RiscvArchDriver({
    super.launcher,
    super.reaper,
    super.killGrace,
    RiscvHostPlatform? platform,
    // Initializing formals cannot name a private field (Dart's parser
    // disallows `this._platform`), and the field is intentionally private.
    // ignore: prefer_initializing_formals
  }) : _platform = platform;

  final RiscvHostPlatform? _platform;

  /// The `simulatorId` this driver claims. Bare, lowercase, matching the
  /// open-core convention (`icarus`, `verilator`, …).
  static const String kId = RiscvConfig.kSimulatorId;

  /// Filename the compile stage gives the cross-compiled test ELF.
  static const String kElfName = 'test.elf';

  /// Metric key: the extension this test exercises (`I`, `M`, `C`, …).
  /// The Pro per-extension rollup groups on this.
  static const String kMetricExtension = 'riscv.extension';

  /// Metric key: the ISA string the config claimed. Descriptive only —
  /// attestation derives from what passed, never from this.
  static const String kMetricIsa = 'riscv.isa';

  /// Metric key: which reference model produced the golden signature.
  static const String kMetricReferenceModel = 'riscv.reference_model';

  /// Metric key: which of the three modes produced this result. Present so
  /// a demo-mode row can never be mistaken for a real toolchain run in an
  /// exported compatibility report.
  static const String kMetricMode = 'riscv.mode';

  /// Metric key: the architectural test source this row ran.
  static const String kMetricTest = 'riscv.test';

  /// Metric key: the `riscv-arch-test` revision, for report provenance.
  static const String kMetricArchTestRevision = 'riscv.arch_test_revision';

  /// Metric key: bytes per signature word.
  static const String kMetricSignatureWordSize = 'riscv.signature.word_size';

  /// Metric key: the **byte** offset of the first divergence — the word
  /// offset from `golden.mismatch_offset` multiplied by the word size.
  /// This is the coordinate the Pro signature diff viewer decodes at.
  static const String kMetricSignatureByteOffset =
      'riscv.signature.byte_offset';

  @override
  String get id => kId;

  @override
  String get displayName => 'RISC-V Arch Test';

  /// Declares **no HDL languages**, deliberately.
  ///
  /// This driver compiles RISC-V assembly with a cross-compiler; it never
  /// compiles HDL. See the note on [MixedLanguageValidator] in
  /// `config_loader_riscv.dart` for why `riscv_arch` is also absent from
  /// `ConfigLoader.defaultSimulatorLanguages`.
  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const <HdlLanguage>{},
    supportsVcd: false,
    supportsFst: false,
    supportsCocotb: false,
    // The compile stage does real work in `mode: normal` (cross-compile +
    // the reference-model run), and the scheduler registers the live test
    // before `driver.compile` so a cancel arriving mid-compile reaps it.
    requiresSeparateCompileStep: true,
    emitsStructuredOutput: false,
  );

  /// Builds a probe phrased for this driver's platform, spawning through
  /// the base class's non-throwing [detectVersionOf].
  RiscvToolchainProbe probeFor() =>
      RiscvToolchainProbe(versionProbe: detectVersionOf, platform: _platform);

  /// Returns a one-line summary of the RISC-V toolchain for the
  /// diagnostics panel, or null when nothing was found.
  ///
  /// The interface gives one `String?` for what is really four independent
  /// dependencies, so the structured answer lives on
  /// [RiscvToolchainProbe.probe] and this is its summary line.
  /// Probed against `$PATH` defaults — there is no project config at
  /// diagnostics time. Non-throwing, per the interface contract.
  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) async {
    try {
      final report = await probeFor().probe(const RiscvConfig());
      return report.summaryLine;
    } on Object {
      return null;
    }
  }

  // ── compile stage ──────────────────────────────────────────────────

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    final cfg = request.test.riscv ?? const RiscvConfig();
    final stdoutCapture = request.stdoutCapture ?? BoundedLogCapture();
    final stderrCapture = request.stderrCapture ?? BoundedLogCapture();
    switch (cfg.effectiveMode) {
      case RiscvRunMode.demo:
        return await _demoCompile(request, cfg, stdoutCapture, stderrCapture);
      case RiscvRunMode.riscofPassthrough:
        stdoutCapture.addLine(
          'riscv_arch: mode=riscof_passthrough — no compile stage; the '
          'configured RISCOF command owns build and run.',
        );
        return CompileResult(
          success: true,
          artifactPath: null,
          stdout: stdoutCapture.text,
          stderr: stderrCapture.text,
        );
      case RiscvRunMode.normal:
        return await _normalCompile(request, cfg, stdoutCapture, stderrCapture);
    }
  }

  /// Demo compile: stage the committed **reference** signature. No spawn.
  ///
  /// A missing case directory or a missing golden is deliberately *not* a
  /// compile failure — it flows into the same comparison tail as every
  /// other mode, where "reference signature not written" is reported with
  /// the same wording a real toolchain run would produce. Failing here
  /// instead would give demo mode a failure path production never takes.
  Future<CompileResult> _demoCompile(
    CompileRequest request,
    RiscvConfig cfg,
    BoundedLogCapture stdoutCapture,
    BoundedLogCapture stderrCapture,
  ) async {
    final caseDir = _demoCaseDir(cfg, request.test.name);
    stdoutCapture.addLine(
      'riscv_arch: mode=demo — replaying committed signatures from '
      '${caseDir ?? '(unset)'} (no toolchain, no subprocess).',
    );
    if (caseDir == null) {
      stderrCapture.addLine(
        'riscv_arch: `riscv.demo_signatures` is not set, so there is no '
        'corpus to replay.',
      );
      return CompileResult(
        success: true,
        artifactPath: null,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    }
    final names = await _demoCaseFilenames(caseDir);
    await _stageDemoFile(
      from: p.join(caseDir, names.reference),
      to: GoldenCompareDetector.resolvePath(
        cfg.effectiveSignature.effectiveReference,
        request.workingDirectory,
      ),
      label: 'reference',
      stderrCapture: stderrCapture,
    );
    return CompileResult(
      success: true,
      artifactPath: null,
      stdout: stdoutCapture.text,
      stderr: stderrCapture.text,
    );
  }

  /// Normal compile: cross-compile the test, then run the reference model.
  ///
  /// The reference run belongs here rather than in `execute` for two
  /// reasons: it produces a prerequisite *artifact* (the golden), and
  /// `runProcessStreaming` owns the whole execute stream — it drains and
  /// closes the controller — so it can be called exactly once per execute.
  /// Putting the reference run in compile keeps that contract intact and
  /// still gets tree reaping and the compile timeout, because the scheduler
  /// registers the live test before `driver.compile`.
  Future<CompileResult> _normalCompile(
    CompileRequest request,
    RiscvConfig cfg,
    BoundedLogCapture stdoutCapture,
    BoundedLogCapture stderrCapture,
  ) async {
    final wd = request.workingDirectory;
    final elf = p.join(wd, kElfName);
    final probe = probeFor();

    // 1. Cross-compile.
    final compiler = RiscvToolchainProbe.crossCompilerBinary(cfg);
    final compileArgs = _compileArgs(cfg: cfg, request: request, elf: elf);
    final compileOk = await _runStage(
      request: request,
      executable: compiler,
      args: compileArgs,
      stdoutCapture: stdoutCapture,
      stderrCapture: stderrCapture,
      component: RiscvToolchainComponent.crossCompiler,
      probe: probe,
      cfg: cfg,
    );
    if (!compileOk || !File(elf).existsSync()) {
      if (compileOk) {
        stderrCapture.addLine(
          'riscv_arch: the cross-compiler exited 0 but produced no '
          '$kElfName. Check `riscv.compile.link_script` and '
          '`riscv.compile.include_dirs`.',
        );
      }
      return CompileResult(
        success: false,
        artifactPath: null,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    }

    // 2. Reference model → the golden signature.
    final model = RiscvToolchainProbe.referenceModelBinary(cfg);
    final refSig = GoldenCompareDetector.resolvePath(
      cfg.effectiveSignature.effectiveReference,
      wd,
    );
    final referenceOk = await _runStage(
      request: request,
      executable: model,
      args: _referenceArgs(cfg: cfg, elf: elf, signaturePath: refSig),
      stdoutCapture: stdoutCapture,
      stderrCapture: stderrCapture,
      component: RiscvToolchainComponent.referenceModel,
      probe: probe,
      cfg: cfg,
    );
    return CompileResult(
      success: referenceOk,
      artifactPath: referenceOk ? elf : null,
      stdout: stdoutCapture.text,
      stderr: stderrCapture.text,
    );
  }

  /// Spawns one compile-stage subprocess through the reaper, streaming both
  /// pipes into the attempt's bounded captures. Returns true on exit 0.
  ///
  /// On `ProcessException` it writes the component's **actionable**
  /// remediation into the stderr capture — so the user reads "install the
  /// cross-compiler, here is how, on your platform" rather than an OS
  /// errno — and then throws [SimulatorNotAvailableException], which the
  /// scheduler already renders as inspector-visible log lines.
  Future<bool> _runStage({
    required CompileRequest request,
    required String executable,
    required List<String> args,
    required BoundedLogCapture stdoutCapture,
    required BoundedLogCapture stderrCapture,
    required RiscvToolchainComponent component,
    required RiscvToolchainProbe probe,
    required RiscvConfig cfg,
  }) async {
    stdoutCapture.addLine('+ $executable ${args.join(' ')}');
    final reducer = PythonTracebackReducer();
    try {
      final process = await reaper.spawnGrouped(
        executable,
        args,
        environment: augmentEnvironment(request.binaryConfig.extraEnv),
        workingDirectory: request.workingDirectory,
      );
      trackProcess(request.test.id, process);
      final stdoutSub = process.stdout.listen(stdoutCapture.addLine);
      final stderrSub = process.stderr.listen((line) {
        reducer.addLine(line);
        stderrCapture.addLine(line);
      });
      final exit = await process.exitCode;
      await stdoutSub.cancel();
      await stderrSub.cancel();
      untrackProcess(request.test.id);
      if (exit != 0) {
        final summary = reducer.summary;
        stderrCapture.addLine(
          summary != null
              ? 'riscv_arch: ${p.basename(executable)} failed — $summary'
              : 'riscv_arch: ${p.basename(executable)} exited $exit.',
        );
      }
      return exit == 0;
    } on ProcessException catch (e) {
      untrackProcess(request.test.id);
      stderrCapture.addLine(probe.remediationFor(component, cfg));
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

  // ── execute stage ──────────────────────────────────────────────────

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final cfg = request.test.riscv ?? const RiscvConfig();
    final startedAt = DateTime.now().toUtc();

    if (cfg.effectiveMode == RiscvRunMode.demo) {
      // The only branch that skips a spawn. Everything after it —
      // signature reading, comparison, metric emission, event
      // construction — is the identical tail the other two modes take.
      await _stageDemoDut(request, cfg, controller);
      final finished = await buildTerminalEvent(
        workingDirectory: request.workingDirectory,
        cfg: cfg,
        exitCode: 0,
        startedAt: startedAt,
        killSignal: null,
        tracebackSummary: null,
      );
      controller.add(finished);
      await controller.close();
      return;
    }

    final argv = cfg.effectiveMode == RiscvRunMode.riscofPassthrough
        ? _riscofArgv(request, cfg)
        : _targetArgv(request, cfg);
    if (argv.isEmpty) {
      // The loader refuses this configuration, so reaching here means a
      // programmatically-built spec. Fail loudly rather than passing.
      controller.add(
        TestExecutionFinished(
          status: TestStatus.fail,
          exitCode: null,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          failureMessage: cfg.validateForRun().join(' '),
        ),
      );
      await controller.close();
      return;
    }

    final reducer = PythonTracebackReducer();
    await runProcessStreaming(
      request: request,
      executable: argv.first,
      args: argv.skip(1).toList(growable: false),
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: argv.first,
      unavailableMessage:
          '${argv.first} not available (${request.binaryConfig.source.name})',
      // Every line still reaches the stream as a TestLogLine and lands in
      // the retained stderr log; the reducer only decides what the single
      // dashboard-row line says.
      onLine: (line, {required fromStderr}) => reducer.addLine(line),
      buildFinished: (exitCode, process) => buildTerminalEvent(
        workingDirectory: request.workingDirectory,
        cfg: cfg,
        exitCode: exitCode,
        startedAt: startedAt,
        killSignal: process.killSignal,
        tracebackSummary: reducer.summary,
      ),
    );
  }

  /// Demo execute: stage the committed **DUT** signature. No spawn.
  ///
  /// The `missing_dut` fixture case has no DUT dump at all, so nothing is
  /// written — which is exactly the shape of a real run whose core exited 0
  /// without emitting a signature, and the exit-0-means-pass trap this
  /// driver exists to catch.
  Future<void> _stageDemoDut(
    ExecuteRequest request,
    RiscvConfig cfg,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final caseDir = _demoCaseDir(cfg, request.test.name);
    if (caseDir == null) return;
    final names = await _demoCaseFilenames(caseDir);
    final from = p.join(caseDir, names.dut);
    final to = GoldenCompareDetector.resolvePath(
      cfg.effectiveSignature.effectiveDut,
      request.workingDirectory,
    );
    final staged = await _stageDemoFile(
      from: from,
      to: to,
      label: 'DUT',
      controller: controller,
    );
    if (staged) {
      controller.add(
        TestLogLine(
          line: 'riscv_arch: staged DUT signature from $from',
          fromStderr: false,
          timestamp: DateTime.now().toUtc(),
        ),
      );
    }
  }

  // ── the shared tail: read, compare, emit ───────────────────────────

  /// Reads both signatures out of the working directory, compares them
  /// through the shared pure [GoldenComparator], and builds the terminal
  /// event with the `golden.*` + `riscv.*` metrics attached.
  ///
  /// **This is the whole point of the driver and every mode reaches it
  /// unchanged.** Exposed (rather than private) so the demo-mode and
  /// normal-mode tests can assert they produce identical events from
  /// identical signature files.
  ///
  /// The status is **always** `pass` or `fail` — never `unknown` (which
  /// hands the verdict back to the driver's own exit code, so an exit-0 run
  /// that wrote nothing would report pass) and never `vacuous` (which the
  /// scheduler treats as success-equivalent: no retry, and the work
  /// directory holding the evidence is deleted).
  Future<TestExecutionFinished> buildTerminalEvent({
    required String workingDirectory,
    required RiscvConfig cfg,
    required int? exitCode,
    required DateTime startedAt,
    required KillSignal? killSignal,
    required String? tracebackSummary,
  }) async {
    final sig = cfg.effectiveSignature;
    final dutPath = GoldenCompareDetector.resolvePath(
      sig.effectiveDut,
      workingDirectory,
    );
    final refPath = GoldenCompareDetector.resolvePath(
      sig.effectiveReference,
      workingDirectory,
    );

    final metrics = <String, String>{
      kMetricMode: cfg.effectiveMode.wireName,
      kMetricSignatureWordSize: '${sig.effectiveWordSize}',
      kMetricExtension: ?cfg.extension,
      kMetricIsa: ?cfg.isa,
      kMetricTest: ?cfg.testPath,
      kMetricArchTestRevision: ?cfg.archTest?.revision,
    };
    if (cfg.effectiveMode != RiscvRunMode.demo) {
      // Omitted in demo mode on purpose: no reference model ran, and an
      // exported compatibility report must never attribute a replayed
      // signature to a model that was never invoked.
      metrics[kMetricReferenceModel] =
          (cfg.reference?.effectiveModel ?? RiscvReferenceModel.spike).wireName;
    }

    final refText = await _readOrNull(refPath);
    final dutText = await _readOrNull(dutPath);

    TestStatus status;
    String? failureMessage;
    if (refText == null) {
      status = TestStatus.fail;
      failureMessage =
          'reference signature not written (${sig.effectiveReference})';
    } else if (dutText == null) {
      // The exit-0 trap in its purest form: the run exited 0 and produced
      // nothing. Anything but `fail` here reports a broken core as green.
      status = TestStatus.fail;
      failureMessage = 'DUT signature not written (${sig.effectiveDut})';
    } else {
      final comparison = GoldenComparator.compare(
        dut: dutText,
        reference: refText,
        profile: GoldenCompareProfile.riscvSignature,
      );
      metrics.addAll(comparison.toMetrics());
      final offset = comparison.mismatchOffset;
      if (offset != null) {
        metrics[kMetricSignatureByteOffset] =
            '${offset * sig.effectiveWordSize}';
      }
      status = comparison.matched ? TestStatus.pass : TestStatus.fail;
      if (!comparison.matched) {
        failureMessage = _describeDivergence(comparison, sig.effectiveWordSize);
      }
    }

    // A non-zero exit is a failure even when the signatures happen to
    // agree — a core that crashed after writing a correct prefix is not
    // compatible.
    if (exitCode != null && exitCode != 0) {
      status = TestStatus.fail;
      failureMessage ??= 'DUT exited $exitCode';
    }
    // A reduced Python traceback is the most informative single line we
    // have, so it wins over the generic exit-code phrasing.
    if (tracebackSummary != null && status != TestStatus.pass) {
      failureMessage = tracebackSummary;
    }

    return TestExecutionFinished(
      status: status,
      exitCode: exitCode,
      startedAt: startedAt,
      finishedAt: DateTime.now().toUtc(),
      failureMessage: failureMessage,
      killSignal: killSignal,
      metrics: metrics,
    );
  }

  String _describeDivergence(GoldenComparison c, int wordSize) {
    final offset = c.mismatchOffset;
    if (c.dutEmpty && c.refEmpty) {
      return 'both signatures are empty — the run produced no architectural '
          'state to check';
    }
    if (c.dutEmpty) return 'DUT signature is empty';
    if (c.refEmpty) return 'reference signature is empty';
    if (offset == null) return 'signature mismatch';
    final byte = offset * wordSize;
    if (c.dutWord == null || c.refWord == null) {
      return 'signature length mismatch at word $offset (byte $byte): '
          'DUT ${c.dutWords} words, reference ${c.refWords}';
    }
    return 'signature mismatch at word $offset (byte $byte): '
        'DUT ${c.dutWord}, reference ${c.refWord}';
  }

  // ── argv construction ──────────────────────────────────────────────

  Map<String, String> _placeholders({
    required String workingDirectory,
    required String testName,
    required RiscvConfig cfg,
  }) {
    final sig = cfg.effectiveSignature;
    return <String, String>{
      'elf': p.join(workingDirectory, kElfName),
      'signature': GoldenCompareDetector.resolvePath(
        sig.effectiveDut,
        workingDirectory,
      ),
      'ref_signature': GoldenCompareDetector.resolvePath(
        sig.effectiveReference,
        workingDirectory,
      ),
      'test': _resolvedTestPath(cfg) ?? '',
      'isa': cfg.isa ?? '',
      'name': testName,
      'work_dir': workingDirectory,
      'plugin_path': cfg.target?.pluginPath ?? '',
    };
  }

  /// The architectural test source, resolved against
  /// `riscv.arch_test.suite_path` when relative.
  String? _resolvedTestPath(RiscvConfig cfg) {
    final rel = cfg.testPath;
    if (rel == null || rel.isEmpty) return null;
    if (p.isAbsolute(rel)) return rel;
    final root = cfg.archTest?.suitePath;
    if (root == null || root.isEmpty) return rel;
    return p.normalize(p.join(root, rel));
  }

  List<String> _compileArgs({
    required RiscvConfig cfg,
    required CompileRequest request,
    required String elf,
  }) {
    final values = _placeholders(
      workingDirectory: request.workingDirectory,
      testName: request.test.name,
      cfg: cfg,
    );
    final override = cfg.compile?.command;
    if (override != null && override.isNotEmpty) {
      return override
          .map((a) => expandRiscvPlaceholders(a, values))
          .toList(growable: false);
    }
    final source = _resolvedTestPath(cfg);
    return <String>[
      '-march=${cfg.isa ?? 'rv${cfg.xlen}i'}',
      '-mabi=${cfg.abi}',
      '-static',
      '-nostdlib',
      '-nostartfiles',
      '-o',
      elf,
      if (cfg.compile?.linkScript != null) ...<String>[
        '-T',
        expandRiscvPlaceholders(cfg.compile!.linkScript!, values),
      ],
      for (final dir in cfg.compile?.includeDirs ?? const <String>[])
        '-I${expandRiscvPlaceholders(dir, values)}',
      // `riscv.test` first, then any ordinary `sources:` the user added
      // (an env stub, a custom macro header). A set literal dedupes the
      // case where the same file appears in both.
      ...<String>{?source, ...request.test.sources},
      for (final extra in cfg.compile?.extraArgs ?? const <String>[])
        expandRiscvPlaceholders(extra, values),
    ];
  }

  List<String> _referenceArgs({
    required RiscvConfig cfg,
    required String elf,
    required String signaturePath,
  }) {
    final model = cfg.reference?.effectiveModel ?? RiscvReferenceModel.spike;
    final conventional = model.signatureArgs(
      isa: cfg.isa ?? 'rv${cfg.xlen}i',
      elf: elf,
      signaturePath: signaturePath,
      wordSize: cfg.effectiveSignature.effectiveWordSize,
    );
    final extra = cfg.reference?.args ?? const <String>[];
    if (extra.isEmpty) return conventional;
    // Extra args are spliced in before the ELF path (always last).
    return <String>[
      ...conventional.take(conventional.length - 1),
      ...extra,
      conventional.last,
    ];
  }

  List<String> _targetArgv(ExecuteRequest request, RiscvConfig cfg) {
    final command = cfg.target?.command ?? const <String>[];
    if (command.isEmpty) return const <String>[];
    final values = _placeholders(
      workingDirectory: request.workingDirectory,
      testName: request.test.name,
      cfg: cfg,
    );
    return command
        .map((a) => expandRiscvPlaceholders(a, values))
        .toList(growable: false);
  }

  List<String> _riscofArgv(ExecuteRequest request, RiscvConfig cfg) {
    final command = cfg.riscof?.command ?? const <String>[];
    if (command.isEmpty) return const <String>[];
    final values = _placeholders(
      workingDirectory: request.workingDirectory,
      testName: request.test.name,
      cfg: cfg,
    );
    return command
        .map((a) => expandRiscvPlaceholders(a, values))
        .toList(growable: false);
  }

  // ── demo-corpus helpers ────────────────────────────────────────────

  String? _demoCaseDir(RiscvConfig cfg, String testName) {
    final root = cfg.demoSignatures;
    if (root == null || root.isEmpty) return null;
    return p.join(root, cfg.demoCase ?? testName);
  }

  /// Reads the case's `case.json` for the two dump filenames.
  ///
  /// The `golden_compare` corpus (`verification/fixtures/golden_compare/`)
  /// declares them there, so demo mode consumes that corpus as-is rather
  /// than authoring a second fixture set. Falls back to the corpus's conventional
  /// names when the manifest is absent or unreadable.
  Future<_DemoCaseFilenames> _demoCaseFilenames(String caseDir) async {
    const fallback = _DemoCaseFilenames(
      dut: 'dut.sig',
      reference: 'golden.sig',
    );
    try {
      final file = File(p.join(caseDir, 'case.json'));
      if (!file.existsSync()) return fallback;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return fallback;
      final dut = decoded['dut'];
      final reference = decoded['reference'];
      return _DemoCaseFilenames(
        dut: dut is String && dut.isNotEmpty ? dut : fallback.dut,
        reference: reference is String && reference.isNotEmpty
            ? reference
            : fallback.reference,
      );
    } on Object {
      return fallback;
    }
  }

  Future<bool> _stageDemoFile({
    required String from,
    required String to,
    required String label,
    BoundedLogCapture? stderrCapture,
    StreamController<TestExecutionEvent>? controller,
  }) async {
    final source = File(from);
    if (!source.existsSync()) {
      final message =
          'riscv_arch: demo corpus has no $label dump at $from — the run '
          'proceeds and the comparison reports it, exactly as a real run '
          'that produced nothing would.';
      stderrCapture?.addLine(message);
      controller?.add(
        TestLogLine(
          line: message,
          fromStderr: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      return false;
    }
    try {
      final target = File(to);
      await target.parent.create(recursive: true);
      await target.writeAsString(await source.readAsString());
      return true;
    } on FileSystemException catch (e) {
      stderrCapture?.addLine('riscv_arch: could not stage $label dump: $e');
      controller?.add(
        TestLogLine(
          line: 'riscv_arch: could not stage $label dump: $e',
          fromStderr: true,
          timestamp: DateTime.now().toUtc(),
        ),
      );
      return false;
    }
  }

  Future<String?> _readOrNull(String path) async {
    try {
      final file = File(path);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }
}

class _DemoCaseFilenames {
  const _DemoCaseFilenames({required this.dut, required this.reference});

  final String dut;
  final String reference;
}
