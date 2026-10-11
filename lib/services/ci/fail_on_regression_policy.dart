// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The Flutter-free licence barrel, for the same reason as the Riverpod
// import below: this file is in the headless CLI's import closure.
import 'package:crux_license/crux_license_core.dart';
import 'package:meta/meta.dart';
// `package:riverpod` (not `flutter_riverpod`): this file sits inside the
// headless CLI's import closure (`SimcruxCli` needs the policy interface
// and its open-core default), and the Flutter-bound barrel would fail the
// `dart build cli` link. The provider type is identical — flutter_riverpod
// re-exports it — so every existing consumer is unaffected.
import 'package:riverpod/riverpod.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/domain/models/test_run.dart';

/// Decision returned by [FailOnRegressionPolicy.shouldFailWithExitCode].
///
/// `failed` indicates whether the gate failed the run: the candidate
/// regressed relative to the configured baseline, or the gate could not
/// be evaluated at all. `exitCode` is the process exit status the CI
/// runner should use. When `failed` is `false`, `exitCode` is always `0`.
/// The Pro implementation computes the regression exit code from the
/// `SIMCRUX_REGRESSION_EXIT_CODE` environment variable (default `1`) —
/// see [FailOnRegressionPolicy]'s doc comment below. A gate that could
/// not be evaluated fails with exit code `2` and says why in [reason].
@immutable
class FailOnRegressionDecision {
  /// Creates a [FailOnRegressionDecision].
  const FailOnRegressionDecision({
    required this.failed,
    required this.exitCode,
    this.reason,
  });

  /// A gate that was asked for and cannot run in this build: the
  /// regression comparison engine is not linked into it. Exit code `2`,
  /// the CLI's "could not do what was asked", with [reason] telling the
  /// operator which executable does carry the engine.
  const FailOnRegressionDecision.unavailable(String this.reason)
    : failed = true,
      exitCode = 2;

  /// "Did the gate fail the run?" — a regression relative to baseline,
  /// or a gate that could not be evaluated.
  final bool failed;

  /// Process exit code the CI runner should use: 0 when [failed] is
  /// false; non-zero when [failed] is true (the Pro implementation
  /// defaults to 1 for a regression, overridable via
  /// `SIMCRUX_REGRESSION_EXIT_CODE` — see the class doc comment above).
  final int exitCode;

  /// Why the gate failed, for the operator, or null when there is nothing
  /// to add beyond the exit code. `CiRunner` writes it to stderr after an
  /// `error: regression gate: ` prefix, so a policy reports through the
  /// runner's own writer instead of printing for itself.
  final String? reason;

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
          other.exitCode == exitCode &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(failed, exitCode, reason);

  @override
  String toString() =>
      'FailOnRegressionDecision(failed: $failed, exitCode: $exitCode'
      '${reason == null ? '' : ', reason: $reason'})';
}

/// Extension-point interface the Pro overlay implements to gate the
/// CI exit code on regression detection.
///
/// **Open-core default.** [UnavailableFailOnRegressionPolicy] refuses
/// every call with [FailOnRegressionDecision.unavailable]: the comparison
/// engine lives in the Pro overlay, so a build without it (the standalone
/// headless `simcrux` binary, an open-source desktop build) cannot
/// evaluate the gate, and a gate the job asked for and did not get must
/// not report green. The refusal names the executable that does carry
/// the engine.
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
/// Single-method but a real strategy seam: the open-core default
/// refuses; the Pro implementation runs the comparison engine.
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

/// The stderr text (after `error: regression gate: `) for a gate that this
/// build cannot evaluate.
///
/// English-only like every other line `--ci` prints: a CI log has no locale.
const String kRegressionGateUnavailableReason =
    "this build doesn't include the regression comparison engine. Run --ci "
    "from the SimCrux desktop app's executable (on macOS, "
    'SimCrux.app/Contents/MacOS/SimCrux) with a Pro license.';

/// Open-core default: refuses the gate.
///
/// Returns [FailOnRegressionDecision.unavailable] with
/// [kRegressionGateUnavailableReason] for every call, so `--fail-on-regression
/// --baseline` in a build without the comparison engine fails the run with
/// exit code `2` and says which executable to use, instead of exiting `0` as
/// if the gate had run and found nothing. The Pro overlay replaces this with
/// `ProFailOnRegressionPolicy`.
class UnavailableFailOnRegressionPolicy implements FailOnRegressionPolicy {
  /// Const default.
  const UnavailableFailOnRegressionPolicy();

  @override
  Future<FailOnRegressionDecision> shouldFailWithExitCode({
    required TestRun candidate,
    required CliArgs args,
    required LicenseTier licenseTier,
  }) async {
    return const FailOnRegressionDecision.unavailable(
      kRegressionGateUnavailableReason,
    );
  }
}

/// Extension-point seam. Open-core default is the refusing policy; the
/// Pro overlay overrides with `ProFailOnRegressionPolicy` (which
/// runs `RegressionComparisonEngine` against the baseline snapshot
/// referenced by [CliArgs.baselineRunPath]).
final Provider<FailOnRegressionPolicy> failOnRegressionPolicyProvider =
    Provider<FailOnRegressionPolicy>(
      (_) => const UnavailableFailOnRegressionPolicy(),
    );
