// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/services/config/mixed_language_validator.dart';

void main() {
  group('MixedLanguageValidator', () {
    const validator = MixedLanguageValidator(
      simulatorLanguages: {
        'icarus': {HdlLanguage.verilog, HdlLanguage.systemVerilog},
        'verilator': {HdlLanguage.verilog, HdlLanguage.systemVerilog},
        'ghdl': {HdlLanguage.vhdl},
      },
    );

    TestSpec make({
      required String simulator,
      required List<String> sources,
      Map<String, HdlLanguage> overrides = const {},
    }) {
      return TestSpec(
        id: 'foo/bar',
        name: 'bar',
        suiteName: 'foo',
        simulatorId: simulator,
        top: 'tb',
        sources: sources,
        sourceLanguages: overrides,
      );
    }

    test('returns no errors when every source matches the simulator', () {
      final errors = validator.validate(
        tests: [
          make(simulator: 'icarus', sources: ['rtl/a.v', 'rtl/b.sv']),
          make(simulator: 'ghdl', sources: ['rtl/c.vhd']),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, isEmpty);
    });

    test('flags Icarus against a .vhd source', () {
      final errors = validator.validate(
        tests: [
          make(simulator: 'icarus', sources: ['rtl/a.v', 'rtl/b.vhd']),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, hasLength(1));
      final err = errors.single;
      expect(err.path, '/path/simcrux.yaml');
      expect(err.message, contains('foo/bar'));
      expect(err.message, contains('VHDL'));
      expect(err.message, contains('rtl/b.vhd'));
      expect(err.message, contains('icarus'));
      // Suggestion list should include `ghdl` and `cocotb`.
      expect(err.message, contains('ghdl'));
      expect(err.message, contains('cocotb'));
    });

    test('flags GHDL against a .v source', () {
      final errors = validator.validate(
        tests: [
          make(simulator: 'ghdl', sources: ['rtl/a.vhd', 'rtl/b.v']),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('Verilog'));
      expect(errors.single.message, contains('rtl/b.v'));
    });

    test('Cocotb admits Verilog + VHDL + Python freely', () {
      final errors = validator.validate(
        tests: [
          make(
            simulator: 'cocotb',
            sources: ['tb/dff.py', 'rtl/dff.v', 'rtl/legacy.vhd'],
          ),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, isEmpty);
    });

    test('per-source language overrides take precedence over extension', () {
      // Disguised .txt that's actually Verilog — declared via override.
      final errors = validator.validate(
        tests: [
          make(
            simulator: 'icarus',
            sources: ['rtl/legacy.txt'],
            overrides: {'rtl/legacy.txt': HdlLanguage.verilog},
          ),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, isEmpty);
    });

    test('per-source language override can also flag a mismatch', () {
      final errors = validator.validate(
        tests: [
          make(
            simulator: 'icarus',
            sources: ['rtl/legacy.txt'],
            overrides: {'rtl/legacy.txt': HdlLanguage.vhdl},
          ),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, hasLength(1));
      expect(errors.single.message, contains('VHDL'));
      expect(errors.single.message, contains('rtl/legacy.txt'));
    });

    test('skips sources with unknown extension and no override', () {
      final errors = validator.validate(
        tests: [
          make(simulator: 'icarus', sources: ['rtl/legacy.txt', 'rtl/a.v']),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, isEmpty);
    });

    test('skips tests with unknown simulator id', () {
      final errors = validator.validate(
        tests: [
          make(simulator: 'questa', sources: ['rtl/a.v']),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, isEmpty);
    });

    test('reports one error per offending source', () {
      final errors = validator.validate(
        tests: [
          make(
            simulator: 'icarus',
            sources: ['rtl/a.vhd', 'rtl/b.vhdl', 'rtl/c.v'],
          ),
        ],
        configFilePath: '/path/simcrux.yaml',
      );
      expect(errors, hasLength(2));
    });
  });
}
