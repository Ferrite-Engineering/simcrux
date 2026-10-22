// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/services/flow/flow_metric_keys.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_toolchain_probe.dart';
import 'package:simcrux/services/telemetry/flow_telemetry.dart';
import 'package:simcrux/services/telemetry/telemetry_event_catalog.dart';

/// The Flow telemetry: closed vocabularies that follow their enums, at most
/// six properties, and never a value, a name, a path or a step.
void main() {
  TelemetryCatalogEvent entry(String name) =>
      kSimcruxEventCatalog.firstWhere((e) => e.name == name);

  TestResult result(Map<String, String> metrics) => TestResult(
    testId: 'flow/secret_design_name',
    runId: 'r',
    status: metrics[FlowMetricKeys.verdict] == 'met'
        ? TestStatus.pass
        : TestStatus.fail,
    startedAt: DateTime.utc(2026),
    finishedAt: DateTime.utc(2026),
    metrics: metrics,
  );

  test('the outcome vocabulary is the FlowVerdict wire names', () {
    expect(
      kFlowOutcomeTokens.toSet(),
      FlowVerdict.values.map((v) => v.wireName).toSet(),
    );
  });

  test('the kind vocabulary is the FlowKind wire names', () {
    expect(
      kFlowKindTokens.toSet(),
      FlowKind.values.map((v) => v.wireName).toSet(),
    );
  });

  test('every probe tool token is a flow.tool.missing value', () {
    for (final tool in FlowTool.values) {
      expect(kFlowToolTokens, contains(tool.token), reason: tool.name);
    }
  });

  test('the four events are catalogued within the Worker cap', () {
    for (final name in const [
      'flow.run.completed',
      'flow.reader.unsupported',
      'flow.handoff.launched',
      'flow.tool.missing',
    ]) {
      expect(entry(name).propertyKeys.length, lessThanOrEqualTo(6));
    }
    expect(entry('flow.run.completed').propertyKeys.toSet(), <String>{
      'kind',
      'source',
      'outcome',
      'target',
      'reader',
      'steps',
    });
  });

  test('flow.run.completed carries only closed tokens and a clamped count', () {
    final properties = flowRunsCompletedProperties([
      result(<String, String>{
        FlowMetricKeys.kind: 'librelane',
        FlowMetricKeys.verdict: 'violated',
        FlowMetricKeys.target: 'sky130',
        FlowMetricKeys.readerVerified: 'false',
        FlowMetricKeys.steps: '78',
        FlowMetricKeys.runDir: '/home/someone/secret/runs/RUN_1',
        FlowMetricKeys.wnsPs: '-120',
        FlowMetricKeys.tag: 'RUN_1',
      }),
      result(const <String, String>{'unrelated': 'x'}),
    ]);
    expect(properties, [
      <String, Object?>{
        'kind': 'librelane',
        'source': 'run',
        'outcome': 'violated',
        'target': 'sky130',
        'reader': 'unverified',
        'steps': 78,
      },
    ]);
  });

  test('an unknown target folds to other', () {
    final p = flowRunCompletedProperties(<String, String>{
      FlowMetricKeys.kind: 'nextpnr',
      FlowMetricKeys.verdict: 'met',
      FlowMetricKeys.target: 'xc7a35t',
      FlowMetricKeys.readerVerified: 'true',
    }, source: 'ingest');
    expect(p!['target'], 'other');
    expect(p['source'], 'ingest');
    expect(p['reader'], 'verified');
  });

  test('flow.reader.unsupported is one per (kind, reason)', () {
    final metrics = <String, String>{
      FlowMetricKeys.kind: 'librelane',
      FlowMetricKeys.readerUnsupported: 'version_unknown',
    };
    expect(
      flowReaderUnsupportedProperties([result(metrics), result(metrics)]),
      [
        <String, Object?>{'kind': 'librelane', 'reason': 'version_unknown'},
      ],
    );
  });

  test('flow.tool.missing names closed tools only', () {
    expect(
      flowToolMissingTokens([
        result(<String, String>{FlowDriverMetricKeys.toolMissing: 'yosys'}),
        result(<String, String>{FlowDriverMetricKeys.toolMissing: '/opt/x'}),
      ]),
      {'yosys'},
    );
  });
}
