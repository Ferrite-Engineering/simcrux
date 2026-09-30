// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The Flutter-free licence barrel, for the same reason as the Riverpod
// import below: this file is in the headless CLI's import closure.
import 'package:crux_license/crux_license_core.dart';
import 'package:meta/meta.dart';
// `package:riverpod` (not `flutter_riverpod`): this file sits inside the
// headless CLI's import closure (`SimcruxCli` needs the policy interface
// and its no-op), and the Flutter-bound barrel would fail the
// `dart build cli` link. The provider type is identical — flutter_riverpod
// re-exports it — so every existing consumer is unaffected.
import 'package:riverpod/riverpod.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/models/test_run.dart';

/// Decision returned by [FailOnRegressionPolicy.shouldFailWithExitCode].
///
/// `failed` indicates whether the candidate run regressed relative to
/// the configured baseline; `exitCode` is the process exit status the
/// CI runner should use. When `failed` is `false`, `exitCode` is
/// always `0`. Open-core's [NoopFailOnRegressionPolicy] never sets
/// `failed: true` (the comparison engine lives in the Pro overlay);
/// the Pro implementation, when it does, computes `exitCode` from the
/// `SIMCRUX_REGRESSION_EXIT_CODE` environment variable (default `1`)
/// — see [FailOnRegressionPolicy]'s doc comment below.
@immutable
class FailOnRegressionDecision {
  /// Creates a [FailOnRegressionDecision].
  const FailOnRegressionDecision({
    required this.failed,
    required this.exitCode,
  });

  /// "Did the candidate regress relative to baseline?"
  final bool failed;

  /// Process exit code the CI runner should use: 0 when [failed] is
  /// false; non-zero when [failed] is true (the Pro implementation
  /// defaults to 1, overridable via `SIMCRUX_REGRESSION_EXIT_CODE` —
  /// see the class doc comment above).
  final int exitCode;

  /// Convenience: "no regression detected" decision (`failed=false`,
  /// `exitCode=0`).
  static const FailOnRegressionDecision pass = FailOnRegressionDecision(
    failed: false,
    exitCode: 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FailOnRegressionDecision &&
          other.failed == failed &&
          other.exitCode == exitCode;

  @override
  int get hashCode => Object.hash(failed, exitCode);

  @override
  String toString() =>
      'FailOnRegressionDecision(failed: $failed, exitCode: $exitCode)';
}

/// Extension-point interface the Pro overlay implements to gate the
/// CI exit code on regression detection.
///
/// **Open-core default.** [NoopFailOnRegressionPolicy] returns
/// [FailOnRegressionDecision.pass] for every call — open-core builds
/// never fail a CI run on regression because the comparison engine
/// lives in the Pro overlay.
///
/// **Pro override.** The Pro overlay registers a concrete
/// implementation that:
///
/// 1. Reads the baseline reference from [CliArgs.baselineRunPath]
///    (a `.ndjson` snapshot produced by a prior `--ci` run with
///    streaming enabled).
/// 2. Parses the snapshot into a [TestRun].
/// 3. Runs `RegressionComparisonEngine.compare(baseline, candidate)`.
/// 4. Returns `(diff.isRegression, exitCode)` where exitCode reads
///    the `SIMCRUX_REGRESSION_EXIT_CODE` env var (default 1).
///
/// **When the baseline is unavailable.** A `--baseline` file that is
/// missing, unreadable or holds no results is a failed gate, not a pass:
/// the Pro implementation writes an error to stderr and returns
/// `failed: true` with exit code 2, so a mistyped path in a CI script
/// cannot silently disable the gate. `CiRunner` keeps the higher of that
/// code and the fail-threshold code.
///
/// **When the licence does not include it.** The comparison engine is a
/// paid capability, and the executable that carries it is the one every
/// user downloads, so the implementation that provides it decides whether
/// this run may use it. It is told the tier the run resolved (`--license-file`,
/// then `SIMCRUX_LICENSE_FILE`, then the organization policy file) rather
/// than reading one of its own, so the gate and the `seeds:` expansion agree
/// about what the run is licensed for. A refusal is reported on stderr and
/// fails the run with exit code 2, the same as a baseline that cannot be
/// read: a gate the job asked for and did not get must not report green.
///
/// Single-method but a real strategy seam: the open-core default is
/// always-pass; the Pro implementation runs the comparison engine.
/// The abstract class is load-bearing so Pro overrides do not need
/// to redefine the typedef.
abstract class FailOnRegressionPolicy {
  /// Returns the decision for the just-completed [candidate] run.
  ///
  /// [licenseTier] is the tier this run resolved, before any beta unlock is
  /// applied — see the class doc.
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  });
}

/// Open-core default. Always returns [FailOnRegressionDecision.pass]
/// so the CI exit code is not affected by regression analysis. The
/// Pro overlay replaces this with `ProFailOnRegressionPolicy`.
class NoopFailOnRegressionPolicy implements FailOnRegressionPolicy {
  /// Const default.
  const NoopFailOnRegressionPolicy();

  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    return FailOnRegressionDecision.pass;
  }
}

/// Extension-point seam. Open-core default is the no-op policy; the
/// Pro overlay overrides with `ProFailOnRegressionPolicy` (which
/// runs `RegressionComparisonEngine` against the baseline snapshot
/// referenced by [CliArgs.baselineRunPath]).
final Provider<FailOnRegressionPolicy> failOnRegressionPolicyProvider =
    Provider<FailOnRegressionPolicy>(
      (_) => const NoopFailOnRegressionPolicy(),
    );
