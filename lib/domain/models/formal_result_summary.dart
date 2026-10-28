// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/formal_bucket.dart';
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/domain/enums/formal_verdict.dart';
import 'package:simcrux/domain/models/formal_diagnostic.dart';

/// How a formal row's verdict is worded, a finer split than [FormalBucket].
///
/// The bucket says which of the four a verdict is; this says what may be
/// claimed about it. A bounded (BMC) pass held only over its steps, so it is
/// never worded as a bare proof; a cover pass reached its covers; a pass
/// that checked no property at all proves nothing and says so.
enum FormalVerdictWording {
  /// An unbounded proof (`prove`, `live`) held.
  proved,

  /// An EQY run proved every one of its partitions equivalent.
  provedEquivalent,

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

/// One partition of an EQY row, read back from its metrics.
@immutable
class FormalPartitionRow {
  /// Creates a row.
  const FormalPartitionRow({
    required this.name,
    required this.status,
    this.trace,
    this.step,
  });

  /// The partition's name (`alu.z`). Never translated.
  final String name;

  /// What it ended as: proved, counterexample, inconclusive or did not run.
  final FormalPropertyStatus status;

  /// Its counterexample, relative to the run's work directory.
  final String? trace;

  /// The step its counterexample failed at, when the solver stated one.
  final int? step;
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
    this.solver,
    this.depthConfigured,
    this.properties,
    this.propertiesFailed,
    this.propertiesUndecided,
    this.assertionsDisabled,
    this.frontend,
    this.notRunReason,
    this.svaRefusal,
    this.pretrace,
  });

  /// `formal.frontend`.
  static const String kFrontendKey = 'formal.frontend';

  /// `formal.not_run_reason`.
  static const String kNotRunReasonKey = 'formal.not_run_reason';

  /// `formal.sva.class`.
  static const String kSvaClassKey = 'formal.sva.class';

  /// `formal.sva.construct`.
  static const String kSvaConstructKey = 'formal.sva.construct';

  /// `formal.sva.location`.
  static const String kSvaLocationKey = 'formal.sva.location';

  /// `formal.pretrace.kind`.
  static const String kPretraceKindKey = 'formal.pretrace.kind';

  /// `formal.pretrace.depth`.
  static const String kPretraceDepthKey = 'formal.pretrace.depth';

  /// `formal.pretrace.step`.
  static const String kPretraceStepKey = 'formal.pretrace.step';

  /// `formal.pretrace.location`.
  static const String kPretraceLocationKey = 'formal.pretrace.location';

  /// `formal.verdict`.
  static const String kVerdictKey = 'formal.verdict';

  /// `formal.tool`.
  static const String kToolKey = 'formal.tool';

  /// `formal.mode`.
  static const String kModeKey = 'formal.mode';

  /// `formal.engine`.
  static const String kEngineKey = 'formal.engine';

  /// `formal.solver`.
  static const String kSolverKey = 'formal.solver';

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
    final engineWords = engine?.trim().split(RegExp(r'\s+'));
    // A RISC-V row stored before the general driver existed carries the
    // whole engine line (`smtbmc boolector`) and no `formal.solver`.
    final solver =
        metrics[kSolverKey] ??
        (engineWords == null || engineWords.length < 2
            ? null
            : engineWords.skip(1).join(' '));
    final frontend = FormalFrontend.fromWireName(metrics[kFrontendKey]);
    final svaClass = SvaConstructClass.fromWireName(metrics[kSvaClassKey]);
    final location = metrics[kSvaLocationKey];
    final colon = location?.lastIndexOf(':') ?? -1;
    final pretraceDepth = int.tryParse(metrics[kPretraceDepthKey] ?? '');
    final pretraceStep = int.tryParse(metrics[kPretraceStepKey] ?? '');
    final pretraceKind = metrics[kPretraceKindKey];
    return FormalResultSummary(
      tool: tool,
      verdictToken: token,
      mode: metrics[kModeKey] ?? metrics[kRiscvProofModeKey],
      engine: engineWords?.first,
      solver: solver,
      depthConfigured: int.tryParse(
        metrics[kDepthConfiguredKey] ?? metrics[kRiscvDepthConfiguredKey] ?? '',
      ),
      properties: int.tryParse(metrics[kPropertiesKey] ?? ''),
      propertiesFailed: int.tryParse(metrics[kPropertiesFailedKey] ?? ''),
      propertiesUndecided: int.tryParse(
        metrics[kPropertiesUndecidedKey] ?? '',
      ),
      assertionsDisabled: metrics[kAssertionsDisabledKey],
      frontend: frontend,
      notRunReason: FormalNotRunReason.fromWireName(metrics[kNotRunReasonKey]),
      svaRefusal: svaClass == null
          ? null
          : SvaRefusal(
              constructClass: svaClass,
              frontend: frontend ?? FormalFrontend.unknown,
              construct: metrics[kSvaConstructKey],
              file: location == null
                  ? null
                  : (colon > 0 ? location.substring(0, colon) : location),
              line: colon > 0
                  ? int.tryParse(location!.substring(colon + 1))
                  : null,
            ),
      pretrace:
          pretraceDepth == null || pretraceStep == null || pretraceKind == null
          ? null
          : FormalPretraceMarker(
              kind: pretraceKind,
              depth: pretraceDepth,
              step: pretraceStep,
              location: metrics[kPretraceLocationKey],
            ),
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

  /// The rest of the engine line, as written (`boolector`, `pdr`,
  /// `--nopresat yices`), when there was one.
  final String? solver;

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

  /// The frontend that read the design, when recorded.
  final FormalFrontend? frontend;

  /// Why the row did not run, when SimCrux knows.
  final FormalNotRunReason? notRunReason;

  /// The refused SVA construct, when the frontend refused one.
  final SvaRefusal? svaRefusal;

  /// The first property whose result depends on state from before the
  /// trace began, when one does.
  final FormalPretraceMarker? pretrace;

  /// The parsed verdict, or null for a token this build cannot read.
  FormalVerdict? get verdict => FormalVerdict.fromWireName(verdictToken);

  /// The display bucket. Unrecognised for a token this build cannot read;
  /// Did not run whenever [notRunReason] says so, whatever the token (a
  /// `PASS` whose properties were all dropped checked nothing).
  FormalBucket get bucket => notRunReason != null
      ? FormalBucket.didNotRun
      : FormalBucket.ofStored(verdictToken);

  /// What the row may claim. Never resolves toward a proof: an unknown
  /// bound is worded as bounded, and a pass with no property checked is
  /// worded as nothing proved.
  FormalVerdictWording get wording {
    switch (bucket) {
      case FormalBucket.proved:
        if (properties == 0) return FormalVerdictWording.noPropertiesChecked;
        // The `eqy` driver writes `PASS` only when every partition was
        // proved; a run that proved some is never in this bucket.
        if (tool == kToolEqy) return FormalVerdictWording.provedEquivalent;
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

  /// The partitions of an `eqy` row, in the order the run listed them;
  /// empty for every other row. Read from the same indexed
  /// `formal.property.<n>.*` keys a property row uses, `kind` `partition`.
  static List<FormalPartitionRow> partitionsOf(Map<String, String> metrics) {
    if (metrics[kToolKey] != kToolEqy) return const <FormalPartitionRow>[];
    final rows = <FormalPartitionRow>[];
    for (var n = 0; ; n++) {
      final prefix = 'formal.property.$n.';
      final kind = metrics['${prefix}kind'];
      if (kind == null) break;
      if (kind != 'partition') continue;
      final status = FormalPropertyStatus.fromWireName(
        metrics['${prefix}status'],
      );
      rows.add(
        FormalPartitionRow(
          name: metrics['${prefix}label'] ?? metrics['${prefix}location'] ?? '',
          // A status this build cannot read never reads as proved.
          status: status ?? FormalPropertyStatus.didNotRun,
          trace: metrics['${prefix}trace'],
          step: int.tryParse(metrics['${prefix}step'] ?? ''),
        ),
      );
    }
    return rows;
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
