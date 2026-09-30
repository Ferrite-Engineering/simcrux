// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/cocotb_detector.dart';
import 'package:simcrux/services/pass_fail_detector/exit_code_detector.dart';
import 'package:simcrux/services/pass_fail_detector/golden_compare_detector.dart';
import 'package:simcrux/services/pass_fail_detector/regex_detector.dart';
import 'package:simcrux/services/pass_fail_detector/string_match_detector.dart';
import 'package:simcrux/services/pass_fail_detector/uvm_report_detector.dart';

/// Maps a [PassFailConfig] variant to its [PassFailDetector] and runs
/// it.
///
/// Detector variants: [ExitCodePassFailConfig],
/// [StringMatchPassFailConfig], [RegexPassFailConfig],
/// [CompositePassFailConfig], [UvmReportPassFailConfig] for UVM
/// testbenches, and [GoldenComparePassFailConfig] for golden-file
/// comparison. The composite case is handled in-line here
/// so the registry stays the single dispatch entry point for
/// recursive nesting.
///
/// **Two classification paths, and they are not interchangeable.**
/// [classify] is synchronous and sees only the captured log;
/// [classifyAsync] additionally takes the test's `workingDirectory` and
/// is the only path that can reach a filesystem-backed detector.
/// [GoldenComparePassFailConfig] is filesystem-backed, so [classify]
/// **throws** for it rather than degrading to [TestStatus.unknown] —
/// see the case in [classify] for why silence there would be a silent
/// pass. Production always takes the async path
/// (`LocalJobScheduler._runExecute`).
class PassFailDetectorRegistry {
  /// Creates a registry with the default detector set. Tests may
  /// inject custom detectors to observe call patterns.
  const PassFailDetectorRegistry({
    this.exitCodeDetector = const ExitCodeDetector(),
    this.stringMatchDetector = const StringMatchDetector(),
    this.regexDetector = const RegexDetector(),
    this.cocotbDetector = const CocotbDetector(),
    this.uvmReportDetector = const UvmReportDetector(),
    this.goldenCompareDetector = const GoldenCompareDetector(),
  });

  /// Detector used for [ExitCodePassFailConfig].
  final PassFailDetector exitCodeDetector;

  /// Detector used for [StringMatchPassFailConfig].
  final PassFailDetector stringMatchDetector;

  /// Detector used for [RegexPassFailConfig].
  final PassFailDetector regexDetector;

  /// Detector used for [CocotbPassFailConfig].
  final CocotbDetector cocotbDetector;

  /// Detector used for [UvmReportPassFailConfig].
  final PassFailDetector uvmReportDetector;

  /// Detector used for [GoldenComparePassFailConfig]. Reachable only
  /// from [classifyAsync]; see [GoldenCompareDetector].
  final PassFailDetector goldenCompareDetector;

  /// Classify the run captured by [stdout] / [stderr] / [exitCode] /
  /// [runtime] using the strategy declared in [config].
  ///
  /// Throws [UnsupportedError] for [GoldenComparePassFailConfig] — that
  /// detector is filesystem-backed and only [classifyAsync] carries the
  /// working directory it needs.
  TestStatus classify({
    required PassFailConfig config,
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
  }) {
    switch (config) {
      case ExitCodePassFailConfig():
        return exitCodeDetector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case StringMatchPassFailConfig():
        return stringMatchDetector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case RegexPassFailConfig():
        return regexDetector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case CocotbPassFailConfig():
        return cocotbDetector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case UvmReportPassFailConfig():
        return uvmReportDetector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case GoldenComparePassFailConfig():
        // Deliberately loud. This detector needs the test's working
        // directory, which the synchronous path does not carry. Falling
        // through to `unknown` here would make the scheduler adopt the
        // *driver's* status, and an exit-0 run that produced no output
        // file would be reported as a pass. A `golden_compare` leaf nested inside a `composite`
        // evaluated through the synchronous helpers below lands here
        // too — which is the point: it must fail loudly rather than
        // silently degrade.
        throw UnsupportedError(GoldenCompareDetector.kSyncPathMessage);
      case CompositePassFailConfig():
        return _classifyComposite(
          config,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
        );
    }
  }

  /// Async counterpart to [classify]. [RegexPassFailConfig] leaves are
  /// matched under a killable-isolate deadline via
  /// [RegexDetector.detectAsync] so a catastrophic-backtracking
  /// user-authored pattern cannot freeze the calling isolate; every other
  /// detector is deterministic and stays on the synchronous [classify]
  /// path. [CompositePassFailConfig] recurses through here so a regex leaf
  /// nested inside an `allOf`/`anyOf` is guarded too.
  ///
  /// [GoldenComparePassFailConfig] leaves read the DUT and golden dumps
  /// from [workingDirectory] — this is the only classification path that
  /// carries it, and the only one that can reach a filesystem-backed
  /// detector at all.
  ///
  /// [regexDeadline] is the per-match wall-clock budget handed to the
  /// guarded isolate.
  ///
  /// [workingDirectory] is the test's working directory, threaded from
  /// the scheduler's single call site. Relative dump paths resolve
  /// against it; when null they resolve against the process's current
  /// directory, so a missing file still fails rather than passing.
  Future<TestStatus> classifyAsync({
    required PassFailConfig config,
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    Duration regexDeadline = const Duration(seconds: 1),
    String? workingDirectory,
  }) async {
    switch (config) {
      case RegexPassFailConfig():
        final detector = regexDetector;
        if (detector is RegexDetector) {
          return detector.detectAsync(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            runtime: runtime,
            config: config,
            deadline: regexDeadline,
          );
        }
        // A test injected a non-default detector for the regex slot; honor
        // it on the synchronous path (no isolate guard available).
        return detector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case GoldenComparePassFailConfig():
        final detector = goldenCompareDetector;
        if (detector is GoldenCompareDetector) {
          return detector.detectAsync(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            runtime: runtime,
            config: config,
            workingDirectory: workingDirectory,
          );
        }
        // A test injected a non-default detector for the golden slot;
        // honor it on the synchronous path (it cannot see the working
        // directory, which is the injecting test's problem to solve).
        return detector.detect(
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          config: config,
        );
      case CompositePassFailConfig():
        return _classifyCompositeAsync(
          config,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
          regexDeadline: regexDeadline,
          workingDirectory: workingDirectory,
        );
      // Deterministic detectors — no ReDoS surface, run synchronously.
      // Cocotb belongs here: it matches one fixed aggregate line with no
      // user-supplied pattern, and needs no working directory because the
      // summary it reads is on stdout.
      case ExitCodePassFailConfig():
      case StringMatchPassFailConfig():
      case UvmReportPassFailConfig():
      case CocotbPassFailConfig():
        return classify(
          config: config,
          stdout: stdout,
          stderr: stderr,
          exitCode: exitCode,
          runtime: runtime,
        );
    }
  }

  // ── composite dispatch ────────────────────────────────────────────
  //
  // Inlined here rather than recursing into a separate detector so the
  // registry stays the single dispatch entry point for `all_of` /
  // `any_of` (including nested composites). AND/OR semantics are
  // covered by the composite tests in
  // `pass_fail_detector_registry_test.dart`.
  TestStatus _classifyComposite(
    CompositePassFailConfig config, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
  }) {
    final allOfStatus = _evaluateAllOf(
      config.allOf,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: runtime,
    );
    if (allOfStatus == TestStatus.fail) return TestStatus.fail;

    final anyOfStatus = _evaluateAnyOf(
      config.anyOf,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: runtime,
    );
    if (anyOfStatus == TestStatus.fail) return TestStatus.fail;

    if (allOfStatus == TestStatus.pass || anyOfStatus == TestStatus.pass) {
      return TestStatus.pass;
    }
    return TestStatus.unknown;
  }

  TestStatus _evaluateAllOf(
    List<PassFailConfig> children, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
  }) {
    if (children.isEmpty) return TestStatus.unknown;
    var sawPass = false;
    for (final child in children) {
      final status = classify(
        config: child,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        runtime: runtime,
      );
      if (status == TestStatus.fail) return TestStatus.fail;
      if (status == TestStatus.pass) sawPass = true;
    }
    return sawPass ? TestStatus.pass : TestStatus.unknown;
  }

  TestStatus _evaluateAnyOf(
    List<PassFailConfig> children, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
  }) {
    if (children.isEmpty) return TestStatus.unknown;
    var allFail = true;
    var sawSignal = false;
    for (final child in children) {
      final status = classify(
        config: child,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        runtime: runtime,
      );
      if (status == TestStatus.pass) return TestStatus.pass;
      if (status == TestStatus.fail) {
        sawSignal = true;
      } else {
        allFail = false;
      }
    }
    if (sawSignal && allFail) return TestStatus.fail;
    return TestStatus.unknown;
  }

  // ── async composite dispatch ──────────────────────────────────────
  //
  // Mirrors the synchronous composite helpers above, but awaits
  // [classifyAsync] per child so a [RegexPassFailConfig] leaf nested in a
  // composite is matched under the same isolate deadline. Short-circuit
  // and precedence semantics are identical (fail wins; a satisfied
  // `allOf`/`anyOf` yields pass; otherwise unknown).
  Future<TestStatus> _classifyCompositeAsync(
    CompositePassFailConfig config, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required Duration regexDeadline,
    required String? workingDirectory,
  }) async {
    final allOfStatus = await _evaluateAllOfAsync(
      config.allOf,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: runtime,
      regexDeadline: regexDeadline,
      workingDirectory: workingDirectory,
    );
    if (allOfStatus == TestStatus.fail) return TestStatus.fail;

    final anyOfStatus = await _evaluateAnyOfAsync(
      config.anyOf,
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: runtime,
      regexDeadline: regexDeadline,
      workingDirectory: workingDirectory,
    );
    if (anyOfStatus == TestStatus.fail) return TestStatus.fail;

    if (allOfStatus == TestStatus.pass || anyOfStatus == TestStatus.pass) {
      return TestStatus.pass;
    }
    return TestStatus.unknown;
  }

  Future<TestStatus> _evaluateAllOfAsync(
    List<PassFailConfig> children, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required Duration regexDeadline,
    required String? workingDirectory,
  }) async {
    if (children.isEmpty) return TestStatus.unknown;
    var sawPass = false;
    for (final child in children) {
      final status = await classifyAsync(
        config: child,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        runtime: runtime,
        regexDeadline: regexDeadline,
        workingDirectory: workingDirectory,
      );
      if (status == TestStatus.fail) return TestStatus.fail;
      if (status == TestStatus.pass) sawPass = true;
    }
    return sawPass ? TestStatus.pass : TestStatus.unknown;
  }

  Future<TestStatus> _evaluateAnyOfAsync(
    List<PassFailConfig> children, {
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required Duration regexDeadline,
    required String? workingDirectory,
  }) async {
    if (children.isEmpty) return TestStatus.unknown;
    var allFail = true;
    var sawSignal = false;
    for (final child in children) {
      final status = await classifyAsync(
        config: child,
        stdout: stdout,
        stderr: stderr,
        exitCode: exitCode,
        runtime: runtime,
        regexDeadline: regexDeadline,
        workingDirectory: workingDirectory,
      );
      if (status == TestStatus.pass) return TestStatus.pass;
      if (status == TestStatus.fail) {
        sawSignal = true;
      } else {
        allFail = false;
      }
    }
    if (sawSignal && allFail) return TestStatus.fail;
    return TestStatus.unknown;
  }
}

/// The telemetry `kind` tokens for the detectors [PassFailDetectorRegistry]
/// would dispatch for [config] — the config's own variant, plus every
/// variant reachable through a composite's `all_of` / `any_of` children.
///
/// **This lives beside the dispatch switch on purpose.** It is the same
/// exhaustive `switch` over `PassFailConfig`, one function down, so a seventh
/// detector variant cannot be added to the model without the compiler landing
/// the author here — and the token it must choose is the word the user already
/// writes in `simcrux.yaml`'s `pass_fail: type:`, taken verbatim from
/// `config_loader_pass_fail.dart`.
///
/// **What it deliberately does not return.** Nothing about *what* the detector
/// matched: not the regex, not the string, not the golden dump's path, not the
/// UVM severity line. Those are the contents of somebody's testbench and its
/// output, which telemetry never carries. The kind is app
/// vocabulary; everything else at this call site is not.
///
/// A `Set` because a composite of three `regex` leaves is one fact about the
/// project ("this project uses regex detection"), not three.
Set<String> passFailDetectorKindTokens(PassFailConfig config) {
  switch (config) {
    case ExitCodePassFailConfig():
      return const <String>{'exit_code'};
    case StringMatchPassFailConfig():
      return const <String>{'string_match'};
    case RegexPassFailConfig():
      return const <String>{'regex'};
    case UvmReportPassFailConfig():
      return const <String>{'uvm_report'};
    case CocotbPassFailConfig():
      return const <String>{'cocotb'};
    case GoldenComparePassFailConfig():
      return const <String>{'golden_compare'};
    case CompositePassFailConfig():
      return <String>{
        'composite',
        for (final child in <PassFailConfig>[...config.allOf, ...config.anyOf])
          ...passFailDetectorKindTokens(child),
      };
  }
}
