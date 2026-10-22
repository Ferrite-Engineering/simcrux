// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/services/flow/gate_level/gls_outcome.dart';
import 'package:simcrux/services/flow/gate_level/gls_result.dart';

/// The note `--json` carries: what a functional gate-level result is.
const String kGlsFindingsNote =
    'Functional simulation with unit delays and no timing checks. '
    'The results are findings about behaviour.';

/// The JSON document `--json` prints for `simcrux flow gls`: each test's
/// outcome and both counts, the netlist and the delays, and the exit code.
///
/// Nothing in it is a verdict about timing: the functional simulation has
/// unit delays and no timing checks. Results are findings, not signoff.
Map<String, Object?> glsJson(
  List<GlsResultView> views, {
  required String runDir,
  required int exitCode,
  required String exitLabel,
  required String note,
}) => <String, Object?>{
  'schema': 'simcrux-flow-gls/1',
  'run_dir': runDir,
  'tests': <Object?>[
    for (final v in views)
      <String, Object?>{
        'test_id': v.testId,
        'rtl_test': ?v.rtlTest,
        'outcome': v.outcome.wireName,
        'reason': ?v.reason?.wireName,
        'real_diffs': v.realDiffs,
        'x_diffs': v.xDiffs,
        'first_diff_ps': v.firstDiffPs,
        'netlist': v.netlist,
        'delays': v.delays,
        'simulator': v.simulator,
        'strict_x': v.strictX,
        'passes': v.passes,
        if (v.bannered) 'pdk_not_measured': true,
      },
  ],
  'exit_code': exitCode,
  'exit_label': exitLabel,
  'note': note,
};

/// JUnit for `--junit`: one case per gate-level test, a failure for a test
/// that differs (or is X-only under strict x), a skip for one that did not
/// run, and the outcome and both counts as the case's properties.
String glsJunit(List<GlsResultView> views) {
  final cases = StringBuffer();
  var failures = 0;
  var skipped = 0;
  for (final v in views) {
    cases
      ..write(
        '    <testcase classname="simcrux.flow.gls" '
        'name="${_xml(v.testId)}">\n',
      )
      ..write('      <properties>\n')
      ..write(_property('outcome', v.outcome.wireName))
      ..write(_property('real_diffs', '${v.realDiffs ?? ''}'))
      ..write(_property('x_diffs', '${v.xDiffs ?? ''}'))
      ..write(_property('netlist', v.netlist))
      ..write(_property('delays', v.delays))
      ..write(_property('simulator', v.simulator))
      ..write('      </properties>\n');
    if (v.outcome == GlsOutcome.notRun) {
      skipped++;
      cases.write(
        '      <skipped message="${_xml('did not run: '
        '${v.reason?.wireName ?? 'unknown'}')}"/>\n',
      );
    } else if (!v.passes) {
      failures++;
      final message = v.outcome == GlsOutcome.xOnly
          ? 'x-asymmetry only (${v.xDiffs ?? 0}), and strict x is on'
          : 'differs: ${v.realDiffs ?? 0} real, ${v.xDiffs ?? 0} '
                'x-asymmetry';
      cases.write(
        '      <failure type="${v.outcome.wireName}" '
        'message="${_xml(message)}"/>\n',
      );
    }
    cases.write('    </testcase>\n');
  }
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<testsuites>\n'
      '  <testsuite name="simcrux-flow-gls" tests="${views.length}" '
      'failures="$failures" skipped="$skipped">\n'
      '$cases'
      '  </testsuite>\n'
      '</testsuites>\n';
}

String _property(String name, String value) =>
    '        <property name="$name" value="${_xml(value)}"/>\n';

String _xml(String text) => text
    .replaceAll(RegExp('[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
