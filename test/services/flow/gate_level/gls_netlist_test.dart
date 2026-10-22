// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/gate_level/gls_netlist.dart';

const _gl = 'verification/fixtures/flow/gate_level';
const _run = 'verification/fixtures/flow/librelane/3.0.16/sky130A_met/run';

void main() {
  group('the top module ports of a netlist', () {
    test("LibreLane's non-ANSI header: clk, d and q", () async {
      final ports = (await GlsNetlistPorts.read(
        '$_run/final/nl/path_adder.nl.v',
        'path_adder',
      ))!;
      expect(
        ports.ports.map((p) => (p.name, p.direction)),
        <(String, GlsPortDirection)>[
          ('clk', GlsPortDirection.input),
          ('d', GlsPortDirection.input),
          ('q', GlsPortDirection.output),
        ],
      );
      expect(ports.allUsable, isTrue);
      expect(ports.clockCandidates, <String>['clk']);
    });

    test('buses keep their one name', () async {
      final ports = (await GlsNetlistPorts.read('$_gl/mac/net.v', 'dut'))!;
      expect(ports.ports.map((p) => p.name), <String>[
        'clk',
        'rst_n',
        'en',
        'a',
        'b',
        'acc',
        'cnt',
        'parity',
      ]);
      expect(ports.clockCandidates, <String>['clk']);
    });

    test('the power-aware netlist adds supply ports a testbench never '
        'drives', () async {
      final ports = (await GlsNetlistPorts.read(
        '$_run/final/pnl/path_adder.pnl.v',
        'path_adder',
      ))!;
      expect(ports.ports.map((p) => p.name), containsAll(<String>['VPWR']));
      expect(ports.signalPorts.map((p) => p.name), <String>['clk', 'd', 'q']);
    });

    test(
      'a netlist that split its bus ports has no usable port list',
      () async {
        final ports = (await GlsNetlistPorts.read(
          '$_gl/mac/net_splitports.v',
          'dut',
        ))!;
        expect(ports.ports.first.name, 'clk');
        expect(ports.ports.any((p) => p.name.startsWith(r'\a[0]')), isTrue);
        expect(ports.allUsable, isFalse);
      },
    );

    test('a module the file does not hold is null, not a guess', () async {
      expect(
        await GlsNetlistPorts.read('$_gl/mac/net.v', 'other_top'),
        isNull,
      );
    });

    test('clock candidates are inputs whose names read as a clock', () {
      const ports = GlsNetlistPorts(<GlsPort>[
        GlsPort('clk_i', GlsPortDirection.input),
        GlsPort('sys_clock', GlsPortDirection.input),
        GlsPort('clkout', GlsPortDirection.output),
        GlsPort('block', GlsPortDirection.input),
        GlsPort('rst_n', GlsPortDirection.input),
      ]);
      expect(ports.clockCandidates, <String>['clk_i', 'sys_clock']);
    });
  });

  group('the instance of the design in the testbench', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('gls_scope_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    String write(String name, String text) {
      final path = p.join(tmp.path, name);
      File(path).writeAsStringSync(text);
      return path;
    }

    test('a direct instance in the testbench top', () {
      final found = GlsDutScope.find(
        sources: <String>['$_gl/mac/tb.v'],
        testbenchTop: 'tb',
        design: 'dut',
      );
      expect(found.scope?.path, 'tb.uut');
      expect(found.scope?.instance, 'uut');
    });

    test('the two committed testbenches', () {
      expect(
        GlsDutScope.find(
          sources: <String>['$_gl/path_adder/tb_path_adder.v'],
          testbenchTop: 'tb',
          design: 'path_adder',
        ).scope?.path,
        'tb.uut',
      );
      expect(
        GlsDutScope.find(
          sources: <String>['$_gl/picorv32/tb_picorv32.v'],
          testbenchTop: 'tb',
          design: 'picorv32',
        ).scope?.path,
        'tb.uut',
      );
    });

    test("through the testbench's own sub-modules, with parameters", () {
      final tb = write('tb.sv', '''
module env #(parameter W = 4) (input clk);
  dut #(.W(W)) u_dut (.clk(clk));
endmodule
module top_tb;
  reg clk = 0;
  env #(.W(8)) e0 (.clk(clk));
  always #5 clk = ~clk;
endmodule
''');
      final found = GlsDutScope.find(
        sources: <String>[tb],
        testbenchTop: 'top_tb',
        design: 'dut',
      );
      expect(found.scope?.path, 'top_tb.e0.u_dut');
    });

    test('an instance named only in a comment is not an instance', () {
      final tb = write('tb.v', '''
module tb;
  // dut ghost (.clk(clk));
  /* dut ghost2 (.clk(clk)); */
  dut real_one (.clk(clk));
endmodule
''');
      expect(
        GlsDutScope.find(
          sources: <String>[tb],
          testbenchTop: 'tb',
          design: 'dut',
        ).scope?.instance,
        'real_one',
      );
    });

    test('two instances is ambiguous, none is not found', () {
      final two = write('two.v', '''
module tb;
  dut a (.clk(clk));
  dut b (.clk(clk));
endmodule
''');
      expect(
        GlsDutScope.find(
          sources: <String>[two],
          testbenchTop: 'tb',
          design: 'dut',
        ).problem,
        GlsDutScope.ambiguous,
      );
      final none = write('none.v', 'module tb; endmodule\n');
      expect(
        GlsDutScope.find(
          sources: <String>[none],
          testbenchTop: 'tb',
          design: 'dut',
        ).problem,
        'not_found',
      );
      expect(
        GlsDutScope.find(
          sources: <String>[none],
          testbenchTop: 'missing',
          design: 'dut',
        ).problem,
        'testbench_not_found',
      );
    });

    test('language keywords and function calls are not instances', () {
      final tb = write('kw.v', r'''
module tb;
  reg clk = 0, rst_n = 0;
  integer i, f;
  initial begin
    f = $fopen("x");
    for (i = 0; i < 4; i = i + 1) begin
      @(negedge clk);
    end
    if (rst_n) $finish;
  end
  dut u (.clk(clk));
endmodule
''');
      expect(
        GlsDutScope.find(
          sources: <String>[tb],
          testbenchTop: 'tb',
          design: 'dut',
        ).scope?.path,
        'tb.u',
      );
    });
  });
}
