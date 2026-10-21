// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/shortcuts/menu_layout.dart';
import 'package:simcrux/core/shortcuts/simcrux_action.dart';
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/features/dashboard/models/dashboard_column_layout.dart';
import 'package:simcrux/features/dashboard/models/dashboard_sort.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

// The Formal open-core surfaces are each called by something the app runs.
// A class nothing reaches compiles, analyzes and keeps its own tests green;
// these pin the call sites: the importer from the CLI and the File menu, the
// probe from Settings, the Verdict column in the results table, the Pro
// seam from View > Formal Properties….

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: path);
  return file.readAsStringSync();
}

void main() {
  group('the .sby importer', () {
    test('import-sby is a sub-command word the parser dispatches', () {
      expect(CliArgParser.kSubcommands, contains('import-sby'));
      expect(
        FormalImportKind.fromSubcommand('import-sby'),
        FormalImportKind.sby,
      );
    });

    test('the headless binary and the desktop app both run it', () {
      expect(
        _read('lib/core/cli/simcrux_cli.dart'),
        contains('FormalImportCli('),
      );
      expect(
        _read('lib/app.dart'),
        contains('SimcruxCli.runFormalImport('),
      );
      expect(
        _read('lib/services/import/formal_import_cli.dart'),
        contains('.importJobs('),
      );
    });

    test('File > Import Formal Project… runs it', () {
      expect(
        kMenuLayout.values.expand((g) => g).expand((a) => a),
        contains(SimcruxAction.importFormalProject),
      );
      expect(
        _read('lib/core/shortcuts/simcrux_action_handlers.dart'),
        contains('runImportFormalProject('),
      );
      expect(
        _read('lib/features/formal_import/import_formal_project_flow.dart'),
        contains('.importJobs('),
      );
    });

    test('the riscv-formal importer is built on it', () {
      expect(
        _read('lib/services/import/riscv_formal_check_importer.dart'),
        contains('SbyProjectImporter.expandTasks('),
      );
    });
  });

  test('Settings > Engines > Formal tools runs the probe', () {
    expect(
      _read('lib/features/settings/widgets/settings_formal_tools_section.dart'),
      allOf(contains('FormalToolchainProbe('), contains('.probe(')),
    );
    expect(
      _read('lib/features/settings/widgets/settings_engines_section.dart'),
      contains('SettingsFormalToolsSection('),
    );
  });

  test('the shipped registry registers sby, so Formal tools is drawn', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(simulatorDriverRegistryProvider).simulatorIds,
      contains('sby'),
    );
  });

  test('the results table draws the Verdict column', () {
    expect(dashboardColumns.columns, contains(DashboardSortColumn.verdict));
    expect(
      _read('lib/features/dashboard/widgets/dashboard_results_table.dart'),
      allOf(
        contains('DashboardSortColumn.verdict'),
        contains('formalVerdictLabel('),
      ),
    );
  });

  test('View > Formal Properties… reads the Pro seam', () {
    expect(
      kMenuLayout.values.expand((g) => g).expand((a) => a),
      contains(SimcruxAction.openFormalProperties),
    );
    expect(
      _read('lib/core/shortcuts/simcrux_action_handlers.dart'),
      contains('formalPropertiesOpenerProvider'),
    );
  });

  test('the formal counters are recorded by both run paths', () {
    for (final path in const [
      'lib/features/dashboard/providers/regression_runner.dart',
      'lib/services/ci/ci_runner.dart',
    ]) {
      expect(
        _read(path),
        allOf(
          contains('formalRunCompletedProperties('),
          contains('formalAssertionsDisabledTokens('),
        ),
        reason: path,
      );
    }
  });
}
