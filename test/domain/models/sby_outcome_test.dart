// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/sby_outcome.dart';

// The SymbiYosys log parser (VERIFICATION_GUIDE.md §18.3).
//
// The one thing worth stating up front: **nothing here reads an exit
// code**. `sby`'s conclusion is a line in its log, and classifying from
// the exit code instead is how a proof that never ran reports green.
//
// MUTATION: make `outcome` default to `RiscvFormalVerdict.pass` instead of
// `noOutcome` and the "silence is not a pass" test fails — that mutation is
// exactly the exit-0 trap in its formal form.

void main() {
  group('the DONE line is the verdict', () {
    test('PASS', () {
      final outcome = SbyLogReader.parse(
        'SBY 11:02:24 [insn_add_ch0] DONE (PASS, rc=0)',
      );
      expect(outcome.verdict, RiscvFormalVerdict.pass);
      expect(outcome.returnCode, 0);
      expect(outcome.verdict.status, TestStatus.pass);
    });

    test('FAIL', () {
      final outcome = SbyLogReader.parse(
        'SBY 11:05:02 [insn_sub_ch0] DONE (FAIL, rc=2)',
      );
      expect(outcome.verdict, RiscvFormalVerdict.fail);
      expect(outcome.verdict.status, TestStatus.fail);
    });

    test('an older sby that prints no rc still parses', () {
      final outcome = SbyLogReader.parse('SBY [t] DONE (PASS)');
      expect(outcome.verdict, RiscvFormalVerdict.pass);
      expect(outcome.returnCode, isNull);
    });

    test('a log with no SBY prefix at all still parses', () {
      // A wrapper, a CI log scraper or a `tee` through another tool can
      // strip the banner. The verdict must survive that.
      expect(
        SbyLogReader.parse('DONE (FAIL, rc=2)').verdict,
        RiscvFormalVerdict.fail,
      );
    });

    test('an unrecognized DONE token is an ERROR, never a pass', () {
      final outcome = SbyLogReader.parse('SBY [t] DONE (WOBBLE, rc=99)');
      expect(outcome.verdict, RiscvFormalVerdict.error);
      expect(outcome.errorLine, contains('unrecognized outcome'));
    });
  });

  group('silence is not a pass — the sharpest trap', () {
    test('an empty log is NO_OUTCOME', () {
      expect(
        SbyLogReader.parse('').verdict,
        RiscvFormalVerdict.noOutcome,
      );
    });

    test('a truncated log that got as far as spawning is NO_OUTCOME', () {
      final outcome = SbyLogReader.parse('''
SBY 11:12:44 [liveness_ch0] engine_0: aiger suprove
SBY 11:12:46 [liveness_ch0] base: finished (returncode=0)
SBY 11:12:47 [liveness_ch0] engine_0: starting process "cd liveness_ch0; suprove model/design_aiger.aig"
''');
      expect(outcome.verdict, RiscvFormalVerdict.noOutcome);
      expect(outcome.verdict.status, TestStatus.fail);
    });

    test('NO_OUTCOME never maps to unknown or vacuous', () {
      // `unknown` would hand the verdict back to the driver's own exit
      // code — and a truncated run typically exits 0. `vacuous` is
      // success-equivalent to the scheduler: no retry, evidence deleted.
      final status = RiscvFormalVerdict.noOutcome.status;
      expect(status, TestStatus.fail);
      expect(status, isNot(TestStatus.unknown));
      expect(status, isNot(TestStatus.vacuous));
    });
  });

  group('an unproven property is never a pass', () {
    test('UNKNOWN is fail', () {
      expect(RiscvFormalVerdict.unknown.status, TestStatus.fail);
      expect(RiscvFormalVerdict.unknown.proved, isFalse);
    });

    test('TIMEOUT is fail — and deliberately not TestStatus.timeout', () {
      // `TestStatus.timeout` means SimCrux killed the job. An `sby`
      // TIMEOUT is the tool reporting, in an orderly way, that its own
      // solver budget expired. Conflating them makes one dashboard filter
      // mean two things.
      expect(RiscvFormalVerdict.timeout.status, TestStatus.fail);
      expect(RiscvFormalVerdict.timeout.status, isNot(TestStatus.timeout));
    });

    test('ERROR is fail', () {
      expect(RiscvFormalVerdict.error.status, TestStatus.fail);
    });

    test('only PASS is a pass, across the whole enum', () {
      for (final verdict in RiscvFormalVerdict.values) {
        expect(
          verdict.status,
          verdict == RiscvFormalVerdict.pass
              ? TestStatus.pass
              : TestStatus.fail,
          reason: verdict.wireName,
        );
        expect(verdict.status, isNot(TestStatus.unknown));
        expect(verdict.status, isNot(TestStatus.vacuous));
      }
    });
  });

  group('worst outcome wins', () {
    test('a multi-task log where one task failed is a fail', () {
      // One `sby` invocation over several tasks prints one DONE line each.
      // "One of them passed" is not a pass. The importer emits one test
      // per task so this is rare — but silence here would be wrong.
      final outcome = SbyLogReader.parse('''
SBY [a] DONE (PASS, rc=0)
SBY [b] DONE (FAIL, rc=2)
SBY [c] DONE (PASS, rc=0)
''');
      expect(outcome.verdict, RiscvFormalVerdict.fail);
    });

    test('a later PASS does not overwrite an earlier FAIL', () {
      expect(
        SbyLogReader.parse(
          'DONE (FAIL, rc=2)\nDONE (PASS, rc=0)\n',
        ).verdict,
        RiscvFormalVerdict.fail,
      );
    });
  });

  group('proof depth', () {
    test('the deepest reported step wins, not the last', () {
      final outcome = SbyLogReader.parse('''
SBY [t] engine_0: ##   0:00:00  Checking assertions in step 0..
SBY [t] engine_0: ##   0:00:03  Checking assertions in step 19..
SBY [t] engine_0.induction: ##   0:00:04  Trying induction in step 11..
SBY [t] DONE (PASS, rc=0)
''');
      expect(outcome.depthReached, 19);
    });

    test('null when the log said nothing about depth', () {
      expect(SbyLogReader.parse('DONE (ERROR, rc=16)').depthReached, isNull);
    });

    test('a `Reached bound` spelling counts too', () {
      expect(
        SbyLogReader.parse('engine_0: ## Reached bound 40').depthReached,
        40,
      );
    });
  });

  group('wall time and engine', () {
    test('clock time is read, process time is not', () {
      // Process time on a parallel engine exceeds wall time; reporting it
      // would make a proof look slower than it ran.
      final outcome = SbyLogReader.parse('''
SBY [t] summary: Elapsed clock time [H:MM:SS (secs)]: 0:00:07 (7)
SBY [t] summary: Elapsed process time [H:MM:SS (secs)]: 0:00:19 (19)
SBY [t] DONE (PASS, rc=0)
''');
      expect(outcome.elapsedSeconds, 7);
    });

    test('the engine comes from the summary line', () {
      final outcome = SbyLogReader.parse(
        'SBY [t] summary: engine_0 (smtbmc boolector) returned pass\n'
        'SBY [t] DONE (PASS, rc=0)',
      );
      expect(outcome.engine, 'smtbmc boolector');
    });

    test('and falls back to the announcement when there is no summary', () {
      final outcome = SbyLogReader.parse(
        'SBY [t] engine_0: abc pdr\nSBY [t] DONE (UNKNOWN, rc=4)',
      );
      expect(outcome.engine, 'abc pdr');
    });
  });

  group('traces — the hand-off to WaveCrux', () {
    test('the summary spelling is preferred over the engine spelling', () {
      // The summary line is sby's own final word and is relative to the
      // invocation directory; the engine's is relative to the task
      // directory. Mixing them would resolve to two different files.
      final outcome = SbyLogReader.parse('''
SBY [t] engine_0: ##  Writing trace to VCD file: engine_0/trace.vcd
SBY [t] summary: counterexample trace: insn_sub_ch0/engine_0/trace.vcd
SBY [t] DONE (FAIL, rc=2)
''');
      expect(outcome.traces, ['insn_sub_ch0/engine_0/trace.vcd']);
      expect(outcome.primaryTrace, 'insn_sub_ch0/engine_0/trace.vcd');
    });

    test('the engine spelling is used when no summary line arrived', () {
      final outcome = SbyLogReader.parse(
        'engine_0: ##  Writing trace to VCD file: engine_0/trace.vcd\n'
        'DONE (FAIL, rc=2)',
      );
      expect(outcome.traces, ['engine_0/trace.vcd']);
    });

    test('a cover run can announce several, in order', () {
      final outcome = SbyLogReader.parse('''
SBY [t] summary: cover trace: cover_ch0/engine_0/trace0.vcd
SBY [t] summary: cover trace: cover_ch0/engine_0/trace1.vcd
SBY [t] DONE (PASS, rc=0)
''');
      expect(outcome.traces, hasLength(2));
      expect(outcome.traces.last, endsWith('trace1.vcd'));
    });

    test('no trace announced means no trace', () {
      expect(SbyLogReader.parse('DONE (PASS, rc=0)').traces, isEmpty);
    });
  });

  group('the pass marker is the single point of agreement', () {
    test('it appears verbatim in a passing log', () {
      const log = 'SBY 11:02:24 [insn_add_ch0] DONE (PASS, rc=0)';
      // The `string_match` detector the importer emits searches for
      // exactly this literal. If the parser and the detector ever key off
      // different text, the driver and the detector can disagree.
      expect(log, contains(SbyLogReader.kPassMarker));
      expect(SbyLogReader.parse(log).verdict, RiscvFormalVerdict.pass);
    });

    test('it does NOT appear in any non-passing log', () {
      for (final token in const ['FAIL', 'UNKNOWN', 'ERROR', 'TIMEOUT']) {
        expect(
          'SBY [t] DONE ($token, rc=2)',
          isNot(contains(SbyLogReader.kPassMarker)),
          reason: token,
        );
      }
    });
  });

  group('line endings are not part of the verdict', () {
    // The corpus is checked out on ubuntu, macos AND windows runners, and
    // Git for Windows rewrites LF to CRLF by default. A verdict that
    // depended on the separator would make the same committed fixture
    // parse differently per platform — and it would fail *quietly*, as
    // NO_OUTCOME, which is a verdict the parser can legitimately reach.
    //
    // `.gitattributes` pins the corpora to LF; this is the other half, so
    // a log that arrives with CRLF anyway (a wrapper, a pasted capture, a
    // future fixture) still parses to the same thing.
    const elapsed =
        'SBY 11:09:13 [causal_ch0] summary: '
        'Elapsed clock time [H:MM:SS (secs)]: 0:00:01 (1)';
    const lines = [
      'SBY 11:09:13 [causal_ch0] engine_0: smtbmc boolector',
      "SBY 11:09:13 [causal_ch0] ERROR: Can't open input file `x.v'",
      elapsed,
      'SBY 11:09:13 [causal_ch0] DONE (ERROR, rc=16)',
    ];

    test('CRLF parses identically to LF', () {
      final lf = SbyLogReader.parse(lines.join('\n'));
      final crlf = SbyLogReader.parse(lines.join('\r\n'));
      expect(crlf.verdict, RiscvFormalVerdict.error);
      expect(crlf.verdict, isNot(RiscvFormalVerdict.noOutcome));
      expect(crlf, lf);
    });

    test('a CRLF log keeps its rc, engine, elapsed time and error line', () {
      // Not just the verdict: a stray `\r` riding on the end of a line
      // would survive into these strings and reach an exported report.
      final crlf = SbyLogReader.parse(lines.join('\r\n'));
      expect(crlf.returnCode, 16);
      expect(crlf.engine, 'smtbmc boolector');
      expect(crlf.elapsedSeconds, 1);
      expect(crlf.errorLine, isNot(contains('\r')));
      expect(crlf.errorLine, contains("Can't open input file"));
    });

    test('a CRLF-terminated file parses to the same outcome', () {
      // Trailing separator included — how the file actually looks on disk.
      expect(
        SbyLogReader.parse('${lines.join('\r\n')}\r\n'),
        SbyLogReader.parse('${lines.join('\n')}\n'),
      );
    });

    test('a lone-CR log is still split into lines', () {
      // The verdict alone is not enough to detect this: `split('\n')`
      // hands the whole blob over as ONE line, and the unanchored `DONE`
      // pattern still finds ERROR in it by luck. What does not survive is
      // everything that is anchored or line-scoped — so assert those.
      final cr = SbyLogReader.parse(lines.join('\r'));
      expect(cr.verdict, RiscvFormalVerdict.error);
      expect(cr.errorLine, isNotNull);
      expect(cr.errorLine, contains("Can't open input file"));
      expect(cr.errorLine, isNot(contains('DONE')));
      expect(cr.elapsedSeconds, 1);
    });
  });

  group('value semantics', () {
    test('equal outcomes compare and hash equal', () {
      const a = SbyOutcome(
        verdict: RiscvFormalVerdict.fail,
        returnCode: 2,
        traces: ['engine_0/trace.vcd'],
      );
      const b = SbyOutcome(
        verdict: RiscvFormalVerdict.fail,
        returnCode: 2,
        traces: ['engine_0/trace.vcd'],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a different trace list is a different outcome', () {
      const a = SbyOutcome(verdict: RiscvFormalVerdict.fail, traces: ['x']);
      const b = SbyOutcome(verdict: RiscvFormalVerdict.fail, traces: ['y']);
      expect(a, isNot(b));
    });
  });
}
