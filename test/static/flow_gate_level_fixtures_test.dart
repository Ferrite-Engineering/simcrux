// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The committed gate-level and netlist-equivalence fixtures: present, small,
// scrubbed, documented, and consistent with their hand-written outcomes.
//
// A missing fixture directory fails here; it is never skipped. The VCD checks
// below read the committed port dumps with a sampler written for this test
// (value held just before each rising clock edge), not with the product's
// reader, and compare them with what the testbench and the RTL mean:
//
// * the MAC resets asynchronously but starts with rst_n already low, so its
//   RTL outputs are x until the first clock edge while the gate-level reset
//   flops are already 0: one sample of x-asymmetry and nothing else;
// * with XPROBE the testbench drives a = x for three cycles with b = 0. The
//   RTL product x*0 is x and the accumulator keeps it, so parity stays x for
//   the rest of the run while the gates compute 0: x-asymmetry only, on 199
//   samples, never a known value that differs.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'flow_gate_level_facts.dart';

const _gl = 'verification/fixtures/flow/gate_level';
const _eqy = 'verification/fixtures/formal/eqy_flow';
const _smallRun = 'verification/fixtures/flow/librelane/3.0.16/sky130A_met/run';

const int _maxFixtureBytes = 5 * 1024 * 1024;

final RegExp _machinePath = RegExp(
  '/Users/|/home/|/private/|/var/folders|/runner/',
);

File _file(String path) {
  final file = File(path);
  if (!file.existsSync()) fail('missing fixture file: $path');
  return file;
}

Directory _dir(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) fail('missing fixture directory: $path');
  return dir;
}

Map<String, dynamic> _json(String path) =>
    jsonDecode(_file(path).readAsStringSync()) as Map<String, dynamic>;

/// Values of the variables in [scope], sampled before each rising edge of
/// [clock]: one map per edge, name to bit string (MSB first).
List<Map<String, String>> _samples(
  String path, {
  String scope = 'tb.uut',
  String clock = 'clk',
}) {
  final ids = <String, (String, int)>{};
  final stack = <String>[];
  final state = <String, String>{};
  final pending = <String, String>{};
  final out = <Map<String, String>>[];
  String? clockId;
  var header = true;

  void flush() {
    if (clockId != null && pending.containsKey(clockId)) {
      if (state[clockId] == '0' && pending[clockId] == '1') {
        out.add({
          for (final e in ids.entries)
            e.value.$1: state[e.key] ?? 'x' * e.value.$2,
        });
      }
    }
    state.addAll(pending);
    pending.clear();
  }

  for (final raw in _file(path).readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (header) {
      final parts = line.split(RegExp(r'\s+'));
      if (line.startsWith(r'$scope')) {
        stack.add(parts[2]);
      } else if (line.startsWith(r'$upscope')) {
        stack.removeLast();
      } else if (line.startsWith(r'$var') && stack.join('.') == scope) {
        ids.putIfAbsent(parts[3], () => (parts[4], int.parse(parts[2])));
        if (parts[4] == clock) clockId = parts[3];
      } else if (line.startsWith(r'$enddefinitions')) {
        header = false;
      }
      continue;
    }
    final head = line[0];
    if (head == '#') {
      flush();
    } else if (head == 'b' || head == 'B') {
      final parts = line.substring(1).split(RegExp(r'\s+'));
      final id = parts[1];
      final width = ids[id]?.$2;
      if (width == null) continue;
      var value = parts[0].toLowerCase();
      if (value.length < width) {
        final pad = (value[0] == 'x' || value[0] == 'z') ? value[0] : '0';
        value = pad * (width - value.length) + value;
      }
      pending[id] = value;
    } else if ('01xzXZ'.contains(head) && ids.containsKey(line.substring(1))) {
      pending[line.substring(1)] = head.toLowerCase();
    }
  }
  flush();
  return out;
}

/// Bit-level classification of an RTL/gate pair: (x-asymmetry samples,
/// real-difference samples, x-asymmetry samples per port).
(int, int, Map<String, int>) _classify(String rtl, String gate) {
  final r = _samples(rtl);
  final g = _samples(gate);
  expect(r.length, g.length, reason: 'same number of clock edges');
  var xSamples = 0;
  var realSamples = 0;
  final perPort = <String, int>{};
  for (var k = 0; k < r.length; k++) {
    var x = false;
    var real = false;
    for (final name in r[k].keys) {
      final a = r[k][name]!;
      final b = g[k][name] ?? '';
      if (a == b) continue;
      var portX = false;
      for (var i = 0; i < a.length && i < b.length; i++) {
        final ak = a[i] == '0' || a[i] == '1';
        final bk = b[i] == '0' || b[i] == '1';
        if (a[i] == b[i] || (!ak && !bk)) continue;
        if (!ak) {
          x = true;
          portX = true;
        } else {
          real = true;
        }
      }
      if (portX) perPort[name] = (perPort[name] ?? 0) + 1;
    }
    if (x) xSamples++;
    if (real) realSamples++;
  }
  return (xSamples, realSamples, perPort);
}

void main() {
  test('every gate-level fixture is present', () {
    [
      '$_gl/PROVENANCE.md',
      '$_gl/GLS-GATE.md',
      '$_gl/gls.expected.json',
      '$_gl/harness/gls_bind.v',
      '$_gl/harness/gls_power.v',
      '$_gl/path_adder/tb_path_adder.v',
      '$_gl/path_adder/gls_portdump.v',
      '$_gl/picorv32/tb_picorv32.v',
      '$_gl/picorv32/gls_portdump.v',
      '$_gl/mac/dut.v',
      '$_gl/mac/tb.v',
      '$_gl/mac/net.v',
      '$_gl/mac/net_splitports.v',
      '$_gl/mac/gls_portdump.v',
      '$_gl/mac/vcd/rtl.vcd',
      '$_gl/mac/vcd/gate.vcd',
      '$_gl/mac/vcd/rtl_x.vcd',
      '$_gl/mac/vcd/gate_x.vcd',
      '$_gl/mac/vcd/verilator_rtl.vcd',
      '$_gl/mac/vcd/verilator_gate.vcd',
      '$_eqy/RECIPE-GATE.md',
      '$_eqy/recipe.expected.json',
      '$_eqy/flow_netlist.eqy.in',
      '$_smallRun/final/nl/path_adder.nl.v',
      '$_smallRun/final/pnl/path_adder.pnl.v',
      '$_smallRun/final/sdf/nom_tt_025C_1v80/path_adder__nom_tt_025C_1v80.sdf',
      '$_smallRun/resolved.json',
      'tool/flow/gate_level/regen_gate_level.py',
      'tool/flow/gate_level/gls_compare.py',
      'tool/flow/gate_level/eqy_summary.py',
      'tool/flow/gate_level/netlist_mutant.py',
      '$_gl/SDF-GATE.md',
      '$_gl/sdf/sdf_gate.expected.json',
      '$_gl/sdf/mac_0p5ns.sdf',
      '$_gl/sdf/picorv32_sweep.json',
      '$_gl/sdf/mac_sweep.json',
      '$_gl/sdf/icarus/picorv32_nom_tt_025C_1v80.log',
      '$_gl/sdf/icarus/path_adder_sky130A_nom_tt_025C_1v80.log',
      '$_gl/sdf/icarus/path_adder_gf180mcuD_nom_tt_025C_5v00.log',
      '$_gl/sdf/icarus/path_adder_ihp-sg13g2_nom_typ_1p20V_25C.log',
      'tool/flow/gate_level/sdf_gate.py',
      'tool/flow/gate_level/gen_sdf.py',
    ].forEach(_file);
  });

  group('the SDF gate', () {
    final expected = _json('$_gl/sdf/sdf_gate.expected.json');

    int count(String log, String message) => _file(
      '$_gl/sdf/icarus/$log',
    ).readAsLinesSync().where((l) => l.contains(message)).length;

    test('PicoRV32: no IOPATH unmatched, the INTERCONNECTs not found are the '
        'recorded ones, one TIMINGCHECK warning per flip-flop', () {
      final annotation =
          (expected['picorv32'] as Map<String, dynamic>)['annotation']
              as Map<String, dynamic>;
      const log = 'picorv32_nom_tt_025C_1v80.log';
      expect(count(log, 'Unable to match ModPath'), 0);
      expect(
        count(log, 'Could not find intermodpath'),
        annotation['interconnect_not_found'],
      );
      expect(
        count(log, 'TIMINGCHECK not supported'),
        annotation['timingcheck_warnings'],
      );
      expect(count(log, 'Too many errors'), 0);
    });

    test('the adders: sky130 full, gf180 partial with the unmatched paths, '
        'IHP failed on a COND Icarus cannot parse', () {
      expect(
        count('path_adder_sky130A_nom_tt_025C_1v80.log', 'SDF ERROR'),
        2,
        reason: 'the VOLTAGE and TEMPERATURE header triples only',
      );
      expect(
        count('path_adder_gf180mcuD_nom_tt_025C_5v00.log', 'Unable to match'),
        192,
      );
      const ihp = 'path_adder_ihp-sg13g2_nom_typ_1p20V_25C.log';
      expect(count(ihp, 'Invalid/malformed COND'), 1);
      expect(count(ihp, 'Too many errors: syntax error'), greaterThan(0));
      final adders = expected['path_adder'] as Map<String, dynamic>;
      expect(
        (adders['ihp-sg13g2_met/nom_typ_1p20V_25C'] as Map)['coverage'],
        'failed',
      );
    });

    test('the sweep records agree with the recorded outcomes, period by '
        'period, and no timing message appears in either', () {
      final want = expected['picorv32'] as Map<String, dynamic>;
      final record = _json('$_gl/sdf/picorv32_sweep.json');
      for (final row
          in (record['periods'] as List).cast<Map<String, dynamic>>()) {
        final period = (row['period_ns'] as num).toInt();
        final real =
            (row['comparison']
                    as Map<String, dynamic>)['samples_with_real_difference']
                as int;
        if ((want['equal_at_ns'] as List).contains(period)) {
          expect(real, 0, reason: '$period ns');
          expect((row['gate'] as Map)['testbench'], 'passed');
        }
        if ((want['differs_at_ns'] as List).contains(period)) {
          expect(real, greaterThan(0), reason: '$period ns');
        }
        expect(row['timing_messages'], isEmpty, reason: '$period ns');
      }
      final mac = expected['mac'] as Map<String, dynamic>;
      final macRecord = _json('$_gl/sdf/mac_sweep.json');
      for (final row
          in (macRecord['periods'] as List).cast<Map<String, dynamic>>()) {
        final period = (row['period_ns'] as num).toInt();
        final real = row['samples_with_real_difference'] as int;
        if ((mac['equal_at_ns'] as List).contains(period)) {
          expect(real, 0, reason: 'MAC $period ns');
        }
        if ((mac['differs_at_ns'] as List).contains(period)) {
          expect(real, greaterThan(0), reason: 'MAC $period ns');
        }
        expect(
          (row['split'] as Map)['real_gate_x_bits'],
          mac['gate_x_where_rtl_known'],
        );
      }
    });

    // The facts `differs_by_platform` names are left out of the live rerun,
    // which measures the netlist the Linux tool build wrote; the committed
    // darwin capture holds them exactly.
    test('the darwin sweep record holds the platform-dependent facts', () {
      final want = expected['picorv32'] as Map<String, dynamic>;
      final differs = want['differs_by_platform'] as Map<String, dynamic>;
      expect(differs['why'], isA<String>());
      expect((differs['why'] as String).length, greaterThan(40));
      for (final fact in differs['facts'] as List) {
        expect(want, contains(fact), reason: 'names a recorded fact');
      }
      final rows = (_json('$_gl/sdf/picorv32_sweep.json')['periods'] as List)
          .cast<Map<String, dynamic>>();
      final failing = [
        for (final r in rows)
          if ((r['gate'] as Map)['testbench'] == 'failed')
            (r['period_ns'] as num).toInt(),
      ];
      expect(
        failing.reduce((a, b) => a > b ? a : b),
        want['first_failing_testbench_ns'],
      );
      final six = rows.singleWhere((r) => r['period_ns'] == 6);
      final split = six['split'] as Map<String, dynamic>;
      final known = (split['first_both_known'] as Map)['sample'] as int;
      final x = (split['first_gate_x'] as Map?)?['sample'] as int?;
      expect(
        x == null || known < x,
        want['first_difference_at_6ns_is_known'],
      );
    });

    test('the testbench defaults to the functional gate: a 25 ns clock and '
        'inputs at the edge', () {
      final tb = _file('$_gl/picorv32/tb_picorv32.v').readAsStringSync();
      expect(tb, contains('`define HALF_PERIOD 12.5'));
      expect(tb, contains('`ifdef IN_DELAY'));
      expect(tb, contains('`define DRIVE\n'));
      final dump = _file('$_gl/picorv32/gls_portdump.v').readAsStringSync();
      expect(dump, contains('`ifdef GLS_SDF'));
      expect(dump, contains(r'$sdf_annotate(`GLS_SDF, tb.uut);'));
    });

    test('the document states the recorded outcome and the label', () {
      final doc = _file('$_gl/SDF-GATE.md').readAsStringSync();
      expect(expected['outcome'], 'passes');
      expect(doc, contains('**Result: passes.**'));
      expect(
        doc,
        contains(
          '"Delay-annotated simulation, no timing\nchecks. Setup and hold '
          'violations are not detected."',
        ),
      );
    });
  });

  test('every fixture file is under 5 MB and names no machine path', () {
    for (final root in [_gl, _eqy]) {
      for (final f in _dir(root).listSync(recursive: true).whereType<File>()) {
        expect(f.lengthSync(), lessThan(_maxFixtureBytes), reason: f.path);
        if (f.path.endsWith('.md')) continue;
        expect(
          _machinePath.hasMatch(f.readAsStringSync()),
          isFalse,
          reason: f.path,
        );
      }
    }
  });

  test('the run records name the cell models and the Liberty file', () {
    final resolved = _json('$_smallRun/resolved.json');
    expect(resolved['PDK'], 'sky130A');
    expect(resolved['STD_CELL_LIBRARY'], 'sky130_fd_sc_hd');
    final models = (resolved['CELL_VERILOG_MODELS'] as List).cast<String>();
    expect(models.map((m) => m.split('/').last), [
      'primitives.v',
      'sky130_fd_sc_hd.v',
    ]);
    for (final m in models) {
      expect(m, startsWith(resolved['PDK_ROOT'] as String));
      expect(m, contains('/sky130A/libs.ref/sky130_fd_sc_hd/verilog/'));
    }
    final corner = resolved['DEFAULT_CORNER'] as String;
    expect(corner, 'nom_tt_025C_1v80');
    final lib = (resolved['LIB'] as Map)['*_tt_025C_1v80'] as List;
    expect(lib.single, endsWith('/lib/sky130_fd_sc_hd__tt_025C_1v80.lib'));
    // The physical-only cells the equivalence recipe deletes, as the run's
    // own configuration names them, on each PDK.
    expect(resolved['FILL_CELLS'], [
      'sky130_fd_sc_hd__fill_2',
      'sky130_fd_sc_hd__fill_1',
    ]);
    expect(resolved['DECAP_CELLS'], ['sky130_fd_sc_hd__decap_3']);
    expect(resolved['WELLTAP_CELL'], 'sky130_fd_sc_hd__tapvpwrvgnd_1');
    final gf = _json(
      'verification/fixtures/flow/librelane/3.0.16/gf180mcuD_met/run/resolved.json',
    );
    expect(gf['FILL_CELLS'], ['gf180mcu_fd_sc_mcu7t5v0__fill_*']);
    expect(gf['DECAP_CELLS'], ['gf180mcu_fd_sc_mcu7t5v0__fillcap_*']);
    expect(gf['WELLTAP_CELL'], 'gf180mcu_fd_sc_mcu7t5v0__filltie');
    expect(gf['ENDCAP_CELL'], 'gf180mcu_fd_sc_mcu7t5v0__endcap');
    final ihp = _json(
      'verification/fixtures/flow/librelane/3.0.16/ihp-sg13g2_met/run/resolved.json',
    );
    expect(ihp['FILL_CELLS'], ['sg13g2_fill_1', 'sg13g2_fill_2']);
    expect(ihp['DECAP_CELLS'], ['sg13g2_decap_*']);
    expect(ihp['WELLTAP_CELL'], isNull);
  });

  test(
    'the final netlist keeps the RTL port list; the split variant does not',
    () {
      final nl = _file(
        '$_smallRun/final/nl/path_adder.nl.v',
      ).readAsStringSync();
      expect(nl, contains('module path_adder (clk,'));
      final pnl = _file(
        '$_smallRun/final/pnl/path_adder.pnl.v',
      ).readAsStringSync();
      expect(pnl, contains('inout VPWR;'));
      expect(pnl, contains('inout VGND;'));
      final net = _file('$_gl/mac/net.v').readAsStringSync();
      expect(net, contains(RegExp(r'input\s+\[7:0\]\s+a;')));
      final split = _file('$_gl/mac/net_splitports.v').readAsStringSync();
      expect(split, isNot(contains(RegExp(r'input\s+\[7:0\]\s+a;'))));
      expect(split, contains(r'\a[0]'));
      expect(_file('$_gl/mac/tb.v').readAsStringSync(), contains('.a(a)'));
    },
  );

  test('the MAC port dumps: one x-asymmetry sample, nothing real', () {
    final (x, real, _) = _classify(
      '$_gl/mac/vcd/rtl.vcd',
      '$_gl/mac/vcd/gate.vcd',
    );
    expect(x, 1);
    expect(real, 0);
    final (vx, vreal, _) = _classify(
      '$_gl/mac/vcd/verilator_rtl.vcd',
      '$_gl/mac/vcd/verilator_gate.vcd',
    );
    expect(vx, 0, reason: 'a two-state simulator has no x');
    expect(vreal, 0);
  });

  test(
    'the MAC x*0 probe: parity x-asymmetric on 199 samples, nothing real',
    () {
      final (_, real, perPort) = _classify(
        '$_gl/mac/vcd/rtl_x.vcd',
        '$_gl/mac/vcd/gate_x.vcd',
      );
      expect(real, 0);
      expect(perPort['parity'], 199);
    },
  );

  test('the outcomes in the gate documents match the expectation files', () {
    final gls = _json('$_gl/gls.expected.json');
    final glsDoc = _file('$_gl/GLS-GATE.md').readAsStringSync();
    expect(glsDoc, contains('Outcome: `${gls['outcome']}`'));
    final recipe = _json('$_eqy/recipe.expected.json');
    final recipeDoc = _file('$_eqy/RECIPE-GATE.md').readAsStringSync();
    expect(recipeDoc, contains('Outcome: `${recipe['outcome']}`'));
  });

  group('facts that differ by platform', () {
    final cases =
        _json('$_gl/gls.expected.json')['cases'] as Map<String, dynamic>;
    final recipe =
        _json('$_eqy/recipe.expected.json')['cases'] as Map<String, dynamic>;

    test('each names recorded facts of its own case, with why', () {
      for (final entry in [...cases.entries, ...recipe.entries]) {
        final want = entry.value as Map<String, dynamic>;
        final differs = want[kDiffersByPlatform] as Map<String, dynamic>?;
        if (differs == null) continue;
        expect(differs['why'], isA<String>(), reason: entry.key);
        for (final block in differs.entries) {
          if (block.key == 'why') continue;
          final facts = want[block.key] as Map<String, dynamic>?;
          expect(facts, isNotNull, reason: '${entry.key}: ${block.key}');
          for (final fact in block.value as List) {
            expect(facts, contains(fact), reason: '${entry.key}: $fact');
          }
        }
      }
    });

    // EQY on PicoRV32 as the Linux x64 tool build's netlist gave it on
    // flow-live of 2026-10-28 (6 partitions), and as the darwin capture
    // records it (8).
    Map<String, dynamic> eqyRun(List<String> correct, List<String> mutant) {
      Map<String, dynamic> block(List<String> failing) => <String, dynamic>{
        'overall': 'FAIL',
        'partitions': 75,
        'internal_errors': const <Object?>[],
        'not_passed': [
          for (final f in failing)
            <String, dynamic>{'partition': 'picorv32.$f', 'status': 'FAIL'},
        ],
      };
      return <String, dynamic>{
        'blackboxes': <String, dynamic>{},
        'eqy': block(correct),
        'eqy_mutant': block(mutant),
      };
    }

    const linux = [
      'mem_addr',
      'mem_la_wdata',
      'mem_la_wstrb',
      'mem_wdata',
      'mem_wstrb',
      'pcpi_rs2',
    ];
    const darwin = [
      'mem_addr',
      'mem_instr',
      'mem_la_wdata',
      'mem_la_wstrb',
      'mem_valid',
      'mem_wdata',
      'mem_wstrb',
      'pcpi_rs2',
    ];
    final picorv32Eqy = recipe['picorv32'] as Map<String, dynamic>;

    test('EQY: a live rerun on the Linux netlist agrees with the record, and '
        'a mutant told apart from the correct netlist does not', () {
      expect(
        eqyDifferences(picorv32Eqy, eqyRun(linux, linux), live: true),
        isEmpty,
      );
      expect(
        eqyDifferences(picorv32Eqy, eqyRun(darwin, darwin), live: true),
        isEmpty,
      );
      expect(
        eqyDifferences(
          picorv32Eqy,
          eqyRun(linux, [...linux, 'trap']),
          live: true,
        ),
        hasLength(1),
      );
    });

    test('EQY: the record itself still states the darwin outcome exactly', () {
      expect(eqyDifferences(picorv32Eqy, eqyRun(darwin, darwin)), isEmpty);
      expect(eqyDifferences(picorv32Eqy, eqyRun(linux, linux)), hasLength(2));
    });

    // The PicoRV32 mutant as the Linux x64 tool build's netlist gave it on
    // flow-live of 2026-10-28, and as the darwin capture gave it.
    Map<String, dynamic> mutant(int realBits) => <String, dynamic>{
      'gls_mutant': <String, dynamic>{
        'icarus': <String, dynamic>{
          'rtl': <String, dynamic>{'compiled': true, 'passed': true},
          'gate': <String, dynamic>{'compiled': true, 'passed': true},
          'compare': <String, dynamic>{'real_bits': realBits},
        },
      },
    };
    Map<String, dynamic> recordedMutant() {
      final want = cases['picorv32'] as Map<String, dynamic>;
      return <String, dynamic>{
        'mutant_icarus': want['mutant_icarus'],
        kDiffersByPlatform: want[kDiffersByPlatform],
      };
    }

    test('a live rerun on the Linux netlist agrees with the record', () {
      expect(glsDifferences(recordedMutant(), mutant(0), live: true), isEmpty);
      expect(glsDifferences(recordedMutant(), mutant(8), live: true), isEmpty);
    });

    test('the record itself still states the darwin outcome exactly', () {
      expect(glsDifferences(recordedMutant(), mutant(8)), isEmpty);
      expect(glsDifferences(recordedMutant(), mutant(0)), [
        'mutant_icarus real bits: want above zero, got 0',
      ]);
    });
  });

  test('the recipe template carries the measured steps', () {
    final t = _file('$_eqy/flow_netlist.eqy.in').readAsStringSync();
    for (final line in [
      'read_liberty -ignore_miss_func {liberty}',
      'delete {physical}',
      'hierarchy -top {top} -purge_lib',
      'splitnets',
      'memory_map',
      'timeout {timeout}',
    ]) {
      expect(t, contains(line));
    }
    expect(t, isNot(contains('-ports')), reason: 'never split ports');
  });
}
