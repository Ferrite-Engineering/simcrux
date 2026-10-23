// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Live assertions for the SDF gate: re-measure delay annotation in Icarus with
// tool/flow/gate_level/sdf_gate.py and check the outcomes recorded in
// gate_level/sdf/sdf_gate.expected.json. The tool is a measurement script that
// shares no code with SimCrux; the expectations restate the gate's rule
// (equal at the nominal period, different once it is shortened, a late capture
// silent) and the Icarus messages SDF-GATE.md records.
//
// Gated on the toolchain: OSS_CAD_SUITE, and the PDKs from ciel (PDK_ROOT or
// ~/.ciel). The PicoRV32 run comes from GATE_LEVEL_RUNS, laid out as the
// LibreLane regenerator's --work keeps it (g1/design/runs/g1), with its
// final/sdf/nom_tt_025C_1v80/; without it only the MAC and the committed adder
// runs are measured. With FLOW_LIVE_REQUIRED=1 a missing tool, PDK or run fails
// instead of skipping.
//
// Tagged `oss-cad-live`: the CI `Test` job runs `flutter test -x oss-cad-live`.

@Tags(['oss-cad-live'])
@Timeout(Duration(minutes: 55))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _gl = 'verification/fixtures/flow/gate_level';
const _runs = 'verification/fixtures/flow/librelane/3.0.16';
const _script = 'tool/flow/gate_level/sdf_gate.py';

bool get _required => Platform.environment['FLOW_LIVE_REQUIRED'] == '1';

String? _env(String name) {
  final v = Platform.environment[name];
  return (v == null || v.isEmpty) ? null : v;
}

Map<String, dynamic> _json(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

/// The versioned directory of [family] that holds [variant], or null.
String? _pdk(String family, String variant) {
  final home = Platform.environment['HOME'] ?? '';
  for (final base in <String>[?_env('PDK_ROOT'), p.join(home, '.ciel')]) {
    final versions = Directory(p.join(base, 'ciel', family, 'versions'));
    if (!versions.existsSync()) continue;
    for (final v in versions.listSync().whereType<Directory>()) {
      if (Directory(p.join(v.path, variant)).existsSync()) return v.path;
    }
  }
  return null;
}

String? _blocker() {
  final suite = _env('OSS_CAD_SUITE');
  if (suite == null) return 'OSS_CAD_SUITE is unset';
  for (final tool in ['iverilog', 'vvp']) {
    if (!File('$suite/bin/$tool').existsSync()) {
      return '$tool missing in $suite';
    }
  }
  if (_pdk('sky130', 'sky130A') == null) return 'no sky130A PDK from ciel';
  if (_required && _env('GATE_LEVEL_RUNS') == null) {
    return 'GATE_LEVEL_RUNS is unset';
  }
  return null;
}

Map<String, dynamic> _tool(List<String> args, String out, String file) {
  final r = Process.runSync('python3', <String>['-I', _script, ...args]);
  if (r.exitCode != 0) {
    fail('sdf_gate.py exited ${r.exitCode}\n${r.stdout}\n${r.stderr}');
  }
  return _json(p.join(out, file));
}

void main() {
  final blocker = _blocker();
  if (blocker != null && _required) {
    test('the live toolchain is installed', () {
      fail('FLOW_LIVE_REQUIRED=1 and $blocker');
    });
  }

  group('SDF gate live', () {
    late Directory out;
    late String suite;
    final expected = _json('$_gl/sdf/sdf_gate.expected.json');

    setUpAll(() {
      out = Directory.systemTemp.createTempSync('flow_sdf_gate_live_');
      suite = _env('OSS_CAD_SUITE')!;
    });
    tearDownAll(() {
      if (out.existsSync()) out.deleteSync(recursive: true);
    });

    test('the MAC with 0.5 ns on every path: equal at 20 ns, different at '
        '12 ns, every difference a known wrong value and no message', () {
      final mac = expected['mac'] as Map<String, dynamic>;
      final models = p.join(
        _pdk('sky130', 'sky130A')!,
        'sky130A',
        'libs.ref',
        'sky130_fd_sc_hd',
        'verilog',
      );
      final dir = p.join(out.path, 'mac');
      final got = _tool(
        <String>[
          'mac',
          '--suite',
          suite,
          '--pdk',
          models,
          '--out',
          dir,
          '--period',
          '20',
          '--period',
          '12',
        ],
        dir,
        'mac_sweep.json',
      );
      final rows = (got['periods'] as List).cast<Map<String, dynamic>>();
      expect(rows.first['samples_with_real_difference'], 0);
      expect(rows.last['samples_with_real_difference'], greaterThan(0));
      for (final row in rows) {
        final split = row['split'] as Map<String, dynamic>;
        expect(split['real_gate_x_bits'], mac['gate_x_where_rtl_known']);
        expect(row['timing_messages'], isEmpty);
      }
    });

    test('the committed adder runs annotate as recorded', () {
      final adders = expected['path_adder'] as Map<String, dynamic>;
      for (final MapEntry(:key, :value) in adders.entries) {
        final run = key.split('/').first;
        final corner = key.split('/').last;
        final family = switch (run) {
          'gf180mcuD_met' => ('gf180mcu', 'gf180mcuD'),
          'ihp-sg13g2_met' => ('ihp-sg13g2', 'ihp-sg13g2'),
          _ => ('sky130', 'sky130A'),
        };
        if (_pdk(family.$1, family.$2) == null) {
          if (_required) fail('no ${family.$2} PDK from ciel');
          continue;
        }
        final dir = p.join(out.path, run);
        final got = _tool(
          <String>[
            'annotate',
            '--suite',
            suite,
            '--run',
            '$_runs/$run/run',
            '--corner',
            corner,
            '--out',
            dir,
          ],
          dir,
          'annotate_$corner.json',
        );
        final messages =
            (got['annotation'] as Map<String, dynamic>)['messages']
                as Map<String, dynamic>;
        int count(String text) => messages.entries
            .where((e) => e.key.contains(text))
            .fold(0, (n, e) => n + (e.value as int));
        final want = value as Map<String, dynamic>;
        switch (want['coverage']) {
          case 'full':
            expect(count('ModPath'), 0, reason: key);
            expect(count('intermodpath'), 0, reason: key);
          case 'partial':
            expect(count('ModPath'), want['iopath_unmatched'], reason: key);
          case 'failed':
            final other =
                (got['annotation'] as Map<String, dynamic>)['other_lines']
                    as List;
            expect(count('malformed COND'), 1, reason: key);
            expect(
              other.any((l) => '$l'.contains('Too many errors')),
              isTrue,
              reason: key,
            );
        }
      }
    });

    test(
      'PicoRV32: equal to RTL at the nominal 25 ns, different at 6 ns, a '
      'silent wrong capture first; with inputs at the clock edge it differs '
      'at 25 ns too',
      () {
        final runs = _env('GATE_LEVEL_RUNS')!;
        final run = '$runs/g1/design/runs/g1';
        const rtl =
            'verification/fixtures/flow/librelane/designs/picorv32/picorv32.v';
        final want = expected['picorv32'] as Map<String, dynamic>;
        final dir = p.join(out.path, 'picorv32');
        final got = _tool(
          <String>[
            'sweep',
            '--suite',
            suite,
            '--run',
            run,
            '--rtl',
            rtl,
            '--out',
            dir,
            '--period',
            '25',
            '--period',
            '6',
          ],
          dir,
          'sweep.json',
        );
        final annotation = got['annotation'] as Map<String, dynamic>;
        final messages = annotation['messages'] as Map<String, dynamic>;
        expect(
          messages.keys.where((k) => k.contains('ModPath')),
          isEmpty,
          reason: 'every IOPATH annotates',
        );
        final interconnect =
            (want['annotation'] as Map)['interconnect_not_found'];
        expect(
          messages.entries
              .where((e) => e.key.contains('intermodpath'))
              .fold<int>(0, (n, e) => n + (e.value as int)),
          interconnect,
        );
        final rows = (got['periods'] as List).cast<Map<String, dynamic>>();
        final nominal = rows.first;
        expect((nominal['gate'] as Map)['testbench'], 'passed');
        expect(
          (nominal['comparison'] as Map)['samples_with_real_difference'],
          0,
        );
        final short = rows.last;
        expect((short['gate'] as Map)['testbench'], 'failed');
        final split = short['split'] as Map<String, dynamic>;
        final firstKnown = split['first_both_known'] as Map<String, dynamic>?;
        final firstX = split['first_gate_x'] as Map<String, dynamic>?;
        expect(firstKnown, isNotNull);
        if (firstX != null) {
          expect(
            firstKnown!['sample'] as int,
            lessThan(firstX['sample'] as int),
            reason: 'the first difference is a known wrong value, not an X',
          );
        }
        expect(short['timing_messages'], isEmpty);

        final edgeDir = p.join(out.path, 'picorv32_edge');
        final edge = _tool(
          <String>[
            'sweep',
            '--suite',
            suite,
            '--run',
            run,
            '--rtl',
            rtl,
            '--out',
            edgeDir,
            '--period',
            '25',
            '--at-edge',
          ],
          edgeDir,
          'sweep.json',
        );
        final atEdge = (edge['periods'] as List).single as Map<String, dynamic>;
        expect(
          (atEdge['comparison'] as Map)['samples_with_real_difference'],
          greaterThan(0),
        );
      },
      skip: _env('GATE_LEVEL_RUNS') == null
          ? 'GATE_LEVEL_RUNS is unset'
          : false,
    );
  }, skip: blocker);
}
