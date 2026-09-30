// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/bounded_log_capture.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/domain/services/hdl_language_detector.dart';
import 'package:simcrux/services/simulator/cocotb_junit.dart';
import 'package:simcrux/services/simulator/execution_seed.dart';
import 'package:simcrux/services/simulator/process_backed_simulator_driver.dart';

/// [SimulatorDriver] for [Cocotb](https://www.cocotb.org).
///
/// Cocotb is a Python coroutine framework that drives an underlying
/// HDL simulator (Icarus / Verilator / GHDL / vendor) through a VPI /
/// VHPI / FLI interface. Tests are Python coroutines (`@cocotb.test()`)
/// living next to a tiny `Makefile` that the user authors per
/// testbench. The Makefile sets `SIM`, `TOPLEVEL_LANG`, `TOPLEVEL`,
/// `VERILOG_SOURCES` / `VHDL_SOURCES`, and `MODULE`, then includes
/// `cocotb-config --makefiles/Makefile.sim` which contains the
/// canonical compile-and-run rules. This is the strategy A pattern
/// (Makefile wrap); see `docs/cocotb-strategy.md`.
///
/// **Strategy A vs B.** Strategy B is to skip `make` entirely and
/// drive Cocotb's Python runner (`cocotb_test`) by constructing the
/// command line directly. Strategy A is preferred because it matches
/// the *exact* command users run by hand outside of SimCrux, which
/// keeps reproduction cases trivial. If the per-test `make` startup
/// cost becomes a measurable problem at scale we'll revisit and
/// ship a `CocotbRunnerDriver` alongside this one — see
/// `docs/cocotb-strategy.md` for the decision log.
///
/// **Per-test working dir.** Cocotb's Makefile expects the user to
/// run `make` in the directory that contains the testbench source.
/// SimCrux's [JobScheduler] allocates a per-test working directory
/// under `{runRoot}/runs/{runId}/{testIdSafe}/`. The driver copies
/// the user's testbench tree into that working directory before
/// invoking `make`, so Cocotb's `SIM_BUILD/` and `results.xml`
/// artifacts land inside the scheduler-managed workdir and get
/// retained / cleaned alongside everything else. The "user's
/// testbench tree" is the directory containing the [TestSpec.top]
/// file if that file is a `Makefile`, otherwise the directory
/// containing the test's first source.
///
/// **Pass/fail.** Cocotb reports per-testcase status in its end-of-run
/// summary table:
///
///     ** TESTS=4 PASS=3 FAIL=1 SKIP=0 **
///
/// and per-test lines, whose names Cocotb qualifies with the test module —
/// `<module>.<qualname>`, in every version from 1.9 to 2.1:
///
///     ** test_mix.test_alpha_pass    PASS    10.00   0.00   116550.18 **
///     ** test_mix.test_bravo_fail    FAIL    20.00   0.00   196656.91 **
///
/// **Cocotb 2.1.** `@cocotb.xfail` adds an `XFAIL` row status and an
/// `XFAIL=n` counter appended after `SKIP=n`, both gated behind
/// `COCOTB_PREVIEW=xfail_in_results`; without that flag 2.1 reports an
/// xfailed test as `PASS` exactly as 2.0 did. Both forms are parsed, so one
/// build works against 1.9, 2.0 and 2.1 without detecting the version —
/// which matters because `cocotb-config` frequently lives in a virtualenv
/// SimCrux cannot see.
///
/// **`results.xml` is preferred over the table.** Cocotb writes an xUnit
/// report beside the run and has since 1.x. It names each case exactly,
/// records the failure message and exception type, and does not move when the
/// terminal table is restyled — which the table demonstrably does between
/// releases, and every such drift silently emptied the scrape rather than
/// failing loudly. [_readJunitReport] takes it when present; the table below
/// remains the fallback for a run that produced none.
///
/// Verdict, in order:
///
/// 1. `results.xml` — clean when it declares no failures and no errors. An
///    xfailed case carries no `<failure>` child, so this is right whether or
///    not `COCOTB_PREVIEW` is set, with no residual arithmetic.
/// 2. The summary table — `FAIL=N` (N > 0 ⇒ fail), or a residual once
///    `PASS + SKIP + XFAIL` fails to account for `TESTS`.
/// 3. `make`'s exit code, when neither is parseable.
///
/// The scheduler re-classifies through the configured `PassFailDetector`
/// afterwards. So that the default `exit_code` detector cannot overrule a
/// failing report with Cocotb 1.9's exit status of 0, a failing verdict is
/// reported with a null exit code (see [kMetricProcessExitCode]).
///
/// Metrics on [TestExecutionFinished.metrics]: `cocotb.tests`, `cocotb.pass`,
/// `cocotb.fail`, `cocotb.skip`, `cocotb.xfail` (only when reported), plus
/// `cocotb.test.<module>.<name>.status` / `.sim_time_ns`, and — from the
/// report only — `.message` and `.type` for a failure. The inspector pane
/// reads these to display the Cocotb subtable inside one SimCrux `TestResult`.
///
/// **Cocotb 2.1 regression controls** ride the existing options surface;
/// nothing is emitted unless asked for, so older Cocotb is unaffected:
/// `max_failures` → `COCOTB_MAX_FAILURES`, `random_order` →
/// `COCOTB_RANDOM_TEST_ORDER`, `preview` → `COCOTB_PREVIEW`.
///
/// **Underlying simulator override.** Cocotb's Makefile reads `SIM=…`
/// from the environment or from the Makefile body. SimCrux exposes
/// this via the project's `simulators.cocotb.options.sim` config
/// field, falling back to `icarus`. The user can also override per
/// test via `parameters: { sim: verilator }`.
///
/// **Cancellation.** [cancel] kills the live `make` subprocess
/// (which propagates to Cocotb's child `iverilog` / `verilator` via
/// SIGTERM through the process group), waits `killGrace`, then sends
/// SIGKILL — the shared [ProcessBackedSimulatorDriver] behaviour.
class CocotbDriver extends ProcessBackedSimulatorDriver {
  /// Creates a [CocotbDriver].
  ///
  /// [launcher] is injected so tests can drive the driver against a
  /// scripted `TestProcess`. [makeBinary] is the `make` executable
  /// name resolved via the project's [SimulatorBinaryConfig].
  /// [cocotbConfigBinary] is used for [detectVersion] only.
  CocotbDriver({
    super.launcher,
    super.reaper,
    this.makeBinary = 'make',
    this.cocotbConfigBinary = 'cocotb-config',
    this.defaultSim = 'icarus',
    super.killGrace,
  });

  /// `make` executable name; resolved via [SimulatorBinaryConfig].
  final String makeBinary;

  /// `cocotb-config` executable used for [detectVersion].
  final String cocotbConfigBinary;

  /// Underlying simulator id passed to Cocotb's Makefile via `SIM=…`
  /// when the project doesn't specify one. Defaults to `icarus` —
  /// always-installable, no extra C++ toolchain.
  final String defaultSim;

  /// Metric key: a `make` exit code of **0** that was withheld from
  /// [TestExecutionFinished.exitCode] because the structured verdict was a
  /// failure. The value is preserved here rather than discarded.
  static const String kMetricProcessExitCode = 'cocotb.process_exit_code';

  @override
  String get id => 'cocotb';

  @override
  String get displayName => 'Cocotb';

  @override
  SimulatorCapabilities get capabilities => SimulatorCapabilities(
    supportedLanguages: const {HdlLanguage.python},
    supportsVcd: true,
    supportsFst: true,
    supportsCocotb: true,
    // make-and-run in one step — the Makefile handles compile.
    requiresSeparateCompileStep: false,
    // Cocotb emits a structured summary table the driver parses.
    emitsStructuredOutput: true,
  );

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) {
    // cocotb-config prints a bare version, e.g. "2.1.0". Nothing gates on
    // the value: the parsers accept every format 1.9 through 2.1 emit, which
    // matters because cocotb-config commonly lives in a virtualenv SimCrux
    // cannot see, so a version probe fails exactly where it would be needed.
    return detectVersionOf(resolveBinary(config, cocotbConfigBinary));
  }

  @override
  Future<CompileResult> compile(CompileRequest request) async {
    // Cocotb compiles inside the same `make` invocation as execute;
    // no separate step. Surface a vacuous success so the scheduler
    // proceeds to execute().
    return const CompileResult(
      success: true,
      artifactPath: null,
      stdout: '',
      stderr: '',
    );
  }

  @override
  Future<void> runExecute(
    ExecuteRequest request,
    StreamController<TestExecutionEvent> controller,
  ) async {
    final make = resolveBinary(request.binaryConfig, makeBinary);
    final wd = request.workingDirectory;
    final startedAt = DateTime.now().toUtc();

    final sim = _resolveSim(request);
    // Both spellings of the toplevel, deliberately. Cocotb 2.x renamed
    // TOPLEVEL to COCOTB_TOPLEVEL and its Makefile warns when only the old
    // one is set — but its `deprecate` helper is written as
    //
    //   $(if $(OLD),$(if $(filter $(NEW),$(OLD)),$(NEW),$(warning ...)...))
    //
    // so when BOTH are set to the same value it takes the new one and says
    // nothing. Cocotb 1.x ignores the name it does not know. One argument
    // list therefore runs warning-free on 1.9, 2.0 and 2.1 without asking
    // which is installed.
    final args = <String>[
      'SIM=$sim',
      'TOPLEVEL=${request.test.top}',
      'COCOTB_TOPLEVEL=${request.test.top}',
      ..._extraMakeArgs(request),
    ];

    // The full design copies the testbench source tree into the per-test
    // working directory so `make` finds the Makefile, the python
    // module, and the HDL sources. This driver keeps it simple:
    // the user's testbench directory is the parent of the first
    // source listed (or the directory of the Makefile when the
    // top-level is a Makefile path). Tests inject the source list
    // directly into a prepared workdir to bypass this.
    await _stageTestbenchSources(request, wd);

    // Resolve + pass the effective seed via Cocotb's standard
    // `RANDOM_SEED` env var so the run is reproducible; reported via
    // effectiveSeed.
    final effectiveSeed = resolveExecutionSeed(request.test.seed);
    final env = <String, String>{
      ...request.binaryConfig.extraEnv,
      // Cocotb's Makefile honors `SIM` from the env when the
      // commandline doesn't set it; we set it on the commandline AND
      // env so the user can override either way without surprise.
      'SIM': sim,
      // Both spellings again. Cocotb 2.x prefers COCOTB_RANDOM_SEED and only
      // falls back to RANDOM_SEED with a DeprecationWarning; 1.x knows only
      // the short name. Setting both keeps the reproducible seed working on
      // every version and keeps the warning out of the user's log.
      'RANDOM_SEED': '$effectiveSeed',
      'COCOTB_RANDOM_SEED': '$effectiveSeed',
      ..._cocotbRegressionEnv(request),
    };

    // `make` runs Cocotb's compile-and-run in one step, so these local
    // captures hold the whole run's output for summary parsing below.
    // Bounded — a chatty testbench cannot grow them without limit (the
    // Cocotb summary/per-test tables they feed sit at the end of the
    // log, which head-dropping retains).
    final stdoutCapture = BoundedLogCapture();
    final stderrCapture = BoundedLogCapture();

    await runProcessStreaming(
      request: request,
      executable: make,
      args: args,
      environment: env,
      startedAt: startedAt,
      controller: controller,
      unavailableBinaryLabel: make,
      unavailableMessage:
          '$make not available (${request.binaryConfig.source})',
      onLine: (line, {required fromStderr}) {
        (fromStderr ? stderrCapture : stdoutCapture).addLine(line);
      },
      buildFinished: (exitCode, process) async {
        final blob = '${stdoutCapture.text}\n${stderrCapture.text}';
        final summary = parseCocotbSummary(blob);
        final perTest = parseCocotbPerTestRows(blob);

        // Prefer the machine-readable report. `results.xml` is xUnit, has been
        // written since Cocotb 1.x, and does not move when the terminal table
        // is restyled — which the table demonstrably does: it renames rows and
        // gains status words between releases, and every such drift silently
        // emptied the scrape. When it is missing or unreadable (an aborted
        // run, a Makefile that redirects it) the stdout path below still
        // decides, so nothing regresses on a project that never produces one.
        final junit = await _readJunitReport(wd);
        final metrics = _buildMetrics(summary, perTest, junit);

        final TestStatus status;
        if (junit != null) {
          status = junit.isClean ? TestStatus.pass : TestStatus.fail;
        } else if (summary != null) {
          // Trust the structured summary over the exit code — Cocotb 1.9's
          // Makefile exits 0 with failing tests, and a user's Makefile or
          // wrapper can swallow the status on any version.
          status =
              (summary.fails == 0 &&
                  summary.expectedCompletions == summary.tests)
              ? TestStatus.pass
              : TestStatus.fail;
        } else {
          status = (exitCode == 0) ? TestStatus.pass : TestStatus.fail;
        }

        // **Never hand the scheduler an exit code that contradicts the
        // structured verdict.** The scheduler re-classifies every run through
        // the test's detector and adopts a decisive answer over this status;
        // a test with no `pass_fail:` block gets `exit_code`, which reads 0 as
        // a pass. Cocotb 1.9's `make` exits 0 when tests fail, so reporting
        // that 0 would turn every failing Cocotb 1.9 run green. Reporting
        // `null` makes the exit-code detector return `unknown`, and the
        // scheduler falls back to the status computed above. The raw value is
        // kept in [kMetricProcessExitCode]. A non-zero exit with a clean report
        // is left alone: a failing recipe still fails.
        var reportedExitCode = exitCode;
        if (status != TestStatus.pass && exitCode == 0) {
          metrics[kMetricProcessExitCode] = '0';
          reportedExitCode = null;
        }

        return TestExecutionFinished(
          status: status,
          exitCode: reportedExitCode,
          startedAt: startedAt,
          finishedAt: DateTime.now().toUtc(),
          killSignal: process.killSignal,
          effectiveSeed: effectiveSeed,
          metrics: metrics.isEmpty ? null : metrics,
        );
      },
    );
  }

  // ── helpers ────────────────────────────────────────────────────────

  /// Reads `results.xml` from the per-test working directory.
  ///
  /// Returns null when the file is absent or unparseable, which puts the run
  /// back on the stdout path rather than failing it. Cocotb writes this file
  /// itself; SimCrux never creates it, so its absence is normal for a project
  /// whose Makefile redirects `COCOTB_RESULTS_FILE` elsewhere.
  Future<CocotbJunitReport?> _readJunitReport(String workingDirectory) async {
    try {
      final file = File(p.join(workingDirectory, 'results.xml'));
      if (!file.existsSync()) return null;
      return parseCocotbJunit(await file.readAsString());
    } on Object {
      // An unreadable report is a reason to fall back, never a reason to fail
      // a run the simulator may have completed happily.
      return null;
    }
  }

  /// Returns the underlying-simulator id passed to Cocotb's Makefile
  /// as `SIM=…`. Resolution order:
  ///
  /// 1. `TestSpec.parameters['sim']` — per-test override.
  /// 2. `SimulatorBinaryConfig.options['sim']` — project-wide via
  ///    `simulators.cocotb.options.sim`.
  /// 3. [defaultSim] — driver default (`icarus`).
  String _resolveSim(ExecuteRequest request) {
    final perTest = request.test.parameters['sim'];
    if (perTest != null && perTest.isNotEmpty) return perTest;
    final projectWide = request.binaryConfig.options['sim'];
    if (projectWide != null && projectWide.isNotEmpty) return projectWide;
    return defaultSim;
  }

  /// Extra args appended to the `make` invocation. Cocotb's Makefile
  /// surface accepts `EXTRA_ARGS`, `TOPLEVEL_LANG`, etc. This driver
  /// surfaces only the most common knobs; project authors can
  /// inject anything else via `parameters:` (which become Makefile
  /// variable overrides on the command line).
  ///
  /// `TOPLEVEL_LANG` resolution order (mixed-language designs):
  ///
  /// 1. `parameters.TOPLEVEL_LANG` — explicit per-test override; always
  ///    wins.
  /// 2. Auto-derived from the dominant HDL language across the test's
  ///    `sources` list, using per-source language overrides where
  ///    declared and extension-driven detection otherwise. This is the
  ///    common case — the user does nothing, Cocotb picks the right
  ///    `TOPLEVEL_LANG` for the design.
  /// 3. No `TOPLEVEL_LANG` arg — Cocotb's Makefile applies its own
  ///    default (`verilog`).
  List<String> _extraMakeArgs(ExecuteRequest request) {
    final out = <String>[];
    final overrideLang = request.test.parameters['TOPLEVEL_LANG'];
    if (overrideLang != null && overrideLang.isNotEmpty) {
      out.add('TOPLEVEL_LANG=$overrideLang');
    } else {
      final autoLang = _resolveDominantLang(request);
      if (autoLang != null) {
        out.add('TOPLEVEL_LANG=$autoLang');
      }
    }
    final module = request.test.parameters['MODULE'];
    if (module != null && module.isNotEmpty) {
      // Same both-spellings rule as TOPLEVEL above: Cocotb 2.x renamed this
      // to COCOTB_TEST_MODULES and warns when only MODULE is set.
      out
        ..add('MODULE=$module')
        ..add('COCOTB_TEST_MODULES=$module');
    }
    return out;
  }

  /// Regression-control environment for Cocotb 2.1's opt-in features.
  ///
  /// Read from the test's `parameters` and the project's
  /// `simulators.cocotb.options`, so they ride the config surface that already
  /// exists rather than needing settings UI of their own:
  ///
  /// | Key            | Cocotb variable            | Effect                  |
  /// |----------------|----------------------------|-------------------------|
  /// | `max_failures` | `COCOTB_MAX_FAILURES`      | stop after N failures   |
  /// | `random_order` | `COCOTB_RANDOM_TEST_ORDER` | shuffle within a stage  |
  /// | `preview`      | `COCOTB_PREVIEW`           | opt into preview features |
  ///
  /// **Nothing is emitted unless the user asks for it.** An unset key produces
  /// no variable at all, so a project that says nothing behaves exactly as it
  /// did — and an older Cocotb that has never heard of these simply ignores
  /// the ones it does not know, which is why this needs no version check.
  ///
  /// `max_failures` is validated rather than passed through: a non-numeric
  /// value would be silently ignored by Cocotb, and a regression that quietly
  /// did not stop early is worse than one that refuses to start.
  Map<String, String> _cocotbRegressionEnv(ExecuteRequest request) {
    final out = <String, String>{};

    final maxFailures = _cocotbOption(request, 'max_failures');
    if (maxFailures != null && maxFailures.isNotEmpty) {
      final parsed = int.tryParse(maxFailures);
      if (parsed == null || parsed < 1) {
        throw ArgumentError.value(
          maxFailures,
          'simulators.cocotb.options.max_failures',
          'must be a positive integer',
        );
      }
      out['COCOTB_MAX_FAILURES'] = '$parsed';
    }

    final randomOrder = _cocotbOption(request, 'random_order');
    if (randomOrder != null && randomOrder.toLowerCase() == 'true') {
      out['COCOTB_RANDOM_TEST_ORDER'] = '1';
    }

    final preview = _cocotbOption(request, 'preview');
    if (preview != null && preview.isNotEmpty) {
      out['COCOTB_PREVIEW'] = preview;
    }

    return out;
  }

  /// A Cocotb option from the per-test `parameters` first, then the project's
  /// `simulators.cocotb.options` — the same precedence `SIM` already uses.
  String? _cocotbOption(ExecuteRequest request, String key) {
    final perTest = request.test.parameters[key];
    if (perTest != null && perTest.isNotEmpty) return perTest;
    final projectWide = request.binaryConfig.options[key];
    if (projectWide != null && projectWide.isNotEmpty) return projectWide;
    return null;
  }

  /// Computes the test's dominant HDL language and returns Cocotb's
  /// matching `TOPLEVEL_LANG` value (`verilog` for Verilog or
  /// SystemVerilog, `vhdl` for VHDL). Returns null when the test has
  /// no HDL sources (e.g. pure Python testbench wired through the
  /// Makefile in another way) so the driver omits the arg and lets
  /// Cocotb's own default apply.
  String? _resolveDominantLang(ExecuteRequest request) {
    final paths = request.test.sources;
    if (paths.isEmpty) return null;
    const detector = HdlLanguageDetector();
    final votes = <HdlLanguage, int>{};
    for (final source in paths) {
      final lang =
          request.test.sourceLanguages[source] ?? detector.detect(source);
      if (lang == null) continue;
      votes[lang] = (votes[lang] ?? 0) + 1;
    }
    if (votes.isEmpty) return null;
    HdlLanguage? best;
    var bestCount = 0;
    for (final order in const [
      HdlLanguage.verilog,
      HdlLanguage.systemVerilog,
      HdlLanguage.vhdl,
    ]) {
      final c = votes[order] ?? 0;
      if (c > bestCount) {
        bestCount = c;
        best = order;
      }
    }
    if (best == null) return null;
    switch (best) {
      case HdlLanguage.verilog:
      case HdlLanguage.systemVerilog:
        return 'verilog';
      case HdlLanguage.vhdl:
        return 'vhdl';
      case HdlLanguage.python:
      case HdlLanguage.mixed:
        return null;
    }
  }

  /// Copy the user's testbench source files into the per-test working
  /// directory so `make` finds the Makefile and the Python module.
  /// No-op when the source list is empty (tests prepare the workdir
  /// directly).
  Future<void> _stageTestbenchSources(
    ExecuteRequest request,
    String wd,
  ) async {
    final sources = request.test.sources;
    if (sources.isEmpty) return;
    for (final src in sources) {
      final srcFile = File(src);
      if (!srcFile.existsSync()) continue;
      final destPath = p.join(wd, p.basename(src));
      // Don't overwrite — tests that pre-stage files into the wd
      // should win.
      if (File(destPath).existsSync()) continue;
      await srcFile.copy(destPath);
    }
  }

  Map<String, String> _buildMetrics(
    CocotbSummary? summary,
    List<CocotbPerTestRow> perTest,
    CocotbJunitReport? junit,
  ) {
    final out = <String, String>{};
    if (summary != null) {
      out['cocotb.tests'] = summary.tests.toString();
      out['cocotb.pass'] = summary.passes.toString();
      out['cocotb.fail'] = summary.fails.toString();
      out['cocotb.skip'] = summary.skips.toString();
      // Emitted only when Cocotb actually reported the counter, so a run
      // against any version that does not know about XFAIL carries exactly
      // the metric set it always did.
      if (summary.xfails > 0) {
        out['cocotb.xfail'] = summary.xfails.toString();
      }
    }
    for (final row in perTest) {
      out['cocotb.test.${row.name}.status'] = row.status;
      if (row.simTimeNs != null) {
        out['cocotb.test.${row.name}.sim_time_ns'] = row.simTimeNs!.toString();
      }
    }

    // The report wins where the two overlap: it names each case exactly and
    // carries the failure message and type, none of which the terminal table
    // exposes. Written after the scrape so it overwrites rather than races it.
    if (junit != null) {
      out['cocotb.tests'] = junit.tests.toString();
      out['cocotb.fail'] = junit.failures.toString();
      out['cocotb.skip'] = junit.skipped.toString();
      if (junit.errors > 0) out['cocotb.error'] = junit.errors.toString();
      for (final c in junit.cases) {
        out['cocotb.test.${c.name}.status'] = c.status;
        if (c.simTimeNs != null) {
          out['cocotb.test.${c.name}.sim_time_ns'] = c.simTimeNs!.toString();
        }
        // Why a case failed is the first thing anyone opens the inspector to
        // find, and the table never had it.
        final message = c.message;
        if (message != null && message.isNotEmpty) {
          out['cocotb.test.${c.name}.message'] = message;
        }
        final type = c.type;
        if (type != null && type.isNotEmpty) {
          out['cocotb.test.${c.name}.type'] = type;
        }
      }
    }
    return out;
  }
}

/// One-line aggregate Cocotb reports at the bottom of every run.
class CocotbSummary {
  /// Creates a [CocotbSummary].
  const CocotbSummary({
    required this.tests,
    required this.passes,
    required this.fails,
    required this.skips,
    this.xfails = 0,
  });

  /// Total number of `@cocotb.test()` cases.
  final int tests;

  /// Cases that completed with PASS.
  final int passes;

  /// Cases that completed with FAIL.
  final int fails;

  /// Cases skipped.
  final int skips;

  /// Cases that failed as declared by `@cocotb.xfail` (Cocotb 2.1+).
  ///
  /// Zero on every Cocotb that does not report the counter, which is all of
  /// them unless the user sets `COCOTB_PREVIEW=xfail_in_results` — 2.1 gates
  /// both the counter and the `XFAIL` row status behind that flag, and reports
  /// an xfailed test as `PASS` without it. Defaulting to zero is what keeps
  /// [expectedCompletions] correct on older versions rather than needing to
  /// know which version produced the output.
  final int xfails;

  /// Cases that reached a declared, non-failing outcome.
  ///
  /// The run is healthy when this equals [tests] and [fails] is zero. XFAIL
  /// belongs here: a test that failed exactly as its author declared is a
  /// success, and counting it as a residual is what made an all-xfail run
  /// report as a SimCrux failure.
  int get expectedCompletions => passes + skips + xfails;
}

/// One row of Cocotb's per-test summary table.
class CocotbPerTestRow {
  /// Creates a [CocotbPerTestRow].
  const CocotbPerTestRow({
    required this.name,
    required this.status,
    this.simTimeNs,
  });

  /// Test name (matches `@cocotb.test()` function name).
  final String name;

  /// `PASS`, `FAIL`, `SKIP`, or `ERROR`.
  final String status;

  /// Simulated time at end-of-test in nanoseconds. Null when the
  /// row didn't carry a SIM TIME column (some Cocotb versions omit
  /// the column when no tests reported timing).
  final double? simTimeNs;
}

/// Parses Cocotb's end-of-run aggregate line:
///
///     ** TESTS=4 PASS=3 FAIL=1 SKIP=0 **
///
/// Returns null when the line is absent. The matcher is intentionally
/// generous about surrounding `**` decoration and whitespace.
CocotbSummary? parseCocotbSummary(String blob) {
  // `XFAIL=` is appended AFTER `SKIP=` by Cocotb 2.1 when
  // COCOTB_PREVIEW=xfail_in_results is set, and is absent otherwise and on
  // every earlier version — so it is an optional trailing group rather than a
  // second regex or a version check. Verified against real output from
  // cocotb 2.1.0 in both modes:
  //
  //   ** TESTS=4 PASS=2 FAIL=1 SKIP=1              60.00  0.03    1933.00 **
  //   ** TESTS=4 PASS=1 FAIL=1 SKIP=1 XFAIL=1      60.00  0.03    2172.23 **
  final regex = RegExp(
    r'TESTS\s*=\s*(\d+)\s+PASS\s*=\s*(\d+)\s+FAIL\s*=\s*(\d+)\s+SKIP\s*=\s*(\d+)'
    r'(?:\s+XFAIL\s*=\s*(\d+))?',
  );
  final match = regex.firstMatch(blob);
  if (match == null) return null;
  return CocotbSummary(
    tests: int.parse(match.group(1)!),
    passes: int.parse(match.group(2)!),
    fails: int.parse(match.group(3)!),
    skips: int.parse(match.group(4)!),
    xfails: int.tryParse(match.group(5) ?? '') ?? 0,
  );
}

/// Parses every row of Cocotb's per-test summary table.
///
/// Cocotb names each row `<module>.<qualname>` — it has done so since at least
/// 1.9 (`".".join([test.__module__, test.__qualname__])`) and still does in
/// 2.1 (`test_fullname`). Real output, captured from cocotb 2.1.0:
///
///     ** test_mix.test_alpha_pass    PASS    10.00   0.00   116550.18 **
///     ** test_mix.test_bravo_fail    FAIL    20.00   0.00   196656.91 **
///     ** test_mix.test_charlie_skip  SKIP     0.00   0.00       -.-- **
///     ** test_mix.test_delta_xfail  XFAIL    30.00   0.00   514578.92 **
///
/// The name character class must therefore admit `.`. While it did not, this
/// parser matched **nothing** against real output on any Cocotb version and
/// the per-test metrics below were always empty — the examples it was written
/// against, and the unit tests, both used bare names that Cocotb never emits.
///
/// `XFAIL` appears only under `COCOTB_PREVIEW=xfail_in_results` on 2.1+;
/// accepting it costs nothing on versions that never emit it. Bare names are
/// still accepted so a hand-written or older table keeps parsing.
///
/// Returns rows in the order they appear in the output.
List<CocotbPerTestRow> parseCocotbPerTestRows(String blob) {
  final out = <CocotbPerTestRow>[];
  // A per-test row starts with optional `**`, a dotted-identifier-shaped
  // test name, a status word, and optional numeric columns.
  final regex = RegExp(
    r'^\s*\*{0,2}\s*([A-Za-z_][A-Za-z0-9_.]*)\s+(PASS|FAIL|SKIP|ERROR|XFAIL)(?:\s+([0-9]+(?:\.[0-9]+)?))?',
    multiLine: true,
  );
  for (final match in regex.allMatches(blob)) {
    final name = match.group(1)!;
    final status = match.group(2)!;
    // Exclude the aggregate row, which would otherwise match
    // ("TESTS" / "PASS"-prefixed shape) — but our aggregate uses
    // `=` so the line never matches this regex. Defensive guard
    // anyway: skip names that are pure status words.
    if (name == 'TESTS' || name == 'PASS' || name == 'FAIL') continue;
    final timeStr = match.group(3);
    out.add(
      CocotbPerTestRow(
        name: name,
        status: status,
        simTimeNs: timeStr == null ? null : double.parse(timeStr),
      ),
    );
  }
  return out;
}
