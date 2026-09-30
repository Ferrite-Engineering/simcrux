// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/diagnostics/providers/simulator_versions_provider.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Sentinel rendered when the simulator version probe has not resolved yet.
///
/// Now `crux_issue_reporter`'s shared `(unavailable)` rather than SimCrux's
/// own `(not detected)`. The four products had each invented a placeholder
/// vocabulary and drifted; a maintainer triaging a bug reads these four
/// reports side by side, so the wording is worth having in one place. The
/// meaning is unchanged and is exactly what `unavailable` documents — "we
/// could not determine this", as opposed to "there are zero".
const String kIssueSessionNotProbed = CruxIssueFallback.unavailable;

/// Rendered in place of a version-banner token that failed the path scrub.
///
/// Note this is a *token-level* substitution inside a third-party string, not
/// a whole withheld field, so it uses the shared constant directly rather than
/// `CruxIssueSessionContextBuilder.redact` — which substitutes an entire
/// field's value and, deliberately, records no attribute for it. SimCrux has
/// no wholly-withheld field: it excludes private values rather than
/// redacting them in place.
const String kIssueSessionRedacted = CruxIssueFallback.redacted;

/// Builds SimCrux's privacy-scrubbed Session State snapshot for the shared
/// beta issue reporter.
///
/// ## The privacy contract, stated concretely for SimCrux
///
/// SimCrux sessions are saturated with private strings — the project directory,
/// every source and testbench path, dump-file and log-file paths, and the
/// user's own suite / test / top-module names. **None of it may reach a public
/// GitHub issue.** What ships is counts, a fixed vocabulary of simulator ids
/// (`icarus` / `verilator` / `ghdl` / `cocotb`), detected tool version banners
/// (scrubbed, see [scrubVersionBanner]), and enum names.
///
/// Specifically excluded, and each for a reason:
///
/// - `RegressionConfig.projectFilePath` — a filesystem path, and often the
///   user's employer / project name.
/// - `Suite.name`, `TestSpec.name`, `TestSpec.top` — user-authored testbench
///   and DUT identifiers; frequently the most confidential strings in the
///   whole session.
/// - `TestResult.stdoutPath` / `stderrPath` / `waveformPath` /
///   `failureMessage` — paths, and log text that quotes the design.
/// - `AppSettings.simulatorBinaryOverrides` values and
///   `recentProjectPaths` — paths. Only their *counts* appear.
///
/// The regression test `PRIVACY: a Session State body carries no file paths`
/// drives this contributor from a fully populated session (loaded project with
/// real on-disk paths, completed run with dump and log files) and asserts the
/// rendered markdown contains no path separators.
///
/// ## Degradation
///
/// Every read is defensive. In a bare `ProviderContainer` with no workspace
/// plumbing the per-tab lookups throw; the contributor catches and returns
/// whatever it has, so opening the reporter can never itself be the crash.
CruxIssueSessionContext buildSimcruxIssueSessionContext(Ref ref) {
  var openProjectCount = 0;
  var projectLoaded = false;
  String? schemaVersion;
  var suiteCount = 0;
  var testCount = 0;
  var configuredSimulators = <String>[];
  var binaryOverrideCount = 0;
  var runState = 'idle';
  var runTotal = 0;
  var runCompleted = 0;
  var runPassed = 0;
  var runFailed = 0;

  final builder = CruxIssueSessionContextBuilder();

  // Registered built-in driver ids — a fixed vocabulary, resolvable without a
  // loaded project, and the first thing a triager wants when a simulator is
  // "missing".
  var registeredDrivers = <String>[];
  // `guard` swallows what the block throws, which is the same degrade-rather-
  // than-fail contract the four hand-rolled versions of this function each
  // implemented with their own try/catch: the reporter exists to let a user
  // report a broken state, so it must open even when the state it wants to
  // describe is the broken thing. Registry unavailable in a bare scope.
  // Detected tool versions. Lazily probed: reading this starts the probe, and
  // the reporter dialog watches the session context, so the tiles and the
  // markdown preview refresh in place once it resolves. Probe unavailable when
  // there is no process seam in this scope.
  var versions = const <String, String>{};
  builder
    ..guard(() {
      registeredDrivers = ref
          .watch(simulatorDriverRegistryProvider)
          .simulatorIds
          .toList(growable: false);
    })
    ..guard(() {
      versions = ref.watch(simulatorVersionsProvider).value ?? const {};
    })
    // Bare test scope, or workspace not yet hydrated — report what we have.
    ..guard(() {
      final workspace = ref.watch(workspaceProvider).value;
      openProjectCount = workspace?.tabs.length ?? 0;
      final activeTabId = workspace?.activeTabId;
      if (activeTabId != null) {
        final managers = ref.watch(workspaceContainerManagersProvider);
        final container = managers.tabs.containerFor(activeTabId);

        final config = container.read(activeConfigProvider);
        if (config != null) {
          projectLoaded = true;
          schemaVersion = config.schemaVersion;
          suiteCount = config.suites.length;
          testCount = config.suites.fold<int>(
            0,
            (sum, suite) => sum + suite.tests.length,
          );
          configuredSimulators = <String>{
            for (final suite in config.suites)
              for (final test in suite.tests) test.simulatorId,
          }.toList()..sort();
          binaryOverrideCount = config.simulatorBinaries.length;
        }

        final run = container.read(regressionRunnerProvider).value;
        if (run != null) {
          runState = run.cancelled
              ? 'cancelled'
              : (run.isFinished ? 'finished' : 'running');
          runTotal = run.run.testIds.length;
          runCompleted = run.run.results.length;
          for (final result in run.run.results) {
            switch (result.status) {
              case TestStatus.pass:
              case TestStatus.cover:
                runPassed++;
              case TestStatus.fail:
              case TestStatus.timeout:
                runFailed++;
              case TestStatus.vacuous:
              case TestStatus.running:
              case TestStatus.skipped:
              case TestStatus.cancelled:
              case TestStatus.unknown:
                break;
            }
          }
        }
      }
    })
    // NOTE: these labels are deliberately English, not ARB-sourced. They are
    // markdown field labels inside the GitHub issue body, which the shared
    // package documents as un-localized: the body is read by maintainers in
    // the repository, and a mixed-language body makes triage harder. Only the
    // reporter's UI chrome is localized (see SimcruxIssueReporterStrings).
    //
    // The attribute keys below are the structured extras the Pro
    // overlay's `CruxIssueReporterDataProvider` reads for its "Pro State"
    // category. They now sit beside the field that produces them rather than
    // in a separate map at the bottom, which is what made the two drift apart
    // in the first place.
    ..addCount(
      'Open project tabs',
      openProjectCount,
      attributeKey: 'openProjectCount',
    )
    ..addText(
      'Active project',
      projectLoaded ? 'loaded' : null,
      fallback: CruxIssueFallback.noneLoaded,
    )
    ..attribute('projectLoaded', projectLoaded)
    // `(none)` here, not `(none loaded)`: an absent schema version is a field
    // the config did not carry, not an unloaded project.
    ..addText('Config schema version', schemaVersion)
    ..addCount('Suites', suiteCount, attributeKey: 'suiteCount')
    ..addCount('Tests', testCount, attributeKey: 'testCount')
    ..addList(
      'Configured simulators',
      configuredSimulators,
      attributeKey: 'configuredSimulators',
    )
    ..addCount('Simulator binary overrides', binaryOverrideCount)
    ..addList(
      'Registered drivers',
      registeredDrivers,
      attributeKey: 'registeredDrivers',
    )
    ..addText(
      'Detected versions',
      _renderVersions(versions),
      fallback: kIssueSessionNotProbed,
    )
    ..addText('Run state', runState, attributeKey: 'runState')
    ..addCount('Tests in run', runTotal, attributeKey: 'runTotal')
    ..addCount('Results recorded', runCompleted)
    ..addCount('Passed', runPassed, attributeKey: 'runPassed')
    ..addCount('Failed', runFailed, attributeKey: 'runFailed');

  return builder.build();
}

/// Renders the probed version banners, or null when nothing has resolved yet
/// (the builder substitutes [kIssueSessionNotProbed]).
///
/// Sorted by id so two reports of the same machine diff cleanly.
String? _renderVersions(Map<String, String> versions) {
  if (versions.isEmpty) return null;
  final ids = versions.keys.toList()..sort();
  return [
    for (final id in ids) '$id ${scrubVersionBanner(versions[id]!)}',
  ].join('; ');
}

/// Strips any path-shaped token out of a simulator's `--version` banner.
///
/// Version banners are third-party output, so SimCrux cannot assume their
/// shape. Most are innocuous (`Icarus Verilog version 12.0 (stable)`), but a
/// locally built toolchain can print its install prefix — and the user's
/// binary-override path is by definition a private path. Any whitespace-
/// delimited token containing a POSIX or Windows path separator, or a Windows
/// drive prefix, is replaced with [kIssueSessionRedacted]; a banner that is
/// *entirely* path-shaped collapses to that sentinel.
///
/// Exposed (not private) so the privacy regression test can drive it directly
/// with adversarial banners.
String scrubVersionBanner(String banner) {
  final tokens = banner.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
  final scrubbed = <String>[];
  for (final token in tokens) {
    final looksLikePath =
        token.contains('/') ||
        token.contains(r'\') ||
        RegExp('^[A-Za-z]:').hasMatch(token);
    scrubbed.add(looksLikePath ? kIssueSessionRedacted : token);
  }
  if (scrubbed.isEmpty) return kIssueSessionRedacted;
  return scrubbed.join(' ');
}
