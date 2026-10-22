// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/gate_level/gls_trace_comparator.dart';

const _gl = 'verification/fixtures/flow/gate_level';

/// A one-clock, one-register VCD: `clk`, a 4-bit `q` and a 1-bit `flag` in
/// `tb.uut`, with [body] after the header.
String _vcd(
  String body, {
  String timescale = r'$timescale 1ps $end',
  String scopes = 'tb uut',
  String extraVars = '',
}) {
  final names = scopes.split(' ');
  return [
    timescale,
    for (final n in names) '\$scope module $n \$end',
    r'$var wire 1 ! clk $end',
    r'$var reg 4 " q [3:0] $end',
    r'$var wire 1 # flag $end',
    extraVars,
    for (final _ in names) r'$upscope $end',
    r'$enddefinitions $end',
    body,
  ].join('\n');
}

void main() {
  late Directory tmp;
  final ports = <String>{'clk', 'q', 'flag'};

  setUp(() => tmp = Directory.systemTemp.createTempSync('gls_comparator_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String write(String name, String text) {
    final path = p.join(tmp.path, name);
    File(path).writeAsStringSync(text);
    return path;
  }

  Future<GlsPortTrace> read(
    String text, {
    String scope = 'tb.uut',
    String clock = 'clk',
    GlsVcdLimits limits = GlsVcdLimits.standard,
  }) => GlsTraceComparator.readTrace(
    write('t${text.hashCode}.vcd', text),
    scope: scope,
    ports: ports,
    clock: clock,
    limits: limits,
  );

  Future<GlsComparison> compare(
    String rtl,
    String gate, {
    int listLimit = 0,
  }) async => GlsTraceComparator.compare(
    await read(rtl),
    await read(gate),
    listLimit: listLimit,
  );

  group('sampling', () {
    test('takes the value before the edge, never the edge timestamp', () async {
      // The RTL register changes in the edge's own timestep; the unit-delay
      // gates change one unit later. A sample at the edge would see the RTL
      // updated and the gates not, and call a correct netlist wrong.
      final rtl = _vcd('''
#0
0!
b0000 "
0#
#10
1!
b0001 "
#20
0!
#30
1!
b0010 "
''');
      final gate = _vcd('''
#0
0!
b0000 "
0#
#10
1!
#11
b0001 "
#20
0!
#30
1!
#31
b0010 "
''');
      final r = await read(rtl);
      expect(r.samples.map((s) => s[r.ports.indexOf('q')]), <String>[
        '0000',
        '0001',
      ]);
      expect(r.timesPs, <int>[10, 30]);
      final c = await compare(rtl, gate);
      expect(c.samplesCompared, 2);
      expect(c.realDiffs, 0);
      expect(c.xDiffs, 0);
      expect(c.sampleTimeMismatches, 0);
    });

    test('only a 0 to 1 transition of the clock is an edge', () async {
      final trace = await read(
        _vcd('''
#0
x!
b0000 "
#5
1!
#10
0!
#15
1!
#20
z!
#25
1!
#30
0!
#40
1!
'''),
      );
      // x to 1 and z to 1 are not edges; 0 to 1 at 15 and 40 are.
      expect(trace.timesPs, <int>[15, 40]);
    });

    test('a vector shorter than its width extends the way VCD says', () async {
      final trace = await read(
        _vcd('''
#0
0!
b1 "
#10
1!
bx "
#20
0!
#30
1!
bz1 "
#40
0!
#50
1!
'''),
      );
      final q = trace.ports.indexOf('q');
      expect(trace.samples.map((s) => s[q]), <String>['0001', 'xxxx', 'zzz1']);
    });

    test('the timescale scales the sample time to picoseconds', () async {
      final trace = await read(
        _vcd('''
#0
0!
#10
1!
''', timescale: '\$timescale\n\t10ns\n\$end'),
      );
      expect(trace.timesPs, <int>[100000]);
    });

    test('values outside the port scope never reach a sample', () async {
      final text = [
        r'$timescale 1ps $end',
        r'$scope module tb $end',
        r'$var wire 1 ! clk $end',
        r'$var reg 4 " q [3:0] $end',
        r'$scope module uut $end',
        r'$var wire 1 # clk $end',
        r'$var reg 4 $ q [3:0] $end',
        r'$var reg 4 % hidden [3:0] $end',
        r'$upscope $end',
        r'$upscope $end',
        r'$enddefinitions $end',
        '#0',
        '0#',
        r'b0000 $',
        'b1111 %',
        'b1010 "',
        '#10',
        '1#',
        r'b0011 $',
        '1!',
      ].join('\n');
      final trace = await read(text);
      expect(trace.ports, <String>['clk', 'q']);
      // `hidden` is in the scope but not a port; the testbench's own `q`
      // (code `"`) is outside it.
      expect(trace.samples.single[trace.ports.indexOf('q')], '0000');
    });

    test('a dump whose scopes are wrapped in a top still matches', () async {
      final trace = await read(
        _vcd('''
#0
0!
#10
1!
''', scopes: 'TOP tb uut'),
      );
      expect(trace.samples, hasLength(1));
    });

    test('two names on one identifier both read it', () async {
      final text = [
        r'$timescale 1ps $end',
        r'$scope module tb $end',
        r'$scope module uut $end',
        r'$var wire 1 ! clk $end',
        r'$var reg 4 " q [3:0] $end',
        r'$var reg 4 " flag $end',
        r'$upscope $end',
        r'$upscope $end',
        r'$enddefinitions $end',
        '#0',
        '0!',
        'b0101 "',
        '#10',
        '1!',
      ].join('\n');
      final trace = await read(text);
      final row = trace.samples.single;
      expect(row[trace.ports.indexOf('q')], '0101');
      expect(row[trace.ports.indexOf('flag')], '0101');
    });
  });

  group('classification', () {
    // Every case: one edge at t=10, the port values before it as given.
    String edge(String rtlQ, {String flag = '0'}) => _vcd('''
#0
0!
b$rtlQ "
$flag#
#10
1!
''');

    test('X in the RTL and a known gate is X-asymmetry, not real', () async {
      final c = await compare(edge('xxxx'), edge('0000'));
      expect(c.xDiffs, 1);
      expect(c.realDiffs, 0);
      expect(c.xBits, 4);
      expect(c.xSamples, 1);
      expect(c.realSamples, 0);
      expect(c.firstRealPs, isNull);
      expect(c.firstXPs, 10);
      expect(c.firstDiffPs, 10);
    });

    test('Z in the RTL against a known gate is X-asymmetry too', () async {
      final c = await compare(edge('zzzz'), edge('1010'));
      expect(c.xDiffs, 1);
      expect(c.realDiffs, 0);
    });

    test('both known and unequal is real', () async {
      final c = await compare(edge('0101'), edge('0111'));
      expect(c.realDiffs, 1);
      expect(c.realBits, 1);
      expect(c.xDiffs, 0);
      expect(c.firstRealPs, 10);
    });

    test('X in the gate where the RTL is known is real: a reset-less '
        'register under gates', () async {
      final c = await compare(edge('0000'), edge('xxxx'));
      expect(c.realDiffs, 1);
      expect(c.realBits, 4);
      expect(c.xDiffs, 0);
    });

    test('unknown on both sides is not a difference', () async {
      final c = await compare(edge('xxzx'), edge('zxxx'));
      expect(c.realDiffs, 0);
      expect(c.xDiffs, 0);
      expect(c.firstDiffPs, isNull);
    });

    test(
      'a port with a real bit and an X bit is one real difference',
      () async {
        final c = await compare(edge('x001'), edge('0000'));
        expect(c.realDiffs, 1);
        expect(c.xDiffs, 0);
        expect(c.realBits, 1);
        expect(c.xBits, 1);
      },
    );

    test('equal values compare equal', () async {
      final c = await compare(edge('1100'), edge('1100'));
      expect(c.realDiffs, 0);
      expect(c.xDiffs, 0);
      expect(c.samplesCompared, 1);
    });

    test('counts are per port per sample, and ports are named', () async {
      String two(String q, String flag) => _vcd('''
#0
0!
b$q "
$flag#
#10
1!
#20
0!
#30
1!
''');
      final c = await compare(two('xxxx', 'x'), two('0000', '1'));
      // Two samples, two ports (q and flag), all X-asymmetry.
      expect(c.xDiffs, 4);
      expect(c.perPort['q']!.xAsymmetry, 2);
      expect(c.perPort['flag']!.xAsymmetry, 2);
      expect(c.xSamples, 2);
    });

    test('the listing is bounded and ordered', () async {
      String many(String q) => _vcd('''
#0
0!
b$q "
0#
#10
1!
#20
0!
#30
1!
#40
0!
#50
1!
''');
      final c = await compare(many('xxxx'), many('0000'), listLimit: 2);
      expect(c.xDiffs, 3);
      expect(c.listed, hasLength(2));
      expect(c.listed.first.sample, 0);
      expect(c.listed.first.port, 'q');
      expect(c.listed.first.rtl, 'xxxx');
      expect(c.listed.first.gate, '0000');
      expect(c.listed.first.kind, GlsDifferenceKind.xAsymmetry);
      expect(c.listed.last.sample, 1);
      expect(
        (await compare(many('xxxx'), many('0000'))).listed,
        isEmpty,
        reason: 'the counts need no list',
      );
    });

    test('a port one side did not dump is named, not compared', () async {
      final withFlag = await read(edge('0000'));
      final without = await read(
        [
          r'$timescale 1ps $end',
          r'$scope module tb $end',
          r'$scope module uut $end',
          r'$var wire 1 ! clk $end',
          r'$var reg 4 " q [3:0] $end',
          r'$upscope $end',
          r'$upscope $end',
          r'$enddefinitions $end',
          '#0',
          '0!',
          'b0000 "',
          '#10',
          '1!',
        ].join('\n'),
      );
      final c = GlsTraceComparator.compare(withFlag, without);
      expect(c.portsNotDumped, <String>['flag']);
      expect(c.portsCompared, containsAll(<String>['clk', 'q']));
      expect(c.realDiffs, 0);
    });
  });

  group('bounds', () {
    test('a file over the byte cap is refused before it is read', () async {
      expect(
        () => read(
          edge2(),
          limits: const GlsVcdLimits(maxBytes: 16),
        ),
        throwsA(
          isA<GlsVcdException>().having(
            (e) => e.problem,
            'problem',
            GlsVcdProblem.tooLarge,
          ),
        ),
      );
    });

    test('more clock edges than the cap are refused', () async {
      final text = _vcd(
        [
          '#0',
          '0!',
          for (var t = 10; t < 100; t += 10) ...<String>[
            '#$t',
            if ((t ~/ 10).isOdd) '1!' else '0!',
          ],
        ].join('\n'),
      );
      expect(
        () => read(text, limits: const GlsVcdLimits(maxSamples: 2)),
        throwsA(
          isA<GlsVcdException>().having(
            (e) => e.problem,
            'problem',
            GlsVcdProblem.tooLarge,
          ),
        ),
      );
    });

    test('more ports than the cap are refused', () async {
      expect(
        () => read(edge2(), limits: const GlsVcdLimits(maxVariables: 2)),
        throwsA(isA<GlsVcdException>()),
      );
    });

    test(
      'a missing file, a missing scope and a missing clock are named',
      () async {
        await expectLater(
          GlsTraceComparator.readTrace(
            p.join(tmp.path, 'absent.vcd'),
            scope: 'tb.uut',
            ports: ports,
            clock: 'clk',
          ),
          throwsA(
            isA<GlsVcdException>().having(
              (e) => e.problem,
              'problem',
              GlsVcdProblem.unreadable,
            ),
          ),
        );
        await expectLater(
          read(edge2(), scope: 'tb.other'),
          throwsA(
            isA<GlsVcdException>().having(
              (e) => e.problem,
              'problem',
              GlsVcdProblem.scopeMissing,
            ),
          ),
        );
        await expectLater(
          read(edge2(), clock: 'nope'),
          throwsA(
            isA<GlsVcdException>().having(
              (e) => e.problem,
              'problem',
              GlsVcdProblem.scopeMissing,
            ),
          ),
        );
      },
    );

    test('an exception never repeats a path or a signal name', () async {
      try {
        await read(edge2(), scope: 'tb.secret_scope');
        fail('expected an exception');
      } on GlsVcdException catch (e) {
        expect(e.message, isNot(contains('secret_scope')));
        expect(e.message, isNot(contains(tmp.path)));
      }
    });
  });

  group('the research MAC dumps', () {
    final macPorts = <String>{
      'clk',
      'rst_n',
      'en',
      'a',
      'b',
      'acc',
      'cnt',
      'parity',
    };

    Future<GlsComparison> mac(String rtl, String gate) =>
        GlsTraceComparator.compareFiles(
          rtlPath: '$_gl/mac/vcd/$rtl.vcd',
          gatePath: '$_gl/mac/vcd/$gate.vcd',
          scope: 'tb.uut',
          ports: macPorts,
          clock: 'clk',
        );

    test('Icarus, no probe: one X-asymmetry sample, nothing real', () async {
      final c = await mac('rtl', 'gate');
      // The testbench's clock rises three times before its first checked
      // cycle (period 20 ns, reset released at 45 ns), then once per cycle.
      expect(c.samplesCompared, 203);
      expect(c.realDiffs, 0);
      // The RTL's asynchronous-reset registers are x until the first edge;
      // the gate flops are already reset.
      expect(c.xSamples, 1);
      expect(c.firstXPs, isNotNull);
    });

    test('Icarus, x*0 probe: parity X-asymmetric on 199 samples', () async {
      final c = await mac('rtl_x', 'gate_x');
      expect(c.realDiffs, 0);
      expect(c.perPort['parity']!.xAsymmetry, 199);
      expect(c.perPort['parity']!.real, 0);
    });

    test(
      'Verilator: nothing differs, and the whole model is not read',
      () async {
        final c = await mac('verilator_rtl', 'verilator_gate');
        expect(c.realDiffs, 0);
        expect(c.xDiffs, 0);
        expect(c.portsCompared, containsAll(macPorts));
      },
    );
  });
}

/// A minimal valid dump with one edge, for the bound tests.
String edge2() => _vcd('''
#0
0!
b0000 "
0#
#10
1!
''');
