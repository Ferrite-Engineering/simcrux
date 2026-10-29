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

import 'flow_gate_level_facts.dart';

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

    // Every case is compared before anything fails, so one drifted case does
    // not hide the others' outcomes from the same run.
    test('G8: every recorded gate-level outcome is unchanged', () {
      final want = _json('$_gl/gls.expected.json');
      final cases = want['cases'] as Map<String, dynamic>;
      final diffs = <String>[];
      for (final entry in cases.entries) {
        if (!got.containsKey(entry.key)) {
          if (runs == null && entry.key.startsWith('picorv32')) continue;
          diffs.add('${entry.key}: not measured');
          continue;
        }
        diffs.addAll(
          glsDifferences(
            entry.value as Map<String, dynamic>,
            got[entry.key] as Map<String, dynamic>,
            live: true,
          ).map((d) => '${entry.key}: $d'),
        );
      }
      expect(diffs, isEmpty);
    });

    test('G6: every recorded equivalence outcome is unchanged', () {
      final want = _json('$_eqy/recipe.expected.json');
      final cases = want['cases'] as Map<String, dynamic>;
      final diffs = <String>[];
      for (final entry in cases.entries) {
        if (!got.containsKey(entry.key)) {
          if (runs == null && entry.key.startsWith('picorv32')) continue;
          diffs.add('${entry.key}: not measured');
          continue;
        }
        diffs.addAll(
          eqyDifferences(
            entry.value as Map<String, dynamic>,
            got[entry.key] as Map<String, dynamic>,
            live: true,
          ).map((d) => '${entry.key}: $d'),
        );
      }
      expect(diffs, isEmpty);
    });
  }, skip: blocker);
}
