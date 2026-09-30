// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/hdl_language.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';

void main() {
  group('SimulatorCapabilities', () {
    test('wraps supportedLanguages in an unmodifiable set', () {
      final caps = SimulatorCapabilities(
        supportedLanguages: const {HdlLanguage.verilog},
        supportsVcd: true,
        supportsFst: true,
        supportsCocotb: false,
        requiresSeparateCompileStep: true,
        emitsStructuredOutput: false,
      );
      expect(
        () => caps.supportedLanguages.add(HdlLanguage.vhdl),
        throwsUnsupportedError,
      );
    });

    test('exposes the declared capability flags', () {
      final caps = SimulatorCapabilities(
        supportedLanguages: const {HdlLanguage.systemVerilog},
        supportsVcd: true,
        supportsFst: true,
        supportsCocotb: false,
        requiresSeparateCompileStep: false,
        emitsStructuredOutput: false,
      );
      expect(caps.supportedLanguages, {HdlLanguage.systemVerilog});
      expect(caps.supportsVcd, isTrue);
      expect(caps.supportsFst, isTrue);
      expect(caps.supportsCocotb, isFalse);
      expect(caps.requiresSeparateCompileStep, isFalse);
      expect(caps.emitsStructuredOutput, isFalse);
    });
  });

  group('TestExecutionEvent', () {
    test('TestLogLine carries line / fromStderr / timestamp', () {
      final now = DateTime.utc(2026, 5, 22, 10);
      final ev = TestLogLine(line: 'hello', fromStderr: true, timestamp: now);
      expect(ev.line, 'hello');
      expect(ev.fromStderr, isTrue);
      expect(ev.timestamp, now);
    });

    test('TestStatusChange carries an intermediate status', () {
      const ev = TestStatusChange(status: TestStatus.running);
      expect(ev.status, TestStatus.running);
    });

    test('TestExecutionFinished captures terminal data', () {
      final start = DateTime.utc(2026, 5, 22, 10);
      final finish = start.add(const Duration(seconds: 5));
      final ev = TestExecutionFinished(
        status: TestStatus.pass,
        exitCode: 0,
        startedAt: start,
        finishedAt: finish,
        waveformPath: '/tmp/dump.fst',
      );
      expect(ev.status, TestStatus.pass);
      expect(ev.exitCode, 0);
      expect(ev.waveformPath, '/tmp/dump.fst');
      expect(finish.difference(start), const Duration(seconds: 5));
    });
  });
}
