// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The exit-code contract of `simcrux flow ...`.
///
/// A pipeline must tell "the design has findings" from "the flow could not
/// be evaluated" from "the command line was wrong", so the codes are
/// disjoint. When one invocation has both a violation and something it could
/// not evaluate (two entries, or a threshold whose metric is missing), it
/// reports [couldNotEvaluate]: a run that could not be read in full cannot be
/// summarised as a plain finding.
///
/// ```text
///   0  met                   every threshold met, or no thresholds and the
///                            flow verdict is met
///   1  violated              a threshold or the flow verdict is violated
///   2  couldNotEvaluate      the flow stopped before producing the metric,
///                            the report is missing, or the reader cannot
///                            read the run
///   3  orgThresholdViolated  an organization policy threshold failed
///  64  usage                 unknown flag, missing value, missing path,
///                            unknown subcommand
///  65  dataErr               a report or metrics file exists but cannot be
///                            converted
///  77  licenseRequired       the command is a paid analysis and the licence
///                            this run resolved does not include it
/// 130  sigint                interrupted; the run's process trees were killed
/// 143  sigterm               terminated; the run's process trees were killed
/// ```
///
/// The usage code is 64 for every `flow` subcommand: `flow` never shipped
/// with the `2` the older importers and `--ci` keep.
///
/// [licenseRequired] is returned only by the Pro binary's flow verbs (run
/// comparison and baseline writing), whose whole output is the analysis the
/// licence pays for: a refusal there fails the job with a code of its own,
/// never 64, so a pipeline can tell "the command line was wrong" from "this
/// agent has no licence for it". Every `simcrux flow` subcommand of the open
/// binary is free and never returns it. `77` is `EX_NOPERM`, beside the
/// `EX_USAGE` and `EX_DATAERR` the family already uses.
class FlowExitCode {
  const FlowExitCode._();

  /// Every threshold met, or no thresholds and the verdict is `met`.
  static const int met = 0;

  /// A threshold or the flow verdict is violated. Findings, not signoff.
  static const int violated = 1;

  /// The flow could not be evaluated.
  static const int couldNotEvaluate = 2;

  /// An organization policy threshold failed, separately from the user's
  /// own.
  static const int orgThresholdViolated = 3;

  /// The command line could not be honoured.
  static const int usage = 64;

  /// An input exists but cannot be converted.
  static const int dataErr = 65;

  /// A paid flow analysis was refused for want of a licence tier.
  static const int licenseRequired = 77;

  /// Interrupted by SIGINT, re-exited as 128 + 2.
  static const int sigint = 130;

  /// Terminated by SIGTERM, re-exited as 128 + 15.
  static const int sigterm = 143;

  /// Every code the `flow` command family can return ([licenseRequired] only
  /// from the Pro binary's verbs).
  static const List<int> all = <int>[
    met,
    violated,
    couldNotEvaluate,
    orgThresholdViolated,
    usage,
    dataErr,
    licenseRequired,
    sigint,
    sigterm,
  ];

  /// A short, stable label for [code], printed on the last line of a run
  /// and in `--json` as `exit_label`.
  static String labelFor(int code) => switch (code) {
    met => 'met',
    violated => 'violated',
    couldNotEvaluate => 'could_not_evaluate',
    orgThresholdViolated => 'org_threshold_violated',
    usage => 'usage',
    dataErr => 'data_err',
    licenseRequired => 'license_required',
    sigint => 'sigint',
    sigterm => 'sigterm',
    _ => 'unexpected',
  };
}
