// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// SvaRefusalClassifier against the committed refusals of the open frontends:
// every refused probe of the 51-probe matrix on both frontends (build
// 20261021), the refused handshake design on all three builds (the older
// two keep the message only in model/design.log), and hand-written
// statements for each construct class. The expected class is the hand
// expectation's (sva_matrix.expected.json `class`, handshake_temporal
// `refused_constructs`), never the classifier's own output.
//
// MUTATION: swap the delay and implication checks in classifyStatement and
// `a |-> ##1 b` reads as implication; drop the design.log lines and the
// older builds' slang refusal is lost.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/formal_diagnostic.dart';
import 'package:simcrux/services/formal/sva_refusal_classifier.dart';

import '../../support/formal_fixture_checks.dart';

String _fx(String relative) => p.join(kFormalFixtureRoot, relative);

List<String> _lines(String relative) {
  final file = File(_fx(relative));
  if (!file.existsSync()) fail('fixture $relative is missing');
  return const LineSplitter().convert(file.readAsStringSync());
}

void main() {
  const classifier = SvaRefusalClassifier();

  group('the SVA matrix, as the frontends refused it', () {
    final expected = readJsonObject(_fx('sva_matrix/sva_matrix.expected.json'));
    final tsv = _lines('sva_matrix/captured/results.tsv').skip(1);
    final refused = <String>{
      for (final row in tsv)
        if (row.split('\t') case [
          final probe,
          final fe,
          final exit,
          ...,
        ] when exit != '0')
          '$probe|$fe',
    };

    for (final probe in objectList(expected['probes'])) {
      final name = probe['probe']! as String;
      final source = File(
        _fx('sva_matrix/probes/$name.sv'),
      ).readAsStringSync();
      for (final fe in kFormalSvaFrontends) {
        final frontend = fe == 'slang'
            ? FormalFrontend.slang
            : FormalFrontend.builtin;
        final wasRefused = refused.contains('$name|$fe');
        test('$name ($fe) ${wasRefused ? 'is classified' : 'is not'}', () {
          final refusal = classifier.classify(
            lines: _lines('sva_matrix/captured/$name.$fe.log'),
            frontend: frontend,
            readSource: (file, line) =>
                SvaRefusalClassifier.statementAt(source, line),
          );
          if (!wasRefused) {
            expect(refusal, isNull);
            return;
          }
          expect(refusal, isNotNull, reason: 'a refused probe is diagnosed');
          expect(refusal!.frontend, frontend);
          expect(refusal.line, isNotNull);
          final cls = probe['class'] as String?;
          // A temporal form lands in its hand class; any other refused
          // form (a concurrent boolean property the built-in parser cannot
          // read, an initial assumption slang refuses) lands in `other`.
          expect(
            refusal.constructClass.wireName,
            cls ?? SvaConstructClass.other.wireName,
          );
        });
      }
    }

    test('every temporal class of the closed set comes from a fixture', () {
      final classes = <String>{
        for (final probe in objectList(expected['probes']))
          if (probe['class'] case final String c) c,
      };
      expect(
        classes,
        containsAll(<String>[
          for (final c in SvaConstructClass.values)
            if (c.temporal) c.wireName,
        ]),
      );
    });
  });

  group('the refused handshake design on three builds', () {
    final expected = readJsonObject(
      _fx('sby/handshake_temporal/handshake_temporal.expected.json'),
    );
    final refusedLines = <int, String>{
      for (final r in objectList(expected['refused_constructs']))
        r['line']! as int: r['class']! as String,
    };
    final source = File(
      _fx('sby/handshake_temporal/handshake.sv'),
    ).readAsStringSync();

    void check(List<String> lines, FormalFrontend frontend) {
      final refusal = classifier.classify(
        lines: lines,
        frontend: frontend,
        readSource: (file, line) {
          expect(file, 'handshake.sv');
          return SvaRefusalClassifier.statementAt(source, line);
        },
      );
      expect(refusal, isNotNull);
      expect(refusedLines.keys, contains(refusal!.line));
      expect(refusal.constructClass.wireName, refusedLines[refusal.line]);
      expect(refusal.file, 'handshake.sv');
    }

    for (final fe in ['builtin', 'slang']) {
      final frontend = fe == 'slang'
          ? FormalFrontend.slang
          : FormalFrontend.builtin;
      test('20261021 $fe: from the task log alone', () {
        check(_lines('sby/handshake_temporal/captured/$fe/sby.log'), frontend);
      });
      for (final build in ['20261021', '20260921', '20260821']) {
        test('$build $fe: from model/design.log', () {
          final dir = 'schemas/$build/sby/handshake_temporal/$fe';
          check(<String>[
            ..._lines('$dir/design.log'),
            ..._lines('$dir/sby.log'),
          ], frontend);
        });
      }
    }

    test('the older slang builds keep no located error in the task log', () {
      for (final build in ['20260921', '20260821']) {
        final refusal = classifier.classify(
          lines: _lines('schemas/$build/sby/handshake_temporal/slang/sby.log'),
          frontend: FormalFrontend.slang,
          readSource: (file, line) =>
              SvaRefusalClassifier.statementAt(source, line),
        );
        expect(refusal, isNull, reason: build);
      }
    });

    test('the frontend comes from the Yosys banner first', () {
      expect(
        SvaRefusalClassifier.detectFrontend(
          designLog: _lines('sby/handshake_temporal/captured/slang/design.log'),
          script: const <String>['read -formal handshake.sv'],
        ),
        FormalFrontend.slang,
      );
      expect(
        SvaRefusalClassifier.detectFrontend(
          designLog: _lines(
            'sby/handshake_temporal/captured/builtin/design.log',
          ),
        ),
        FormalFrontend.builtin,
      );
    });
  });

  group('frontend detection from the [script]', () {
    test('read_slang, read -formal, verific -sv', () {
      expect(
        SvaRefusalClassifier.detectFrontend(
          script: const <String>[
            'plugin -i slang',
            'read_slang top.sv --top top',
          ],
        ),
        FormalFrontend.slang,
      );
      expect(
        SvaRefusalClassifier.detectFrontend(
          script: const <String>['read -formal top.sv'],
        ),
        FormalFrontend.builtin,
      );
      expect(
        SvaRefusalClassifier.detectFrontend(
          script: const <String>['read_verilog -formal -sv top.sv'],
        ),
        FormalFrontend.builtin,
      );
      expect(
        SvaRefusalClassifier.detectFrontend(
          script: const <String>['verific -sv top.sv', 'verific -import top'],
        ),
        FormalFrontend.verific,
      );
      expect(
        SvaRefusalClassifier.detectFrontend(script: const <String>['prep']),
        FormalFrontend.unknown,
      );
    });

    test('a Yosys without Verific asked for it is reported as verific', () {
      expect(
        SvaRefusalClassifier.detectFrontend(
          designLog: const <String>[
            'ERROR: This version of Yosys is built without Verific support.',
          ],
        ),
        FormalFrontend.verific,
      );
    });
  });

  group('what it never does', () {
    test('a Verific run is never diagnosed', () {
      expect(
        classifier.classify(
          lines: const <String>[
            'top.sv:3: ERROR: syntax error, unexpected TOK_PROPERTY',
          ],
          frontend: FormalFrontend.verific,
          readSource: (_, _) => 'property p; a |-> b; endproperty',
        ),
        isNull,
      );
    });

    test('a syntax error in plain RTL is not called an SVA refusal', () {
      expect(
        classifier.classify(
          lines: const <String>['top.sv:7: ERROR: syntax error, unexpected ;'],
          frontend: FormalFrontend.builtin,
          readSource: (_, _) => '  assign y = a & ;',
        ),
        isNull,
      );
    });

    test('a builtin syntax error with no readable source is not claimed', () {
      expect(
        classifier.classify(
          lines: const <String>[
            "top.sv:7: ERROR: syntax error, unexpected '@'",
          ],
          frontend: FormalFrontend.builtin,
        ),
        isNull,
      );
    });

    test('a slang SVA message with no readable source is `other`', () {
      final refusal = classifier.classify(
        lines: const <String>[
          'top.sv:7: ERROR: encountered unsupported SVA feature',
        ],
        frontend: FormalFrontend.slang,
      );
      expect(refusal?.constructClass, SvaConstructClass.other);
      expect(refusal?.construct, isNull);
      expect(refusal?.location, 'top.sv:7');
    });
  });

  group('classifyStatement: one statement per class', () {
    final cases = <String, (SvaConstructClass, String)>{
      'default clocking cb @(posedge clk); endclocking': (
        SvaConstructClass.defaultClocking,
        'default clocking',
      ),
      'default disable iff (rst);': (
        SvaConstructClass.defaultClocking,
        'default disable iff',
      ),
      r'  sequence s_req; $rose(req); endsequence': (
        SvaConstructClass.namedSequence,
        'sequence',
      ),
      'property p; @(posedge clk) a |-> b; endproperty': (
        SvaConstructClass.namedSequence,
        'property',
      ),
      'assert property (@(posedge clk) a |-> s_eventually b);': (
        SvaConstructClass.livenessOp,
        's_eventually',
      ),
      r'assert property (@(posedge clk) a |-> strong(##[1:$] b));': (
        SvaConstructClass.livenessOp,
        'strong',
      ),
      'assert property (@(posedge clk) a |-> (c throughout b[->1]));': (
        SvaConstructClass.sequenceOp,
        'throughout',
      ),
      'assert property (@(posedge clk) (a ##1 b) and (c ##1 b) |-> c);': (
        SvaConstructClass.sequenceOp,
        'and',
      ),
      'assert property (@(posedge clk) a[*2] |-> b);': (
        SvaConstructClass.repetition,
        '[*2]',
      ),
      'assert property (@(posedge clk) a |-> b[->1] ##1 c);': (
        SvaConstructClass.repetition,
        '[->1]',
      ),
      'assert property (@(posedge clk) a |-> ##[1:3] b);': (
        SvaConstructClass.delay,
        '##[1:3]',
      ),
      'cover property (@(posedge clk) a ##1 b);': (
        SvaConstructClass.delay,
        '##1',
      ),
      'assert property (@(posedge clk) a |-> nexttime b);': (
        SvaConstructClass.delay,
        'nexttime',
      ),
      'a_pulse: assert property (@(posedge clk) ack |=> !ack);': (
        SvaConstructClass.implication,
        '|=>',
      ),
      r'assert property (@(posedge clk) $fell(a) |-> b);': (
        SvaConstructClass.implication,
        '|->',
      ),
      'assert property (@(posedge clk) !(a && b));': (
        SvaConstructClass.other,
        'assert property',
      ),
      'initial assume (rst);': (SvaConstructClass.other, 'initial assume'),
    };
    for (final MapEntry(key: text, value: (cls, construct)) in cases.entries) {
      test(text.trim(), () {
        final hit = SvaRefusalClassifier.classifyStatement(text);
        expect(hit?.constructClass, cls);
        expect(hit?.construct, construct);
      });
    }

    test('a comment never decides the class', () {
      final hit = SvaRefusalClassifier.classifyStatement(
        'assert property (@(posedge clk) a |-> b); // was a ##1 b',
      );
      expect(hit?.constructClass, SvaConstructClass.implication);
    });

    test('a message that names the construct wins over the statement', () {
      final refusal = classifier.classify(
        lines: const <String>[
          r"handshake.sv:49:42: error: unknown system name '$initstate'",
        ],
        frontend: FormalFrontend.slang,
        readSource: (_, _) =>
            r'm_rst: assume property (@(posedge clk) $initstate |-> rst);',
      );
      expect(refusal?.constructClass, SvaConstructClass.other);
      expect(refusal?.construct, r'$initstate');
    });

    test('statementAt reads on to the first semicolon', () {
      const text =
          'module m;\n  a: assert property (@(posedge clk)\n'
          '    a |=> b);\n  wire w;\nendmodule\n';
      expect(
        SvaRefusalClassifier.statementAt(text, 2),
        contains('a |=> b);'),
      );
      expect(
        SvaRefusalClassifier.statementAt(text, 2),
        isNot(contains('wire')),
      );
      expect(SvaRefusalClassifier.statementAt(text, 99), isNull);
    });
  });
}
