// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/eqy_script.dart';

import '../../support/eqy_workdir_fixture.dart';

void main() {
  group('the committed .eqy files', () {
    EqyScript read(String name) => EqyScript.parse(
      File(p.join(eqyCorpus, '$name.eqy')).readAsStringSync(),
    );

    test('alu_pass: gold, gate and one sby strategy, no match rule', () {
      final script = read('alu_pass');
      expect(script.gold, ['read_verilog alu.v', 'prep -top alu']);
      expect(script.gate, ['read_verilog gate.v', 'prep -top alu']);
      expect(script.hasGoldAndGate, isTrue);
      expect(script.match, isEmpty);
      final strategy = script.strategies.single;
      expect(strategy.name, 'sby');
      expect(strategy.type, 'sby');
      expect(strategy.depth, 5);
      expect(strategy.engine, 'smtbmc yices');
      expect(script.engineWord, 'smtbmc');
      expect(script.solver, 'yices');
      expect(script.vhdlPluginLines, isEmpty);
    });

    test('alu_pass2: the gold-nomatch rule under its module', () {
      final rule = read('alu_pass2').match.single;
      expect(rule.module, 'alu');
      expect(rule.text, 'gold-nomatch r');
    });
  });

  group('parsing', () {
    test('comments, unknown sections and strategy order', () {
      final script = EqyScript.parse('''
# a comment
[options]
splitnets off

[gold]
read_verilog a.v   # trailing comment
[gate]
read_verilog b.v

[collect *]
group x

[partition top]
amend y

[strategy fast]
use sat
depth 3

[strategy deep]
use sby
timeout 60

[strategy last]
use dummy

[something_new]
whatever
''');
      expect(script.options, ['splitnets off']);
      expect(script.gold, ['read_verilog a.v']);
      expect(script.collect.single.module, '*');
      expect(script.partition.single.text, 'amend y');
      expect(script.strategies.map((s) => s.name), ['fast', 'deep', 'last']);
      expect(script.strategies[0].effectiveEngine, 'sat');
      expect(script.strategies[1].effectiveEngine, 'smtbmc');
      expect(script.strategies[1].timeoutSeconds, 60);
      expect(script.strategies[2].effectiveEngine, isNull);
      expect(script.engineWord, 'mixed');
      expect(script.solver, isNull, reason: 'two strategies run an engine');
      expect(script.sections, contains('something_new'));
    });

    test('imctk runs the aiger engine', () {
      final script = EqyScript.parse(
        '[gold]\nread_verilog a.v\n[gate]\nread_verilog b.v\n'
        '[strategy i]\nuse imctk\n',
      );
      expect(script.engineWord, 'aiger');
    });

    test('a file without [gate] is not one EQY accepts', () {
      expect(
        EqyScript.parse('[gold]\nread_verilog a.v\n').hasGoldAndGate,
        isFalse,
      );
      expect(const EqyScript().engineWord, isNull);
    });
  });

  group('VHDL through the GHDL plugin', () {
    test('a ghdl command in [gold], [gate] or [script] is found', () {
      final script = EqyScript.parse('''
[gold]
ghdl --std=08 alu.vhd -e alu
prep -top alu
[gate]
read_verilog gate.v
[script]
ghdl -e other
''');
      expect(script.vhdlPluginLines, [
        'ghdl --std=08 alu.vhd -e alu',
        'ghdl -e other',
      ]);
    });

    test('vhdlReads parses each ghdl line SimCrux can lower', () {
      const text = '''
[gold]
ghdl --std=08 rtl/a.vhd rtl/b.vhd -e alu  # the gold
prep -top alu
[gate]
read_verilog gate.v
ghdl c.vhd -e other
''';
      final reads = EqyScript.vhdlReads(text);
      expect(reads, hasLength(2));
      expect(reads[0].section, 'gold');
      expect(reads[0].files, ['rtl/a.vhd', 'rtl/b.vhd']);
      expect(reads[0].unit, 'alu');
      expect(reads[0].standard, '08');
      expect(reads[0].problem, isNull);
      expect(reads[1].section, 'gate');
      expect(reads[1].ordinal, 1);
      expect(reads[1].standard, isNull);
    });

    for (final (line, why) in const [
      ('ghdl -fsynopsys a.vhd -e alu', 'option `-fsynopsys`'),
      ('ghdl a.vhd', 'no unit'),
      ('ghdl -e alu', 'no VHDL file'),
      ('ghdl a.vhd -e alu extra', 'words after the unit'),
      ('ghdl a.vhd -e alu; prep', 'more than one command'),
    ]) {
      test('"$line" cannot be lowered faithfully: $why', () {
        final read = EqyScript.vhdlReads('[gold]\n$line\n').single;
        expect(read.problem, contains(why));
      });
    }

    test('a ghdl line in [script] is refused: it reads both designs', () {
      final read = EqyScript.vhdlReads('[script]\nghdl a.vhd -e a\n').single;
      expect(read.problem, contains('[script]'));
    });

    test('replaceVhdlReads swaps only the ghdl lines, byte for byte else', () {
      const text =
          '[gold]\n  ghdl a.vhd -e alu\nprep -top alu\n# ghdl in a comment\n'
          '[gate]\nghdl b.vhd -e alu\n';
      final out = EqyScript.replaceVhdlReads(text, {
        0: 'read_verilog "/w/gold_0.v"',
        1: 'read_verilog "/w/gate_1.v"',
      });
      expect(
        out,
        '[gold]\nread_verilog "/w/gold_0.v"\nprep -top alu\n'
        '# ghdl in a comment\n[gate]\nread_verilog "/w/gate_1.v"\n',
      );
    });

    test('reading a lowered Verilog file is not the plugin', () {
      final script = EqyScript.parse(
        '[gold]\nread_verilog alu_ghdl.v\n[gate]\nread_verilog g.v\n',
      );
      expect(script.vhdlPluginLines, isEmpty);
    });
  });
}
