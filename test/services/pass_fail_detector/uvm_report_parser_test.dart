// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/pass_fail_detector/uvm_report_parser.dart';

void main() {
  group('parseUvmReport — summary table', () {
    test('parses a standard UVM summary block', () {
      final counts = parseUvmReport('''
--- UVM Report Summary ---

** Report counts by severity
UVM_INFO    :   42
UVM_WARNING :    3
UVM_ERROR   :    2
UVM_FATAL   :    0
''');
      expect(counts.source, UvmReportCountSource.summary);
      expect(counts.info, 42);
      expect(counts.warning, 3);
      expect(counts.error, 2);
      expect(counts.fatal, 0);
      expect(counts.hasAnySignal, isTrue);
    });

    test('tolerates partial summaries (missing INFO row)', () {
      final counts = parseUvmReport('''
--- UVM Report Summary ---
UVM_WARNING : 1
UVM_ERROR : 0
UVM_FATAL : 0
''');
      expect(counts.source, UvmReportCountSource.summary);
      expect(counts.info, 0);
      expect(counts.warning, 1);
      expect(counts.error, 0);
      expect(counts.fatal, 0);
    });

    test('rejects an all-zero summary with no count lines', () {
      // Header present but no `UVM_*:` lines at all → falls back to
      // per-message counting (which is also empty here).
      final counts = parseUvmReport('--- UVM Report Summary ---');
      expect(counts.source, UvmReportCountSource.none);
    });
  });

  group('parseUvmReport — per-message counting', () {
    test('counts every UVM_FATAL/ERROR/WARNING/INFO line', () {
      final counts = parseUvmReport('''
UVM_INFO @ 0: reporter [RNTST] Running test
UVM_WARNING tb.sv(42) @ 12 ns: reporter [SCRBD] Scoreboard X
UVM_WARNING tb.sv(56) @ 13 ns: reporter [SCRBD] Scoreboard Y
UVM_ERROR tb.sv(73) @ 24 ns: reporter [CHKR] mismatch
UVM_FATAL tb.sv(99) @ 30 ns: reporter [BUILD] missing
''');
      expect(counts.source, UvmReportCountSource.perMessage);
      expect(counts.info, 1);
      expect(counts.warning, 2);
      expect(counts.error, 1);
      expect(counts.fatal, 1);
    });

    test('rejects UVM_INFOXY as a non-match (identifier follow-rule)', () {
      final counts = parseUvmReport(
        'UVM_INFOXY tb @ 0: this is not a UVM line',
      );
      expect(counts.source, UvmReportCountSource.none);
    });

    test('returns empty when no UVM signal is present at all', () {
      final counts = parseUvmReport('just an iverilog run, nothing UVM');
      expect(counts.source, UvmReportCountSource.none);
      expect(counts.hasAnySignal, isFalse);
    });
  });

  group('parseUvmReport — summary trumps per-message', () {
    test(
      'uses summary counts even when per-message lines are also present',
      () {
        final counts = parseUvmReport('''
UVM_WARNING tb.sv(1) @ 0 ns: per-message warning ignored
UVM_ERROR tb.sv(2) @ 0 ns: per-message error ignored

--- UVM Report Summary ---
UVM_INFO : 10
UVM_WARNING : 5
UVM_ERROR : 3
UVM_FATAL : 0
''');
        // Summary's count of 5 warnings wins over the 1 per-message
        // warning we'd otherwise have counted.
        expect(counts.source, UvmReportCountSource.summary);
        expect(counts.warning, 5);
        expect(counts.error, 3);
      },
    );
  });
}
