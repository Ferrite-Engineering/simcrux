// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/pass_fail_detector.dart';
import 'package:simcrux/domain/models/golden_comparator.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';

/// Pass/fail classifier that compares a DUT output dump against
/// a committed golden reference dump.
///
/// Honors [GoldenComparePassFailConfig]. Reads both files from the test's
/// working directory and hands the text to the shared, pure
/// [GoldenComparator]. The verdict is binary:
///
/// - every word equal under the configured
///   `GoldenCompareProfile`, and at least one word present ⇒
///   [TestStatus.pass];
/// - anything else ⇒ [TestStatus.fail].
///
/// Architecture neutral by construction: RISC-V architectural signatures
/// are the flagship use, but they arrive as a *profile*, and nothing in
/// this class knows about any ISA.
///
/// ## Why it never returns `unknown` or `vacuous`
///
/// Both of the other plausible answers are traps that would let a broken
/// DUT report green:
///
/// - A detector that returns [TestStatus.unknown] hands classification
///   back to the **driver**, and a run that produced no output file at
///   all typically still exits 0 — which the driver reads as a pass.
/// - [TestStatus.vacuous] is success-equivalent to the scheduler: it is
///   not retried and the working directory holding the evidence is
///   deleted. Nothing in `lib/` produces `vacuous` today and
///   `golden_compare` must not become the first thing that does.
///
/// So a **missing** file on either side, an **empty** dump on either
/// side, an unreadable file, and a length divergence are all
/// [TestStatus.fail].
///
/// ## Why it is async-only
///
/// [PassFailDetector.detect] is synchronous and receives only stdout /
/// stderr / exit code / runtime — no filesystem, no working directory.
/// The dumps live in a directory the scheduler allocates at run
/// time, so this detector is reachable only through [detectAsync], which
/// `PassFailDetectorRegistry.classifyAsync` calls with the working
/// directory threaded from the scheduler's single call site. [detect]
/// throws rather than guessing; silently returning `unknown` there is
/// exactly the failure mode above.
///
/// ## Metrics
///
/// This detector **only classifies**. It does not — and structurally
/// cannot — attach the mismatch offset to the result:
/// `TestResult.metrics` is fed solely from
/// `TestExecutionFinished.metrics`, which only a driver emits. That is
/// deliberate doctrine (see `UvmReportDetector`'s doc comment), and this
/// detector keeps it: a driver calls the same [GoldenComparator] and emits
/// `GoldenComparison.toMetrics()` under the reserved `golden.*` keys.
///
/// **Documented consequence, not papered over:** under a driver that does
/// not emit those metrics — a user wiring
/// `pass_fail: { type: golden_compare }` onto an ordinary Icarus or
/// Verilator test that writes its own output file — the verdict is still
/// correct, but **no `golden.*` offset metrics are emitted**, because no
/// driver emitted them. A Pro diff viewer will have a verdict and no
/// offset to render for such a test.
///
/// ## Tiering
///
/// The compatibility verdict is open core and is **never** gated — not by
/// `LicenseTier`, not by `FeatureGate`, not after `kBetaPeriod` flips:
/// correctness is free. Do
/// not add a gate here.
class GoldenCompareDetector implements PassFailDetector {
  /// Const constructor.
  const GoldenCompareDetector();

  /// The message raised whenever `golden_compare` is reached through a
  /// synchronous classification path. Shared with the registry so both
  /// loud failures read identically.
  static const String kSyncPathMessage =
      'golden_compare cannot be classified synchronously: it compares '
      'files in the test working directory, which '
      'PassFailDetector.detect() does not receive. Route it through '
      'PassFailDetectorRegistry.classifyAsync(workingDirectory: ...) — '
      'including when it is nested as a composite leaf. Degrading to '
      'TestStatus.unknown here would hand the verdict back to the driver, '
      'and an exit-0 run with no output file would silently report pass.';

  /// Always throws [UnsupportedError].
  ///
  /// The comparison needs the filesystem and the test's working
  /// directory, neither of which this interface provides. Returning
  /// [TestStatus.unknown] instead would make the scheduler fall back to
  /// the driver's status — an exit-0 run with no output would report
  /// **pass**. Failing loudly is the point: the only supported
  /// entry point is [detectAsync].
  @override
  TestStatus detect({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
  }) {
    throw UnsupportedError(kSyncPathMessage);
  }

  /// Classifies the run by comparing the two dumps.
  ///
  /// Relative paths in [config] resolve against [workingDirectory]; when
  /// it is null they resolve against the process's current directory (a
  /// missing file then simply fails, which is the correct answer either
  /// way). Absolute paths are used as given.
  Future<TestStatus> detectAsync({
    required String stdout,
    required String stderr,
    required int? exitCode,
    required Duration runtime,
    required PassFailConfig config,
    String? workingDirectory,
  }) async {
    if (config is! GoldenComparePassFailConfig) {
      // A dispatch/wiring defect. `unknown` would fall back to the
      // driver's status, so refuse to pass instead.
      return TestStatus.fail;
    }

    final dutText = await _read(config.dutPath, workingDirectory);
    if (dutText == null) return TestStatus.fail;
    final refText = await _read(config.referencePath, workingDirectory);
    if (refText == null) return TestStatus.fail;

    final comparison = GoldenComparator.compare(
      dut: dutText,
      reference: refText,
      profile: config.profile,
    );
    // `matched` is false for an empty dump on either side, for a length
    // divergence, and for a word divergence — every one of which is a
    // failure, never `vacuous`.
    return comparison.matched ? TestStatus.pass : TestStatus.fail;
  }

  /// Resolves [path] and reads it, or returns null when it is missing or
  /// unreadable (a directory, a permission error, a dangling symlink).
  Future<String?> _read(String path, String? workingDirectory) async {
    final resolved = resolvePath(path, workingDirectory);
    try {
      final file = File(resolved);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// Resolves a configured dump path against [workingDirectory].
  ///
  /// Exposed for drivers (`riscv_arch`) and for tests so the resolution rule has
  /// one definition: absolute paths pass through untouched; relative
  /// paths join onto the working directory when there is one, and are
  /// otherwise left relative to the process's current directory.
  static String resolvePath(String path, String? workingDirectory) {
    if (p.isAbsolute(path)) return path;
    if (workingDirectory == null || workingDirectory.isEmpty) return path;
    return p.join(workingDirectory, path);
  }
}
