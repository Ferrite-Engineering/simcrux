// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';

/// How a formal row's verdict is worded, a finer split than [FormalBucket].
///
/// The bucket says which of the four a verdict is; this says what may be
/// claimed about it. A bounded (BMC) pass held only over its steps, so it is
/// never worded as a bare proof; a cover pass reached its covers; a pass
/// that checked no property at all proves nothing and says so.
enum FormalVerdictWording {
  /// An unbounded proof (`prove`, `live`) held.
  proved,

  /// A bounded proof held over [FormalResultSummary.depthConfigured] steps.
  provedOverSteps,

  /// A pass whose bound or mode was not recorded: worded as bounded, never
  /// as a proof.
  provedBounded,

  /// A cover task reached every cover statement.
  reached,

  /// The task passed with no property checked: nothing was proved.
  noPropertiesChecked,

  /// An assertion failed with a trace.
  counterexample,

  /// A cover task left a cover statement unreached.
  notReached,

  /// Nothing was learned.
  inconclusive,

  /// A tooling problem: the check never ran.
  didNotRun,

  /// A stored verdict this build cannot read.
  unrecognised,
}

/// The formal facts of one result row, read back from its metrics.
///
/// One reader for every surface that has to know whether a row is formal
/// and what it may say: the results table's Verdict column and status glyph,
/// the run telemetry, and the WaveCrux hand-off's origin. Pure (`domain/`),
/// so the headless CLI and the web viewer read it too.
///
/// The metric keys are spelled here as literals because `domain/` may not
/// import the drivers that write them; a test holds them equal to the
/// drivers' constants.
@immutable
class FormalResultSummary {
  /// Creates a summary.
  const FormalResultSummary({
    required this.tool,
    required this.verdictToken,
    this.mode,
    this.engine,
    this.depthConfigured,
    this.properties,
    this.propertiesFailed,
    this.propertiesUndecided,
    this.assertionsDisabled,
  });

  /// `formal.verdict`.
  static const String kVerdictKey = 'formal.verdict';

  /// `formal.tool`.
  static const String kToolKey = 'formal.tool';

  /// `formal.mode`.
  static const String kModeKey = 'formal.mode';

  /// `formal.engine`.
  static const String kEngineKey = 'formal.engine';

  /// `formal.depth_configured`.
  static const String kDepthConfiguredKey = 'formal.depth_configured';

  /// `formal.properties`.
  static const String kPropertiesKey = 'formal.properties';

  /// `formal.properties_failed`.
  static const String kPropertiesFailedKey = 'formal.properties_failed';

  /// `formal.properties_undecided`.
  static const String kPropertiesUndecidedKey = 'formal.properties_undecided';

  /// `formal.assertions_disabled`.
  static const String kAssertionsDisabledKey = 'formal.assertions_disabled';

  /// `riscv.formal.verdict`, which every RISC-V formal row carries.
  static const String kRiscvVerdictKey = 'riscv.formal.verdict';

  /// `riscv.formal.proof_mode`.
  static const String kRiscvProofModeKey = 'riscv.formal.proof_mode';

  /// `riscv.formal.depth_configured`.
  static const String kRiscvDepthConfiguredKey =
      'riscv.formal.depth_configured';

  /// `riscv.formal.engine`.
  static const String kRiscvEngineKey = 'riscv.formal.engine';

  /// [tool] for a `simulator: sby` row.
  static const String kToolSby = 'sby';

  /// [tool] for a `simulator: eqy` row.
  static const String kToolEqy = 'eqy';

  /// [tool] for a `simulator: riscv_formal` row.
  static const String kToolRiscvFormal = 'riscv_formal';

  /// The summary of [metrics], or null when the row is not a formal one.
  ///
  /// A row is formal when it carries `formal.verdict` or the RISC-V track's
  /// `riscv.formal.verdict` (a row stored before the general driver existed
  /// carries only the second).
  static FormalResultSummary? fromMetrics(Map<String, String> metrics) {
    final riscv = metrics[kRiscvVerdictKey];
    final general = metrics[kVerdictKey];
    final token = general ?? riscv;
    if (token == null) return null;
    final tool = riscv != null
        ? kToolRiscvFormal
        : (metrics[kToolKey] == kToolEqy ? kToolEqy : kToolSby);
    final engine = metrics[kEngineKey] ?? metrics[kRiscvEngineKey];
    return FormalResultSummary(
      tool: tool,
      verdictToken: token,
      mode: metrics[kModeKey] ?? metrics[kRiscvProofModeKey],
      engine: engine?.trim().split(RegExp(r'\s+')).first,
      depthConfigured: int.tryParse(
        metrics[kDepthConfiguredKey] ?? metrics[kRiscvDepthConfiguredKey] ?? '',
      ),
      properties: int.tryParse(metrics[kPropertiesKey] ?? ''),
      propertiesFailed: int.tryParse(metrics[kPropertiesFailedKey] ?? ''),
      propertiesUndecided: int.tryParse(
        metrics[kPropertiesUndecidedKey] ?? '',
      ),
      assertionsDisabled: metrics[kAssertionsDisabledKey],
    );
  }

  /// `sby`, `eqy` or `riscv_formal`.
  final String tool;

  /// The stored verdict token, verbatim.
  final String verdictToken;

  /// The proof mode (`bmc`, `prove`, `cover`, `live`), when recorded.
  final String? mode;

  /// The engine word (`smtbmc`, `abc`), when recorded.
  final String? engine;

  /// The configured bound, when the job file set one.
  final int? depthConfigured;

  /// How many properties the run checked, when the status was read.
  final int? properties;

  /// Properties that ended as a counterexample or unreached.
  final int? propertiesFailed;

  /// Properties that ended undecided or did not run.
  final int? propertiesUndecided;

  /// `noassert` or `ignore_assertions` when the script turned assertions
  /// off.
  final String? assertionsDisabled;

  /// The parsed verdict, or null for a token this build cannot read.
  FormalVerdict? get verdict => FormalVerdict.fromWireName(verdictToken);

  /// The display bucket. Unrecognised for a token this build cannot read.
  FormalBucket get bucket => FormalBucket.ofStored(verdictToken);

  /// What the row may claim. Never resolves toward a proof: an unknown
  /// bound is worded as bounded, and a pass with no property checked is
  /// worded as nothing proved.
  FormalVerdictWording get wording {
    switch (bucket) {
      case FormalBucket.proved:
        if (properties == 0) return FormalVerdictWording.noPropertiesChecked;
        switch (mode) {
          case 'prove' || 'live':
            return FormalVerdictWording.proved;
          case 'cover':
            return FormalVerdictWording.reached;
          case 'bmc':
            return depthConfigured != null && depthConfigured! > 0
                ? FormalVerdictWording.provedOverSteps
                : FormalVerdictWording.provedBounded;
          default:
            return FormalVerdictWording.provedBounded;
        }
      case FormalBucket.counterexample:
        return mode == 'cover'
            ? FormalVerdictWording.notReached
            : FormalVerdictWording.counterexample;
      case FormalBucket.inconclusive:
        return FormalVerdictWording.inconclusive;
      case FormalBucket.didNotRun:
        return FormalVerdictWording.didNotRun;
      case FormalBucket.unrecognised:
        return FormalVerdictWording.unrecognised;
    }
  }

  /// Sort rank for the Verdict column: the most urgent first.
  int get sortRank => switch (bucket) {
    FormalBucket.counterexample => 0,
    FormalBucket.didNotRun => 1,
    FormalBucket.unrecognised => 2,
    FormalBucket.inconclusive => 3,
    FormalBucket.proved =>
      wording == FormalVerdictWording.noPropertiesChecked ? 4 : 5,
  };
}
