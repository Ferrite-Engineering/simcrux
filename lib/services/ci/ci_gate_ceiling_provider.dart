// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/cli/cli_args.dart';

/// The organization's ceiling on failed tests for a `--ci` run, or null when
/// none applies.
///
/// A seam. Open core resolves null; an edition that honours organization
/// policy overrides it. The desktop `--ci` branch of `bootstrap()` reads it
/// and applies it with [applyCiGateCeiling].
///
/// A **ceiling**, the same quantity LintCrux's key of the same name
/// thresholds: the number of failures a run may have and still pass. `0`
/// means any failure fails the run.
final Provider<int?> ciGateCeilingProvider = Provider<int?>(
  (ref) => null,
  name: 'ciGateCeilingProvider',
);

/// Returns [args] with [ceiling] applied as the `--fail-threshold`, or
/// [args] unchanged.
///
/// **An explicit `--fail-threshold` wins.** The ceiling replaces only the
/// flag's default, so it applies when [CliArgs.failThresholdExplicit] is
/// false. A pipeline that types the flag has said what it wants for that
/// job, and the organization's number is the default for every job that
/// has not.
///
/// The flag is `exit non-zero when failures >= n` and the ceiling is
/// `failures may not exceed n`, so a ceiling of `n` becomes a threshold of
/// `n + 1`.
///
/// [note] receives one line saying the organization's ceiling is in force,
/// so a job log explains a red build the pipeline did not configure.
CliArgs applyCiGateCeiling(
  CliArgs args, {
  required int? ceiling,
  required void Function(String line) note,
}) {
  if (ceiling == null || ceiling < 0 || args.failThresholdExplicit) {
    return args;
  }
  note(
    'simcrux: the organization policy sets the failure ceiling to $ceiling '
    '(ciGateThreshold); this run fails when more than $ceiling '
    '${ceiling == 1 ? 'test fails' : 'tests fail'}. '
    'Pass --fail-threshold to set it for this job.',
  );
  return args.copyWith(failThreshold: ceiling + 1);
}
