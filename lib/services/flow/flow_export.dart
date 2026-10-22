// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:crux_flow/crux_flow.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/flow_gate.dart';
import 'package:simcrux/services/flow/flow_process_driver.dart';
import 'package:simcrux/services/flow/flow_run_reading.dart';
import 'package:simcrux/services/flow/flow_worst_paths.dart';

/// The formats `simcrux flow export` writes.
enum FlowExportFormat {
  /// The run as JSON.
  json,

  /// One JUnit test case per run.
  junit,

  /// SARIF 2.1.0: nextpnr timing findings with RTL locations, LibreLane
  /// check findings.
  sarif,

  /// A standalone HTML page.
  html;

  /// The format [name] names, or null.
  static FlowExportFormat? fromName(String name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

// vocabulary-guard: disclaimer begin
/// The line every exported result carries: results are findings, not
/// signoff. The one place the HTML template names the word, in the negative.
const String kFlowFindingsNote = 'Findings, not signoff.';
// vocabulary-guard: disclaimer end

/// The JSON summary of one run: what `--json` prints and `export --format
/// json` writes, the derivation of a nextpnr WNS named.
Map<String, Object?> flowRunJson(FlowReading reading) => <String, Object?>{
  'schema': 'simcrux-flow/1',
  'kind': reading.run.ref.kind.wireName,
  'verdict': reading.verdict.wireName,
  'run_dir': reading.run.ref.root,
  'tag': reading.run.ref.tag,
  'reader': reading.reader,
  'reader_verified': reading.run.ref.verified,
  'reader_version': reading.run.ref.readerVersion,
  'target': reading.target,
  'problem': ?reading.problem,
  'stopped_step': ?reading.stoppedStep,
  'reader_unsupported': ?reading.unsupported?.wireName,
  'wns_ns': ?reading.wnsNs,
  'wns_derivation': ?reading.wnsDerivation,
  'fmax_mhz': ?reading.fmaxMhz,
  'steps': <Object?>[for (final s in reading.run.steps) s.toJson()],
  'metrics': reading.run.metrics,
  'timing_paths': reading.run.timing.length,
  'note': kFlowFindingsNote,
};

/// The JSON document of a gate evaluation.
Map<String, Object?> flowGateJson(
  FlowReading reading,
  FlowGateOutcome outcome, {
  required int exitCode,
  required String exitLabel,
}) => <String, Object?>{
  ...flowRunJson(reading),
  'gate': <String, Object?>{
    'decision': outcome.decision.name,
    'exit_code': exitCode,
    'exit_label': exitLabel,
    'thresholds': <Object?>[
      for (final r in outcome.thresholds)
        <String, Object?>{
          'option': r.threshold.name,
          'metric': r.threshold.metric,
          'op': r.threshold.op.symbol,
          'limit': r.threshold.limit,
          'value': r.value,
          'result': r.missing ? 'missing' : (r.failed ? 'failed' : 'met'),
        },
    ],
    'baseline_worse': <Object?>[
      for (final c in outcome.baselineWorse)
        <String, Object?>{
          'metric': c.metricName,
          'baseline': c.formattedGold,
          'current': c.formattedCurrent,
        },
    ],
  },
};

/// A JUnit XML report: one test suite, one test case per reading, a
/// `failure` for every verdict but `met` and every failed threshold.
String flowJunit(
  List<FlowReading> readings, {
  FlowGateOutcome? outcome,
}) {
  final cases = StringBuffer();
  var failures = 0;
  var tests = 0;
  for (final reading in readings) {
    tests++;
    final name = _xml(
      '${reading.run.ref.kind.wireName}/${reading.run.ref.tag}',
    );
    cases.write('    <testcase classname="simcrux.flow" name="$name">\n');
    // Without a gate the verdict fails the case; with one, the case fails
    // only when the decision came from the verdict itself (no threshold or
    // baseline comparison failed or went missing).
    final verdictFails = outcome == null
        ? reading.verdict != FlowVerdict.met
        : outcome.decision != FlowGateDecision.met &&
              !outcome.thresholds.any((r) => r.failed || r.missing) &&
              outcome.baselineWorse.isEmpty;
    if (verdictFails) {
      failures++;
      final message = _xml(FlowProcessDriver.describeVerdict(reading));
      cases.write(
        '      <failure type="${reading.verdict.wireName}" '
        'message="$message"/>\n',
      );
    }
    cases.write('    </testcase>\n');
  }
  if (outcome != null) {
    for (final r in outcome.thresholds) {
      tests++;
      cases.write(
        '    <testcase classname="simcrux.flow.gate" '
        'name="${_xml(r.threshold.expression)}">\n',
      );
      if (r.failed || r.missing) {
        failures++;
        final message = r.missing
            ? 'the run has no ${r.threshold.metric}'
            : '${r.threshold.metric} is ${r.value}';
        cases.write(
          '      <failure type="${r.missing ? 'missing' : 'threshold'}" '
          'message="${_xml(message)}"/>\n',
        );
      }
      cases.write('    </testcase>\n');
    }
    for (final c in outcome.baselineWorse) {
      tests++;
      failures++;
      cases.write(
        '    <testcase classname="simcrux.flow.baseline" '
        'name="${_xml(c.metricName)}">\n'
        '      <failure type="baseline" message="${_xml('${c.formattedGold} '
        'to ${c.formattedCurrent}')}"/>\n'
        '    </testcase>\n',
      );
    }
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<testsuites>\n'
      '  <testsuite name="simcrux-flow" tests="$tests" '
      'failures="$failures">\n'
      '$cases'
      '  </testsuite>\n'
      '</testsuites>\n';
}

/// A SARIF 2.1.0 log for [reading]: the nextpnr writer's timing findings
/// for a nextpnr run; for a LibreLane run, one finding per check the run
/// fails, with [worstSetup] (its worst setup path, mapped) anchoring the
/// setup finding at the endpoint's source; an empty run log otherwise.
///
/// A LibreLane run's source root defaults to the design directory, the one
/// above `runs/`. Findings, not signoff.
String flowSarif(
  FlowReading reading, {
  String? sourceRoot,
  FlowPathRow? worstSetup,
}) {
  final report = reading.nextpnrReport;
  if (report != null) {
    return FlowSarifWriter.encode(
      FlowSarifWriter(sourceRoot: sourceRoot).nextpnr(report),
    );
  }
  final librelane = reading.librelane;
  if (librelane != null) {
    final root = sourceRoot ?? p.dirname(p.dirname(reading.run.ref.root));
    return FlowSarifWriter.encode(
      FlowSarifWriter(sourceRoot: root).librelane(
        librelane,
        worstSetupPath: worstSetup?.path,
        worstSetupMapping: worstSetup == null
            ? null
            : TimingPathMapping(
                startpoint: worstSetup.startpoint,
                endpoint: worstSetup.endpoint,
                segments: worstSetup.segments,
              ),
      ),
    );
  }
  return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
    r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
    'version': '2.1.0',
    'runs': <Object?>[
      <String, Object?>{
        'tool': <String, Object?>{
          'driver': <String, Object?>{'name': 'SimCrux Flow'},
        },
        'results': const <Object?>[],
      },
    ],
  });
}

/// [flowSarif] for [reading] with a LibreLane run's worst setup path read
/// and mapped first ([readFlowWorstPaths]), so its setup finding names the
/// registers and points at the source. Reads files; off the UI isolate.
Future<String> flowSarifWithPaths(
  FlowReading reading, {
  String? sourceRoot,
}) async {
  FlowPathRow? worst;
  if (reading.librelane != null && reading.run.timing.isNotEmpty) {
    final paths = await readFlowWorstPaths(reading.run.ref);
    worst = paths.rows.isEmpty ? null : paths.rows.first;
  }
  return flowSarif(reading, sourceRoot: sourceRoot, worstSetup: worst);
}

/// A standalone HTML page for [reading]: verdict, run facts and the metric
/// table, every value escaped.
String flowHtml(FlowReading reading) {
  final rows = StringBuffer();
  for (final MapEntry(:key, :value) in reading.run.metrics.entries) {
    rows.write('<tr><td>${_html(key)}</td><td>${_html('$value')}</td></tr>\n');
  }
  final steps = StringBuffer();
  for (final s in reading.run.steps) {
    steps.write(
      '<tr><td>${s.ordinal}</td><td>${_html(s.id)}</td>'
      '<td>${_html(s.status.wireName)}</td></tr>\n',
    );
  }
  final tag = _html(reading.run.ref.tag);
  return '<!DOCTYPE html>\n<html lang="en">\n<head>\n'
      '<meta charset="utf-8">\n<title>Flow run $tag</title>\n'
      '<style>body{font-family:sans-serif;margin:2em}'
      'table{border-collapse:collapse}td,th{border:1px solid #888; '
      'padding:2px 8px;text-align:left}</style>\n</head>\n<body>\n'
      '<h1>Flow run $tag</h1>\n'
      '<p>Verdict: <strong>${_html(reading.verdict.wireName)}</strong>. '
      '${_html(kFlowFindingsNote)}</p>\n'
      '<p>Kind: ${_html(reading.run.ref.kind.wireName)}. Reader: '
      '${_html(reading.reader)}'
      '${reading.run.ref.verified ? '' : ' (not verified for this version)'}'
      '.</p>\n'
      '${reading.problem == null ? '' : '<p>${_html(reading.problem!)}</p>\n'}'
      '<h2>Steps</h2>\n<table>\n<tr><th>#</th><th>Step</th><th>Status</th></tr>\n'
      '$steps</table>\n'
      '<h2>Metrics</h2>\n<table>\n<tr><th>Metric</th><th>Value</th></tr>\n'
      '$rows</table>\n</body>\n</html>\n';
}

String _xml(String text) => text
    .replaceAll(RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _html(String text) => _xml(text);
