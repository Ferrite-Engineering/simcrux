// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live assertions for the gate-level and netlist-equivalence gates: re-measure
// with tool/flow/gate_level/regen_gate_level.py and check every recorded
// outcome in gate_level/gls.expected.json and formal/eqy_flow/
// recipe.expected.json against what the tools report now.
//
// Gated on the toolchain. OSS_CAD_SUITE points at an OSS CAD Suite install;
// the sky130 PDK is found through the runs' own resolved.json (rebased onto
// PDK_ROOT or ~/.ciel when the run came from another machine). The PicoRV32
// runs come from GATE_LEVEL_RUNS, laid out as the LibreLane regenerator's
// --work keeps them (g1/design/runs/g1, g1_cg/design/runs/g1_cg); without it
// only the committed small design and the MAC are measured. With
// FLOW_LIVE_REQUIRED=1 a missing tool or run fails instead of skipping.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 55))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _gl = 'verification/fixtures/flow/gate_level';
const _eqy = 'verification/fixtures/formal/eqy_flow';

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

String? _env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.isEmpty) ? null : v;
}

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

String? _blocker() {
  final suite = _env('OSS_CAD_SUITE');
  if (suite == null) return 'OSS_CAD_SUITE is unset';
  for (final tool in ['iverilog', 'vvp', 'verilator', 'yosys', 'eqy']) {
    if (!File('$suite/bin/$tool').existsSync()) {
      return '$tool missing in $suite';
    }
  }
  if (_required && _env('GATE_LEVEL_RUNS') == null) {
    return 'GATE_LEVEL_RUNS is unset';
  }
  return null;
}

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () {
      fail('FLOW_LIVE_REQUIRED=1 and $blocker');
    });
  }

  group('gate level live', () {
    late Map<String, dynamic> got;
    late Directory out;
    final runs = _env('GATE_LEVEL_RUNS');

    setUpAll(() {
      out = Directory.systemTemp.createTempSync('flow_gate_level_live_');
      final args = [
        '-I',
        'tool/flow/gate_level/regen_gate_level.py',
        '--suite',
        _env('OSS_CAD_SUITE')!,
        '--out',
        out.path,
        if (runs != null) ...[
          '--run',
          'picorv32=$runs/g1/design/runs/g1',
          '--run',
          'picorv32_cg=$runs/g1_cg/design/runs/g1_cg',
        ],
      ];
      final r = Process.runSync('python3', args);
      if (r.exitCode != 0) {
        fail('regenerator exited ${r.exitCode}\n${r.stdout}\n${r.stderr}');
      }
      got =
          _json('${out.path}/gate_level.json')['cases'] as Map<String, dynamic>;
    });

    tearDownAll(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    test('G8: every recorded gate-level outcome is unchanged', () {
      final want = _json('$_gl/gls.expected.json');
      final cases = want['cases'] as Map<String, dynamic>;
      for (final entry in cases.entries) {
        if (!got.containsKey(entry.key)) {
          if (runs == null && entry.key.startsWith('picorv32')) continue;
          fail('case ${entry.key} was not measured');
        }
        final diffs = glsDifferences(
          entry.value as Map<String, dynamic>,
          got[entry.key] as Map<String, dynamic>,
        );
        expect(diffs, isEmpty, reason: entry.key);
      }
    });

    test('G6: every recorded equivalence outcome is unchanged', () {
      final want = _json('$_eqy/recipe.expected.json');
      final cases = want['cases'] as Map<String, dynamic>;
      for (final entry in cases.entries) {
        if (!got.containsKey(entry.key)) {
          if (runs == null && entry.key.startsWith('picorv32')) continue;
          fail('case ${entry.key} was not measured');
        }
        final diffs = eqyDifferences(
          entry.value as Map<String, dynamic>,
          got[entry.key] as Map<String, dynamic>,
        );
        expect(diffs, isEmpty, reason: entry.key);
      }
    });
  }, skip: blocker);
}

/// The measured block an expectation key names: `split_ports` and the MAC's
/// `plain`/`xprobe` sit on the case, `mutant_<simulator>` under the mutant's
/// simulation, everything else under `gls`.
Object? _measured(Map<String, dynamic> got, String key) {
  if (key == 'split_ports') return got[key];
  if (key.startsWith('mutant_')) {
    final mutant = got['gls_mutant'] as Map<String, dynamic>?;
    return mutant?[key.substring('mutant_'.length)];
  }
  final gls = got['gls'] as Map<String, dynamic>?;
  return gls?[key] ?? got[key];
}

/// Compares one case's hand-written GLS outcome with a measurement.
List<String> glsDifferences(
  Map<String, dynamic> want,
  Map<String, dynamic> got,
) {
  final diffs = <String>[];
  void check(String what, Object? expected, Object? actual) {
    if (expected != actual) diffs.add('$what: want $expected, got $actual');
  }

  for (final key in want.keys) {
    final w = want[key] as Map<String, dynamic>;
    final source = _measured(got, key);
    if (source is! Map<String, dynamic>) {
      diffs.add('$key: not measured');
      continue;
    }
    if (key == 'split_ports') {
      check('$key compiles', w['compiles'], source['compiled']);
      continue;
    }
    if (key == 'icarus_pnl') {
      check(
        'pnl without USE_POWER_PINS compiles',
        w['without_define_compiles'],
        (source['without_USE_POWER_PINS'] as Map)['compiled'],
      );
      check(
        'pnl floating supply passes',
        w['floating_passes'],
        (source['floating'] as Map)['passed'],
      );
      final tied = source['tied'] as Map<String, dynamic>;
      check('pnl tied supply passes', w['tied_passes'], tied['passed']);
      check(
        'pnl tied real bits',
        w['tied_real_bits'],
        (tied['compare'] as Map?)?['real_bits'],
      );
      continue;
    }
    final rtl = source['rtl'] as Map<String, dynamic>;
    final gate = source['gate'] as Map<String, dynamic>;
    final cmp = source['compare'] as Map<String, dynamic>?;
    // A testbench without a verdict of its own (the MAC's) states none.
    if (w.containsKey('rtl_passes')) {
      check('$key rtl passes', w['rtl_passes'], rtl['passed'] ?? false);
    }
    if (w.containsKey('gate_passes')) {
      check('$key gate passes', w['gate_passes'], gate['passed'] ?? false);
    }
    if (rtl['compiled'] != true || gate['compiled'] != true) {
      diffs.add(
        '$key did not compile: ${rtl['compile_log'] ?? gate['compile_log']}',
      );
    }
    if (w.containsKey('real_bits')) {
      check('$key real bits', w['real_bits'], cmp?['real_bits']);
    }
    if (w['real_bits_above_zero'] == true) {
      final real = (cmp?['real_bits'] as int?) ?? 0;
      if (real == 0) diffs.add('$key real bits: want above zero, got 0');
    }
    if (w.containsKey('x_only')) {
      final x = (cmp?['x_asymmetry_bits'] as int?) ?? 0;
      final real = (cmp?['real_bits'] as int?) ?? -1;
      check('$key x-asymmetry only', w['x_only'], x > 0 && real == 0);
    }
    if (w.containsKey('parity_x_samples')) {
      final perPort = cmp?['per_port'] as Map<String, dynamic>?;
      check(
        '$key parity x-asymmetry samples',
        w['parity_x_samples'],
        (perPort?['parity'] as Map?)?['x_asymmetry'],
      );
    }
    if (w.containsKey('x_samples')) {
      check('$key x samples', w['x_samples'], cmp?['samples_with_x_asymmetry']);
    }
  }
  return diffs;
}

/// Compares one case's hand-written EQY outcome with a measurement.
List<String> eqyDifferences(
  Map<String, dynamic> want,
  Map<String, dynamic> got,
) {
  final diffs = <String>[];
  void check(String what, Object? expected, Object? actual) {
    if (expected != actual) diffs.add('$what: want $expected, got $actual');
  }

  final blackboxes = got['blackboxes'];
  check(
    'blackboxed cell types',
    jsonEncode(want['blackboxes']),
    jsonEncode(blackboxes),
  );
  for (final key in ['eqy', 'eqy_mutant']) {
    if (!want.containsKey(key)) continue;
    final w = want[key] as Map<String, dynamic>;
    final g = got[key] as Map<String, dynamic>?;
    if (g == null) {
      diffs.add('$key: not measured');
      continue;
    }
    check('$key overall', w['overall'], g['overall']);
    if (w.containsKey('not_passed')) {
      final notPassed = [
        for (final r in (g['not_passed'] as List).cast<Map<String, dynamic>>())
          '${r['partition']} ${r['status']}',
      ];
      check(
        '$key partitions not passed',
        jsonEncode(w['not_passed']),
        jsonEncode(notPassed),
      );
    }
    if (w.containsKey('not_passed_count')) {
      check(
        '$key partitions not passed',
        w['not_passed_count'],
        (g['not_passed'] as List).length,
      );
    }
    if (w.containsKey('partitions')) {
      check('$key partitions', w['partitions'], g['partitions']);
    }
    if (w['internal_error'] == true) {
      if ((g['internal_errors'] as List).isEmpty) {
        diffs.add('$key: want an EQY internal error, got none');
      }
    } else if ((g['internal_errors'] as List).isNotEmpty) {
      diffs.add('$key internal errors: ${g['internal_errors']}');
    }
  }
  return diffs;
}
