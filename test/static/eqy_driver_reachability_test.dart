// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';

// A driver, importer or sub-command registered nowhere compiles, analyzes
// and keeps its own tests green. These pin every place the app reaches the
// eqy pieces: both driver registries, the CLI dispatch of `import-eqy`, the
// GUI import's use of the EQY importer, and the inspector's partition list.

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('the desktop registry resolves `eqy` to EqyDriver', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(simulatorDriverRegistryProvider).driverFor(EqyDriver.kId),
      isA<EqyDriver>(),
    );
  });

  test('the headless CLI registry resolves `eqy` to EqyDriver', () {
    expect(
      SimcruxCli.defaultDriverRegistry().driverFor(EqyDriver.kId),
      isA<EqyDriver>(),
    );
  });

  test('import-eqy is a sub-command word the parser dispatches', () {
    expect(CliArgParser.kSubcommands, contains('import-eqy'));
    expect(FormalImportKind.fromSubcommand('import-eqy'), FormalImportKind.eqy);
  });

  test('the CLI and File > Import Formal Project use the EQY importer', () {
    expect(
      _read('lib/services/import/formal_import_cli.dart'),
      contains('_eqyImporter.importFile('),
    );
    expect(
      _read('lib/features/formal_import/import_formal_project_flow.dart'),
      contains('eqy.importFile('),
    );
    expect(
      _read('lib/features/formal_import/import_formal_project_flow.dart'),
      contains("'eqy'"),
    );
  });

  test("the inspector lists an eqy row's partitions", () {
    expect(
      _read('lib/features/inspector/widgets/inspector_formal_notes.dart'),
      contains('FormalResultSummary.partitionsOf('),
    );
  });

  test('the driver reads the work directory off the calling isolate', () {
    expect(
      _read('lib/services/simulator/eqy_driver.dart'),
      contains('Isolate.run('),
    );
  });
}
