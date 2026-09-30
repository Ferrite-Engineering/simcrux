// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Builds the structured-plain-text "Tab Diagnostics Report" the
/// drawer's Copy button drops onto the clipboard.
///
/// The exact text is stable enough to paste into a GitHub issue.
String buildTabDiagnosticsReport(WidgetRef ref) {
  final config = ref.read(activeConfigProvider);
  final runState = ref
      .read(regressionRunnerProvider)
      .maybeWhen(
        data: (s) => s,
        orElse: () => null,
      );
  final driverRegistry = ref.read(simulatorDriverRegistryProvider);
  final buffer = StringBuffer()
    ..writeln('SimCrux — Tab Diagnostics Report')
    ..writeln('--------------------------------');
  if (config == null) {
    buffer.writeln('No config loaded.');
  } else {
    buffer
      ..writeln('Config: ${config.projectFilePath}')
      ..writeln('Schema version: ${config.schemaVersion}')
      ..writeln('Suites: ${config.suites.length}')
      ..writeln(
        'Tests: ${config.suites.fold<int>(0, (sum, s) => sum + s.tests.length)}',
      );
  }
  buffer
    ..writeln()
    ..writeln('Simulator backend:');
  for (final id in driverRegistry.simulatorIds) {
    buffer.writeln('  - $id');
  }
  if (runState != null) {
    buffer
      ..writeln()
      ..writeln('Scheduler state:')
      ..writeln('  Run id: ${runState.run.id}')
      ..writeln('  Started: ${runState.run.startedAt.toIso8601String()}')
      ..writeln('  Total tests: ${runState.run.testIds.length}')
      ..writeln('  Completed: ${runState.run.results.length}')
      ..writeln('  Finished: ${runState.isFinished}');
  }
  return buffer.toString();
}
