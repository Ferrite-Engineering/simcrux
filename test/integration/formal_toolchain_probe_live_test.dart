// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@Tags(['integration', 'oss-cad-live'])
library;

// The formal toolchain probe and the `.sby` importer against a real OSS CAD
// Suite.
//
// The probe: pointed at the suite's sby, it must find every tool the suite
// ships, from beside that sby, and report a Yosys without Verific (the OSS
// CAD Suite is the open-source build; Verific is only in Tabby CAD).
//
// The importer: every corpus job file is imported, the emitted project file
// is loaded with the real loader, and every test it declares is run by the
// real driver, which must reach the case's hand-written verdict for that
// task. That is the whole open-core path from a job file to a verdict.
//
// Needs an OSS CAD Suite build: set OSS_CAD_SUITE to the directory holding
// its bin/, or put that bin/ on PATH. Without one every test is skipped,
// unless FORMAL_LIVE_REQUIRED=1 (the engine canary), which turns a missing
// tool into a failure. Tagged `oss-cad-live`, which the CI `Test` job
// excludes; the engine canary runs it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/formal_toolchain_report.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/formal/formal_toolchain_probe.dart';
import 'package:simcrux/services/import/sby_project_importer.dart';
import 'package:simcrux/services/simulator/sby_driver.dart';

import '../support/formal_fixture_checks.dart';

bool get _required => Platform.environment['FORMAL_LIVE_REQUIRED'] == '1';

final String? _sby = () {
  final suite = Platform.environment['OSS_CAD_SUITE'];
  if (suite != null && suite.isNotEmpty) {
    final sby = p.join(suite, 'bin', 'sby');
    return File(sby).existsSync() ? sby : null;
  }
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', [
    'sby',
  ]);
  if (which.exitCode != 0) return null;
  final first = (which.stdout as String).split('\n').first.trim();
  return first.isEmpty ? null : first;
}();

/// The sby to use, or null after skipping (or failing under
/// FORMAL_LIVE_REQUIRED=1).
String? _sbyOrSkip() {
  final sby = _sby;
  if (sby != null) return sby;
  const reason = 'sby not found; set OSS_CAD_SUITE or put it on PATH';
  if (_required) fail('FORMAL_LIVE_REQUIRED=1 and $reason');
  markTestSkipped(reason);
  return null;
}

void main() {
  test('the probe finds every tool an OSS CAD Suite ships, beside its sby, '
      'and no Verific', () async {
    final sby = _sbyOrSkip();
    if (sby == null) return;
    final report = await FormalToolchainProbe().probe(sbyPath: sby);
    final bin = p.dirname(sby);
    for (final row in report.tools) {
      expect(row.found, isTrue, reason: '${row.tool.binaryName} not found');
      if (row.tool != FormalTool.yosysSlang) {
        expect(p.dirname(row.binary), bin, reason: row.tool.binaryName);
      }
    }
    expect(report[FormalTool.sby]!.version, startsWith('SBY '));
    expect(report[FormalTool.eqy]!.version, startsWith('EQY '));
    expect(report[FormalTool.yosys]!.version, startsWith('Yosys '));
    expect(report[FormalTool.yosys]!.verific, isFalse);
    expect(report.ready, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('sby_import_live_'));
  tearDown(() => root.deleteSync(recursive: true));

  for (final name in kFormalSbyCases) {
    test('$name: imported, loaded and run, every task reaches its '
        'expectation', () async {
      final sby = _sbyOrSkip();
      if (sby == null) return;
      final caseDir = p.absolute(kFormalFixtureRoot, 'sby', name);
      final expected = readJsonObject(p.join(caseDir, '$name.expected.json'));
      final project = Directory(p.join(root.path, name))..createSync();
      for (final f in Directory(caseDir).listSync().whereType<File>()) {
        if (f.path.endsWith('.sby') ||
            f.path.endsWith('.sv') ||
            f.path.endsWith('.v')) {
          f.copySync(p.join(project.path, p.basename(f.path)));
        }
      }
      final imported = SbyProjectImporter().importJobs(
        path: p.join(project.path, '$name.sby'),
        outputDirectory: project.path,
        sbyBinary: sby,
      );
      final yaml = File(p.join(project.path, 'simcrux.yaml'))
        ..writeAsStringSync(imported.simcruxYaml);
      final config = await ConfigLoader(
        allowProjectDefinedTooling: true,
      ).load(yaml.path);
      final tests = [for (final s in config.suites) ...s.tests];
      final tasks = expected['tasks']! as Map<String, Object?>;
      expect(tests.map((t) => t.formal?.task).toSet(), tasks.keys.toSet());

      final problems = <String>[];
      for (final spec in tests) {
        final task = spec.formal!.task!;
        final want = (tasks[task]! as Map<String, Object?>)['verdict'];
        final work = Directory(p.join(root.path, 'work', name, task))
          ..createSync(recursive: true);
        final finished =
            (await SbyDriver()
                    .execute(
                      ExecuteRequest(
                        test: spec,
                        workingDirectory: work.path,
                        compileResult: null,
                        binaryConfig: const SimulatorBinaryConfig(
                          simulatorId: SbyDriver.kId,
                        ),
                      ),
                    )
                    .toList())
                .whereType<TestExecutionFinished>()
                .single;
        final got = finished.metrics[SbyDriver.kMetricVerdict];
        if (got != want) problems.add('$task: $got, expected $want');
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
