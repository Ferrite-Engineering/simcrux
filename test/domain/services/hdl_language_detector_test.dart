// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/services/hdl_language_detector.dart';

void main() {
  group('HdlLanguageDetector.detect', () {
    const detector = HdlLanguageDetector();

    test('returns Verilog for .v', () {
      expect(detector.detect('rtl/cpu.v'), HdlLanguage.verilog);
      expect(detector.detect('/abs/path/foo.V'), HdlLanguage.verilog);
    });

    test('returns SystemVerilog for .sv and .svh', () {
      expect(detector.detect('rtl/cpu.sv'), HdlLanguage.systemVerilog);
      expect(detector.detect('rtl/cpu.svh'), HdlLanguage.systemVerilog);
      expect(detector.detect('/abs/path/foo.SV'), HdlLanguage.systemVerilog);
    });

    test('returns Verilog for .vh (Verilog header)', () {
      expect(detector.detect('rtl/macros.vh'), HdlLanguage.verilog);
    });

    test('returns VHDL for .vhd and .vhdl', () {
      expect(detector.detect('rtl/cpu.vhd'), HdlLanguage.vhdl);
      expect(detector.detect('rtl/cpu.vhdl'), HdlLanguage.vhdl);
      expect(detector.detect('/abs/path/foo.VHDL'), HdlLanguage.vhdl);
    });

    test('returns Python for .py', () {
      expect(detector.detect('tb/cocotb_test.py'), HdlLanguage.python);
    });

    test('returns null for unknown extensions', () {
      expect(detector.detect('rtl/foo.txt'), isNull);
      expect(detector.detect('rtl/foo'), isNull);
      expect(detector.detect('rtl/foo.bin'), isNull);
    });
  });

  group('HdlLanguageDetector.dominantLanguage', () {
    const detector = HdlLanguageDetector();

    test('returns null for empty input', () {
      expect(detector.dominantLanguage(<String>[]), isNull);
    });

    test('returns null when no path has a recognizable extension', () {
      expect(detector.dominantLanguage(['a.txt', 'b.bin']), isNull);
    });

    test('returns Verilog when Verilog files dominate', () {
      expect(
        detector.dominantLanguage(['a.v', 'b.v', 'c.vhd']),
        HdlLanguage.verilog,
      );
    });

    test('returns VHDL when VHDL files dominate', () {
      expect(
        detector.dominantLanguage(['a.vhd', 'b.vhdl', 'c.v']),
        HdlLanguage.vhdl,
      );
    });

    test('tie-breaks in order Verilog → SystemVerilog → VHDL', () {
      expect(
        detector.dominantLanguage(['a.v', 'b.sv']),
        HdlLanguage.verilog,
      );
      expect(
        detector.dominantLanguage(['a.sv', 'b.vhd']),
        HdlLanguage.systemVerilog,
      );
    });

    test('counts SystemVerilog separately from Verilog', () {
      expect(
        detector.dominantLanguage(['a.sv', 'b.sv', 'c.v']),
        HdlLanguage.systemVerilog,
      );
    });

    test('ignores unrecognized extensions when computing the majority', () {
      expect(
        detector.dominantLanguage(['a.vhd', 'b.vhd', 'c.txt', 'd.bin']),
        HdlLanguage.vhdl,
      );
    });
  });
}
