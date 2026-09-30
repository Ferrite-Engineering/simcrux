// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/pass_fail_detector/uvm_report_detector.dart';

void main() {
  const detector = UvmReportDetector();

  TestStatus run(
    String stdout, {
    String stderr = '',
    UvmReportPassFailConfig config = const UvmReportPassFailConfig(),
    int? exitCode = 0,
  }) {
    return detector.detect(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      runtime: const Duration(seconds: 1),
      config: config,
    );
  }

  group('UvmReportDetector — defaults (1 FATAL/1 ERROR threshold)', () {
    test('classifies as pass when summary has no errors or fatals', () {
      final status = run('''
--- UVM Report Summary ---
UVM_INFO : 5
UVM_WARNING : 0
UVM_ERROR : 0
UVM_FATAL : 0
''');
      expect(status, TestStatus.pass);
    });

    test('classifies as fail when summary reports any UVM_ERROR', () {
      final status = run('''
--- UVM Report Summary ---
UVM_INFO : 5
UVM_WARNING : 0
UVM_ERROR : 1
UVM_FATAL : 0
''');
      expect(status, TestStatus.fail);
    });

    test('classifies as fail when summary reports any UVM_FATAL', () {
      final status = run('''
--- UVM Report Summary ---
UVM_INFO : 0
UVM_WARNING : 0
UVM_ERROR : 0
UVM_FATAL : 1
''');
      expect(status, TestStatus.fail);
    });

    test('per-message-only stream: fails on a single UVM_ERROR line', () {
      final status = run('UVM_ERROR tb.sv(1) @ 0 ns: bad result');
      expect(status, TestStatus.fail);
    });

    test('per-message-only stream: passes when only INFOs present', () {
      final status = run('UVM_INFO @ 0: hello');
      expect(status, TestStatus.pass);
    });

    test('classifies as unknown when no UVM signal at all', () {
      final status = run('just a Verilog run, nothing UVM');
      expect(status, TestStatus.unknown);
    });
  });

  group('UvmReportDetector — custom thresholds', () {
    test('errorThreshold=5 — passes with 4 errors, fails with 5', () {
      const cfg = UvmReportPassFailConfig(errorThreshold: 5);
      final logFour = StringBuffer();
      final logFive = StringBuffer();
      for (var i = 0; i < 4; i++) {
        logFour.writeln('UVM_ERROR tb.sv($i) @ 0 ns: e$i');
      }
      for (var i = 0; i < 5; i++) {
        logFive.writeln('UVM_ERROR tb.sv($i) @ 0 ns: e$i');
      }
      expect(run(logFour.toString(), config: cfg), TestStatus.pass);
      expect(run(logFive.toString(), config: cfg), TestStatus.fail);
    });

    test('fatalThreshold=0 disables the fatal check', () {
      const cfg = UvmReportPassFailConfig(
        fatalThreshold: 0,
        errorThreshold: 0,
      );
      final status = run(
        'UVM_FATAL tb.sv(1) @ 0 ns: would-be fail',
        config: cfg,
      );
      expect(status, TestStatus.pass);
    });

    test('warningThreshold null = warnings never fail', () {
      final logWarn = StringBuffer();
      for (var i = 0; i < 50; i++) {
        logWarn.writeln('UVM_WARNING tb.sv($i) @ 0 ns: w$i');
      }
      // Detector default has warningThreshold: null, so the run with
      // 50 warnings still passes.
      expect(run(logWarn.toString()), TestStatus.pass);
    });

    test('warningThreshold=10 — fails when crossed', () {
      const cfg = UvmReportPassFailConfig(warningThreshold: 10);
      final logWarn = StringBuffer();
      for (var i = 0; i < 10; i++) {
        logWarn.writeln('UVM_WARNING tb.sv($i) @ 0 ns: w$i');
      }
      expect(run(logWarn.toString(), config: cfg), TestStatus.fail);
    });
  });

  group('UvmReportDetector — wrong config type', () {
    test('returns unknown when handed a non-UVM config', () {
      final status = detector.detect(
        stdout: 'UVM_ERROR @ 0: bad',
        stderr: '',
        exitCode: 0,
        runtime: const Duration(seconds: 1),
        config: const ExitCodePassFailConfig(),
      );
      expect(status, TestStatus.unknown);
    });
  });
}
