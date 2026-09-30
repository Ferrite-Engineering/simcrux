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
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart'
    show splitCommandLine;
import 'package:simcrux/services/simulator/execution_seed.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';
import 'package:simcrux/services/simulator/simulator_not_available_exception.dart';

/// One captured Verilator lint diagnostic. Surfaced on the driver's
/// compile stdout / stderr scrape so the inspector pane (and the
/// LintCrux cross-probe) can render them inline.
///
/// Format derived from Verilator's stderr lines, e.g.
/// `%Warning-WIDTH: foo.v:42:7: Bit extraction of var[31:0] requires 32 bits, 33 bits given`
class VerilatorLintWarning {
  /// Creates a [VerilatorLintWarning].
  const VerilatorLintWarning({
    required this.severity,
    required this.code,
    required this.filePath,
    required this.line,
    required this.column,
    required this.message,
  });

  /// `Warning` / `Error` / `Info` (verilator distinguishes via prefix).
  final String severity;

  /// The Verilator lint code (`WIDTH`, `UNUSED`, `LATCH`, …). May be
  /// empty when Verilator emitted a non-tagged diagnostic.
  final String code;

  /// Source file the diagnostic points at.
  final String filePath;

  /// 1-based line number, or 0 when Verilator didn't provide one.
  final int line;

  /// 1-based column number, or 0 when Verilator didn't provide one.
  final int column;

  /// Human-readable message body.
  final String message;
}

/// [SimulatorDriver] for [Verilator](https://www.veripool.org/verilator/).
///
/// Verilator translates Verilog/SystemVerilog into C++ that is then
/// compiled into a native executable. The driver runs two processes per
/// test inside the per-test working directory the scheduler allocates:
///
/// 1. compile — one `verilator` invocation that also runs make:
///
///    ```text
///    verilator --cc [--trace-fst] --exe --build -j <j> --Mdir obj_dir
///      --top-module <top> [--timing] -Wall -Wno-fatal [options.args]
///      sim_main.cpp <sources>
///    ```
///
/// 2. run — `./obj_dir/V<top> +verilator+seed+<n>`.
///
/// **Warnings never fail the build.** Verilator treats every warning as
/// fatal unless told otherwise, and `-Wall` adds the style class
/// (`DECLFILENAME`, `UNUSEDSIGNAL`, …) most real RTL trips, so the driver
/// passes `-Wno-fatal`. The warnings are still printed and parsed.
///
/// **Timing.** Verilator 5 rejects a testbench with `#` delays unless it is
/// built with `--timing`, and a timing model has to be driven by an
/// event-driven main loop. The driver reads the major version once per
/// binary, passes `--timing` for 5 and newer, and writes a `sim_main.cpp`
/// that advances time to the model's next event (`eventsPending` /
/// `nextTimeSlot`) on Verilator 5 and by one step on 4.
///
/// **Extra flags.** `simulators.verilator.options.args` is split like a
/// shell command line and passed after the driver's own flags, so a project
/// can add `-Wno-WIDTH`, `-O3` or `--no-timing`.
///
/// stdout/stderr are streamed through to the driver's event stream so the
/// inspector pane shows compile output alongside simulation output.
///
/// Lint warnings (`%Warning-XYZ:`) emitted during compile are
/// parsed and stashed on [parsedLintWarnings] keyed by test id. The
/// data is captured but not surfaced beyond the log scrape.
///
/// Cancellation: `cancel(testId)` kills whichever stage's subprocess
/// is live, sending SIGTERM first; the scheduler escalates to SIGKILL
/// via the per-driver grace period (see
/// [ProcessBackedSimulatorDriver]).
///
/// Binary unavailability: any missing binary (`verilator`, `make`)
/// surfaces as [SimulatorNotAvailableException], converted by the
/// scheduler into a clear `unknown` status with a remediation hint.
class VerilatorDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [VerilatorDriver].
  ///
  /// [launcher] is injected for tests.
  VerilatorDriver({
    super.launcher,
    super.reaper,
    this.verilatorBinary = 'verilator',
    this.makeBinary = 'make',
    this.makeJobs = 1,
    super.killGrace,
  });

  /// The `verilator` executable name. Resolved via [SimulatorBinaryConfig].
  final String verilatorBinary;

  /// The `make` executable name. Verilator emits a Makefile we then
  /// build.
  final String makeBinary;

  /// `make -j` value. Default `1` to keep test-time IO predictable;
  /// callers can override via a per-project setting in a later phase.
  final int makeJobs;

  /// Lint warnings captured by the most recent compile, keyed by
  /// `TestSpec.id`. Exposed for tests and for the inspector pane.
  ///
  /// Cleared at the start of each `compile()` invocation for the
  /// matching test id.
  final Map<String, List<VerilatorLintWarning>> parsedLintWarnings =
      <String, List<VerilatorLintWarning>>{};

  /// Verilator's major version per resolved binary, probed once.
  final Map<String, Future<int?>> _majorVersionByBinary =
      <String, Future<int?>>{};

  @override
  String get id => 'verilator';

  @override
  String get displayName => 'Verilator';

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
    // Verilator prints e.g. "Verilator 5.022 YYYY-MM-DD rev v5.022".
    return detectVersionOf(resolveBinary(config, verilatorBinary));
  }

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    final verilator = resolveBinary(request.binaryConfig, verilatorBinary);
    final make = resolveBinary(request.binaryConfig, makeBinary);
    final wd = request.workingDirectory;
    parsedLintWarnings.remove(request.test.id);
    final lintBuf = <VerilatorLintWarning>[];

    final major = await _majorVersionByBinary.putIfAbsent(
      verilator,
      () => _probeMajorVersion(verilator),
    );
    final args = <String>[
      '--cc',
      ..._traceArgs(request.test),
      '--exe',
      '--build',
      '-j',
      makeJobs.toString(),
      '--Mdir',
      'obj_dir',
      '--top-module',
      request.test.top,
      // Verilator 5 rejects `#` delays without it (NEEDTIMINGOPT); 4 does
      // not know the flag.
      if (major != null && major >= 5) '--timing',
      '-Wall',
      // Every Verilator warning is fatal by default; a lint finding must not
      // fail a simulation build. Warnings are still printed and parsed.
      '-Wno-fatal',
      ...splitCommandLine(request.binaryConfig.options['args'] ?? ''),
      for (final inc in request.test.includeDirs) '+incdir+$inc',
      for (final entry in request.test.defines.entries)
        '+define+${entry.key}=${entry.value}',
      // Per-instance simulation main shim. Verilator's --exe mode needs
      // a C++ main; we ship the standard template alongside the
      // sources. The shim is auto-generated below in the wd before
      // launch.
      'sim_main.cpp',
      ...request.test.sources,
    ];

    await _writeSimMain(wd, request.test.top);

    // Bounded line-by-line capture (scheduler-supplied when running
    // inside a regression) — a chatty compile step cannot grow an
    // unbounded buffer before the result string is materialized.
    final stdoutCapture = request.stdoutCapture ?? BoundedLogCapture();
    final stderrCapture = request.stderrCapture ?? BoundedLogCapture();

    try {
      final process = await reaper.spawnGrouped(
        verilator,
        args,
        environment: augmentEnvironment(request.binaryConfig.extraEnv),
        workingDirectory: wd,
      );
      trackProcess(request.test.id, process);

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      final stdoutSub = process.stdout.listen(
        (line) {
          stdoutCapture.addLine(line);
          final warning = _parseLintLine(line);
          if (warning != null) lintBuf.add(warning);
        },
        onDone: stdoutDone.complete,
      );
      final stderrSub = process.stderr.listen(
        (line) {
          stderrCapture.addLine(line);
          final warning = _parseLintLine(line);
          if (warning != null) lintBuf.add(warning);
        },
        onDone: stderrDone.complete,
      );
      final exit = await process.exitCode;
      await Future.wait<void>([stdoutDone.future, stderrDone.future]);
      await stdoutSub.cancel();
      await stderrSub.cancel();
      untrackProcess(request.test.id);
      parsedLintWarnings[request.test.id] = List.unmodifiable(lintBuf);

      if (exit != 0) {
        return CompileResult(
          success: false,
          artifactPath: null,
          stdout: stdoutCapture.text,
          stderr: stderrCapture.text,
        );
      }

      // Verilator's `--build` runs make for us. The artifact path is
      // the V<top> executable inside obj_dir.
      final artifact = p.join(wd, 'obj_dir', 'V${request.test.top}');
      if (!File(artifact).existsSync()) {
        stderrCapture.addLine(
          'verilator: expected executable at $artifact missing',
        );
        return CompileResult(
          success: false,
          artifactPath: null,
          stdout: stdoutCapture.text,
          stderr: stderrCapture.text,
        );
      }
      return CompileResult(
        success: true,
        artifactPath: artifact,
        stdout: stdoutCapture.text,
        stderr: stderrCapture.text,
      );
    } on ProcessException catch (e) {
      untrackProcess(request.test.id);
      // Distinguish missing make vs missing verilator via the
      // underlying executable name.
      throw SimulatorNotAvailableException(
        simulatorId: id,
        binary: e.executable == make ? make : verilator,
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
    final artifact =
        request.compileResult?.artifactPath ??
        p.join(request.workingDirectory, 'obj_dir', 'V${request.test.top}');
    final startedAt = DateTime.now().toUtc();

    // Resolve + pass the effective seed via `+verilator+seed+` (Verilator's
    // `$random` seed plusarg); reported via effectiveSeed.
    final effectiveSeed = resolveExecutionSeed(request.test.seed);

    await runProcessStreaming(
      request: request,
      executable: artifact,
      args: <String>['+verilator+seed+$effectiveSeed'],
      environment: request.binaryConfig.extraEnv,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: artifact,
      unavailableMessage:
          'verilator artifact $artifact not available (${request.binaryConfig.source})',
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

  /// Reads `verilator --version` ("Verilator 5.050 …") and returns the
  /// major version, or null when the probe or the parse fails.
  Future<int?> _probeMajorVersion(String verilator) async {
    final banner = await detectVersionOf(verilator);
    if (banner == null) return null;
    final match = RegExp(r'Verilator\s+(\d+)\.').firstMatch(banner);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  List<String> _traceArgs(TestSpec spec) {
    final policy = spec.waveform;
    switch (policy.capture) {
      case WaveformCapturePolicy.onDemand:
      case WaveformCapturePolicy.never:
        return const <String>[];
      case WaveformCapturePolicy.always:
      case WaveformCapturePolicy.onFailure:
        return policy.format == WaveformFormat.fst
            ? const <String>['--trace-fst']
            : const <String>['--trace'];
    }
  }

  Future<void> _writeSimMain(String wd, String top) async {
    final path = p.join(wd, 'sim_main.cpp');
    final file = File(path);
    if (file.existsSync()) return;
    const tracePragma = '''
#if VM_TRACE
# include <verilated_fst_c.h>
# include <verilated_vcd_c.h>
#endif
''';
    final body =
        '''
// Auto-generated by simcrux VerilatorDriver. Mirrors Verilator's
// stock sim_main template — runs until the test signals \$finish.
#include <cstdio>
#include <memory>
#include <verilated.h>
#include "V$top.h"
$tracePragma

int main(int argc, char** argv) {
  const std::unique_ptr<VerilatedContext> ctx{new VerilatedContext};
  ctx->commandArgs(argc, argv);
  const std::unique_ptr<V$top> top{new V$top{ctx.get()}};
#if defined(VERILATOR_VERSION_INTEGER) && VERILATOR_VERSION_INTEGER >= 5000000
  // Verilator 5: advance straight to the next scheduled event, which is
  // what a --timing model needs.
  while (!ctx->gotFinish()) {
    top->eval();
    if (!top->eventsPending()) break;
    ctx->time(top->nextTimeSlot());
  }
  if (!ctx->gotFinish()) {
    // Nothing is left to happen and the testbench never called \$finish.
    // Report it rather than exit 0, which would read as a pass.
    top->final();
    fprintf(stderr, "%%Error: simcrux sim_main: simulation ran out of events "
                    "before \$finish\\n");
    return 1;
  }
#else
  while (!ctx->gotFinish()) {
    top->eval();
    ctx->timeInc(1);
  }
#endif
  top->final();
  return 0;
}
''';
    await file.writeAsString(body);
  }

  Future<String?> _locateWaveform(ExecuteRequest request) async {
    final policy = request.test.waveform;
    if (policy.capture == WaveformCapturePolicy.never) return null;
    final wd = Directory(request.workingDirectory);
    if (!wd.existsSync()) return null;
    final candidates = <FileSystemEntity>[];
    for (final entity in wd.listSync(recursive: true)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).toLowerCase();
      if (ext == '.fst' || ext == '.vcd') {
        candidates.add(entity);
      }
    }
    if (candidates.isEmpty) return null;
    candidates.sort(
      (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
    );
    return candidates.first.path;
  }

  static final RegExp _lintLine = RegExp(
    r'^%(Warning|Error|Info)(?:-([A-Z][A-Z0-9_]*))?:\s*(.+?):(\d+):(\d+):\s*(.*)$',
  );
  static final RegExp _lintLineNoLoc = RegExp(
    r'^%(Warning|Error|Info)(?:-([A-Z][A-Z0-9_]*))?:\s*(.+)$',
  );

  /// Parses one Verilator stderr / stdout line into a
  /// [VerilatorLintWarning], returning null when the line is not a
  /// lint diagnostic. Recognized formats (verilator >=4.0):
  ///
  /// - `%Warning-WIDTH: file.v:42:7: Bit extraction…`
  /// - `%Error: file.v:42:7: Syntax error…`
  /// - `%Warning-UNUSED: Signal foo unused`  (no location)
  VerilatorLintWarning? _parseLintLine(String line) {
    final match = _lintLine.firstMatch(line);
    if (match != null) {
      return VerilatorLintWarning(
        severity: match.group(1)!,
        code: match.group(2) ?? '',
        filePath: match.group(3)!,
        line: int.tryParse(match.group(4)!) ?? 0,
        column: int.tryParse(match.group(5)!) ?? 0,
        message: match.group(6)!.trim(),
      );
    }
    final fallback = _lintLineNoLoc.firstMatch(line);
    if (fallback != null) {
      return VerilatorLintWarning(
        severity: fallback.group(1)!,
        code: fallback.group(2) ?? '',
        filePath: '',
        line: 0,
        column: 0,
        message: fallback.group(3)!.trim(),
      );
    }
    return null;
  }
}
