// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

void main() {
  group('ConfigLoader — mixed-language extensions', () {
    test('parses source entries in legacy bare-string form', () {
      final config = ConfigLoader().parse(
        '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        sources:
          - rtl/a.v
          - rtl/b.sv
''',
        '/proj/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      expect(test.sources, ['rtl/a.v', 'rtl/b.sv']);
      expect(test.sourceLanguages, isEmpty);
    });

    test('parses object-form source entries with explicit language', () {
      final config = ConfigLoader().parse(
        '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        sources:
          - rtl/a.v
          - { path: rtl/legacy.txt, language: verilog }
          - { path: rtl/b.bin, language: systemverilog }
''',
        '/proj/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      expect(
        test.sources,
        ['rtl/a.v', 'rtl/legacy.txt', 'rtl/b.bin'],
      );
      expect(test.sourceLanguages, {
        'rtl/legacy.txt': HdlLanguage.verilog,
        'rtl/b.bin': HdlLanguage.systemVerilog,
      });
    });

    test('accepts "auto" as the explicit no-override marker', () {
      final config = ConfigLoader().parse(
        '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        sources:
          - { path: rtl/a.v, language: auto }
''',
        '/proj/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      // No override stored — extension does the talking.
      expect(test.sourceLanguages, isEmpty);
    });

    test('rejects unknown language values', () {
      expect(
        () => ConfigLoader().parse(
          '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
        sources:
          - { path: rtl/a.v, language: nonexistent_lang }
''',
          '/proj/simcrux.yaml',
        ),
        throwsA(isA<ConfigLoaderException>()),
      );
    });

    test('merges suite-level and test-level source overrides', () {
      final config = ConfigLoader().parse(
        '''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    sources:
      - { path: rtl/legacy.txt, language: verilog }
    tests:
      - name: t
        top: tb
        sources:
          - rtl/extra.v
''',
        '/proj/simcrux.yaml',
      );
      final test = config.suites.single.tests.single;
      expect(test.sources, ['rtl/legacy.txt', 'rtl/extra.v']);
      expect(
        test.sourceLanguages,
        {'rtl/legacy.txt': HdlLanguage.verilog},
      );
    });
  });

  group('ConfigLoader.load — mixed-language compatibility check', () {
    test('rejects an Icarus test whose source list includes a .vhd', () async {
      final dir = Directory.systemTemp.createTempSync('simcrux-ml');
      try {
        final yamlPath = p.join(dir.path, 'simcrux.yaml');
        File(yamlPath).writeAsStringSync('''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: bad
        top: tb
        sources:
          - rtl/a.v
          - rtl/legacy.vhd
''');
        ConfigLoaderException? caught;
        try {
          await ConfigLoader().load(yamlPath);
        } on ConfigLoaderException catch (e) {
          caught = e;
        }
        expect(caught, isNotNull);
        expect(caught!.errors, hasLength(1));
        expect(caught.errors.single.message, contains('VHDL'));
        expect(caught.errors.single.message, contains('icarus'));
        expect(caught.errors.single.message, contains('s/bad'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('passes an explicit-override-correct mix under Icarus', () async {
      final dir = Directory.systemTemp.createTempSync('simcrux-ml');
      try {
        final yamlPath = p.join(dir.path, 'simcrux.yaml');
        File(yamlPath).writeAsStringSync('''
version: "1"
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: good
        top: tb
        sources:
          - rtl/a.v
          - { path: rtl/legacy.txt, language: verilog }
''');
        final config = await ConfigLoader().load(yamlPath);
        expect(config.suites.single.tests.single.name, 'good');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('passes a Verilog + VHDL + Python set under Cocotb', () async {
      final dir = Directory.systemTemp.createTempSync('simcrux-ml');
      try {
        final yamlPath = p.join(dir.path, 'simcrux.yaml');
        File(yamlPath).writeAsStringSync('''
version: "1"
defaults:
  simulator: cocotb
suites:
  s:
    tests:
      - name: mixed
        top: tb
        sources:
          - rtl/dff.v
          - rtl/legacy.vhd
          - tb/test_dff.py
''');
        final config = await ConfigLoader().load(yamlPath);
        expect(config.suites.single.tests.single.name, 'mixed');
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });
}
