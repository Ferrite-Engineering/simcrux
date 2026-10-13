// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/pass_fail_config.dart';
import 'package:simcrux/services/job_scheduler/failure_message.dart';

void main() {
  const exitCode = ExitCodePassFailConfig();

  group('firstFailingLine', () {
    test('finds the simulator vocabularies, stderr before stdout', () {
      for (final (line, label) in <(String, String)>[
        ('ERROR: t.sv:1: check failed', 'icarus'),
        ('FATAL: t.sv:3: bus hung', 'icarus fatal'),
        (
          '%Error: top.sv:12:5: syntax error, unexpected endmodule',
          'verilator',
        ),
        ('UVM_ERROR @ 120: uvm_test_top [SCB] mismatch', 'uvm'),
        ('tb.vhd:9:3:error: no declaration for "clk"', 'ghdl'),
        ('Assertion failed: data == 0x42', 'assertion'),
        ('FAILED test_dff.test_reset', 'cocotb'),
        ('Traceback (most recent call last):', 'python'),
        ('# 1000 ns  ERROR @ 1000: bad parity', 'timestamped'),
      ]) {
        expect(
          firstFailingLine(
            config: exitCode,
            stdout: 'hello\nall good\n$line\nbye',
            stderr: '',
          ),
          line,
          reason: label,
        );
      }
      expect(
        firstFailingLine(
          config: exitCode,
          stdout: 'ERROR: later, on stdout',
          stderr: 'ERROR: first, on stderr',
        ),
        'ERROR: first, on stderr',
      );
    });

    test('a mid-sentence mention of error is not a verdict', () {
      expect(
        firstFailingLine(
          config: exitCode,
          stdout: 'Running with 0 errors so far\nNo ERROR: here\nTEST DONE',
          stderr: '',
        ),
        isNull,
        reason: 'a null message is honest; a quoted last line is not',
      );
    });

    test("a configured detector's own fail line wins", () {
      const config = StringMatchPassFailConfig(failString: 'MISMATCH');
      expect(
        firstFailingLine(
          config: config,
          stdout:
              'ERROR: unrelated warning-ish line\nscoreboard MISMATCH at 42',
          stderr: '',
        ),
        'scoreboard MISMATCH at 42',
      );
      const regex = RegexPassFailConfig(failPattern: r'^BAD\s+\d+');
      expect(
        firstFailingLine(
          config: regex,
          stdout: 'ok\nBAD 7 widgets\n',
          stderr: '',
        ),
        'BAD 7 widgets',
      );
    });

    test(
      'falls back to the generic vocabulary when the fail string is absent',
      () {
        const config = StringMatchPassFailConfig(passString: 'TEST PASSED');
        expect(
          firstFailingLine(
            config: config,
            stdout: 'FATAL: clock stopped',
            stderr: '',
          ),
          'FATAL: clock stopped',
        );
      },
    );

    test('is bounded', () {
      final long = 'ERROR: ${'x' * 1000}';
      final message = firstFailingLine(
        config: exitCode,
        stdout: long,
        stderr: '',
      )!;
      expect(message.length, kDerivedFailureMessageMaxChars);
      expect(message, endsWith('…'));
    });

    test('nothing in, nothing out', () {
      expect(
        firstFailingLine(config: exitCode, stdout: '', stderr: ''),
        isNull,
      );
      expect(
        firstFailingLine(config: exitCode, stdout: '\n  \n', stderr: '\n'),
        isNull,
      );
    });
  });
}
