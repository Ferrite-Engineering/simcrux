// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:crux_license/crux_license_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/flow_cli.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_run_ingestor.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';

/// Flow is never gated. At Open Core with the beta period over and no Pro
/// overrides, a project's flow entries load, a run's verdict, metrics and
/// run directory come through ingest and the CLI, and `flow gate` decides.
/// Nothing on these paths consults a licence.
void main() {
  const fixtures = 'verification/fixtures/flow/nextpnr';
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('flow_ungated_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('flow entries load at Open Core with kBetaPeriod false', () async {
    final project = File(p.join(tmp.path, 'simcrux.yaml'))
      ..writeAsStringSync('''
version: "1"
flow:
  entries:
    - name: adder
      kind: nextpnr
      family: ice40
      device: up5k
      package: sg48
      top: path_adder
      sources: [path_adder.v]
''');
    // The loader's defaults are the case under test: Open Core, and the
    // build's beta flag, which is off.
    expect(kBetaPeriod, isFalse);
    final config = await ConfigLoader().load(project.path);
    expect(config.suites.single.tests.single.simulatorId, 'nextpnr');
    expect(config.loadWarnings, isEmpty);
  });

  test('verdict, metrics and run directory render at Open Core', () async {
    final run = Directory(p.join(tmp.path, 'runs', 'adder', 't'))
      ..createSync(recursive: true);
    File(
      '$fixtures/path_ice40_violated/report.json',
    ).copySync(p.join(run.path, 'report.json'));

    final items = await const FlowRunIngestor().ingest(
      <String>[run.path],
      allowedRoots: <String>[tmp.path],
    );
    final result = FlowRunIngestor.resultFor(
      items.single.reading!,
      now: DateTime.utc(2026, 10, 21),
    );
    expect(result.status, TestStatus.fail);
    expect(result.metrics[FlowMetricKeys.verdict], 'violated');
    expect(result.metrics[FlowMetricKeys.wnsPs], isNotNull);
    expect(result.metrics[FlowMetricKeys.fmaxMhz], isNotNull);
    expect(
      result.metrics[FlowMetricKeys.runDir],
      run.resolveSymbolicLinksSync(),
    );

    final out = <String>[];
    final code = await FlowCli(
      stdoutSink: out.add,
      stderrSink: out.add,
      driverRegistry: SimulatorDriverRegistry(const {}),
    ).run(<String>['gate', run.path, '--json']);
    expect(code, 1);
    final json = jsonDecode(out.join('\n')) as Map<String, dynamic>;
    expect(json['verdict'], 'violated');
    expect(json['run_dir'], run.resolveSymbolicLinksSync());
    expect((json['metrics'] as Map)['timing__setup__wns'], isNotNull);
  });

  test('no Flow file reads the licence tier or the beta flag', () {
    final files = <File>[
      ...Directory('lib/services/flow')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')),
      File('lib/core/cli/flow_cli.dart'),
    ];
    for (final file in files) {
      final text = file.readAsStringSync();
      expect(text, isNot(contains('licenseTier')), reason: file.path);
      expect(text, isNot(contains('kBetaPeriod')), reason: file.path);
      expect(text, isNot(contains('FeatureGate')), reason: file.path);
    }
  });
}
