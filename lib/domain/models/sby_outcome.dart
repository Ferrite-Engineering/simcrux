// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/riscv_formal_verdict.dart';

/// What one SymbiYosys run reported, distilled from its log.
///
/// Pure and I/O-free, in `domain/` for the same reason `GoldenComparator`
/// is: **two callers have to agree by construction.** The `riscv_formal`
/// driver classifies from this, and the `string_match` detector the
/// importer emits keys off [SbyLogReader.kPassMarker] — the same literal
/// this parser recognizes. If the marker ever moves, both halves move
/// together (the same single-definition argument `GoldenComparator` makes,
/// applied to a log instead of a signature).
///
/// Parsing the log rather than trusting the exit code is deliberate.
/// `sby`'s return codes are meaningful, but a run can exit 0 having
/// produced no verdict at all, and "exit 0 ⇒ pass" is precisely how an
/// unproven property reads green. The log's `DONE (…)` line is
/// `sby` stating its own conclusion; the exit code is a summary of it.
@immutable
class SbyOutcome {
  /// Creates an [SbyOutcome].
  const SbyOutcome({
    required this.verdict,
    this.returnCode,
    this.depthReached,
    this.engine,
    this.elapsedSeconds,
    this.traces = const <String>[],
    this.errorLine,
  });

  /// What `sby` concluded. [RiscvFormalVerdict.noOutcome] when the log
  /// carried no `DONE (…)` line.
  final RiscvFormalVerdict verdict;

  /// The `rc=` value from the `DONE (…)` line, when present. Recorded for
  /// provenance; it is **not** what the verdict is derived from.
  final int? returnCode;

  /// The deepest step index the engine reported reaching, or null when
  /// the log said nothing about depth.
  ///
  /// Zero-based, matching `sby`'s own "step N" numbering: a BMC run over
  /// `depth 20` reports steps 0..19, so a completed run reads 19.
  final int? depthReached;

  /// The engine specification `sby` used, e.g. `smtbmc boolector`.
  final String? engine;

  /// `sby`'s own "Elapsed clock time" in seconds, when it reported one.
  ///
  /// Preferred over a stopwatch around the subprocess because it is the
  /// **proof's** wall time rather than the job's, and because it replays
  /// honestly in demo mode — a stopwatch there would report the
  /// milliseconds it took to read a committed log.
  final int? elapsedSeconds;

  /// Trace files `sby` announced, exactly as it spelled them — usually
  /// relative to the task directory (`engine_0/trace.vcd`).
  ///
  /// Resolution to an absolute, existing path is the driver's job; this
  /// class does no I/O.
  final List<String> traces;

  /// The first `ERROR:` line, when one appeared. Used for the failure
  /// message on [RiscvFormalVerdict.error].
  final String? errorLine;

  /// The counterexample trace, or null when none was announced.
  String? get primaryTrace => traces.isEmpty ? null : traces.first;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SbyOutcome &&
        other.verdict == verdict &&
        other.returnCode == returnCode &&
        other.depthReached == depthReached &&
        other.engine == engine &&
        other.elapsedSeconds == elapsedSeconds &&
        other.errorLine == errorLine &&
        _listEquals(other.traces, traces);
  }

  @override
  int get hashCode => Object.hash(
    verdict,
    returnCode,
    depthReached,
    engine,
    elapsedSeconds,
    errorLine,
    Object.hashAll(traces),
  );

  @override
  String toString() =>
      'SbyOutcome(${verdict.wireName}, rc: $returnCode, '
      'depth: $depthReached, traces: ${traces.length})';

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Incremental, pure reader that turns a stream of SymbiYosys log lines
/// into an [SbyOutcome].
///
/// Incremental on purpose: the driver feeds it from
/// `runProcessStreaming`'s `onLine` hook in `mode: normal` and feeds it
/// the committed log line by line in `mode: demo`, so **both modes run
/// the identical parser over identically-shaped text**. That is what
/// makes the demo-mode tests evidence about the production path rather
/// than about a second implementation.
///
/// Every line `sby` prints is prefixed `SBY <time> [<task>] `; the reader
/// strips that prefix when it is present and is tolerant of its absence,
/// so a log captured through a wrapper still parses.
class SbyLogReader {
  /// Creates a reader with no lines seen yet.
  SbyLogReader();

  /// The literal that means "this proof passed", and the **single point
  /// of agreement** between this parser and the `string_match` detector
  /// the importer emits as `pass_string`.
  ///
  /// Deliberately the open paren and not the whole `DONE (PASS, rc=0)`:
  /// older `sby` builds print `DONE (PASS)` with no return code.
  static const String kPassMarker = 'DONE (PASS';

  /// `SBY 12:34:56 [insn_add_ch0] ` — the per-line prefix.
  ///
  /// The timestamp is optional in the pattern: `sby` always prints one,
  /// but a log replayed through a CI scraper or a `tee` wrapper may not,
  /// and the anchored patterns below would then stop matching.
  static final RegExp _prefix = RegExp(r'^SBY\s+(?:\S+\s+)?\[[^\]]*\]\s*');

  /// `DONE (PASS, rc=0)` / `DONE (FAIL, rc=2)` / `DONE (UNKNOWN)`.
  static final RegExp _done = RegExp(
    r'DONE\s*\(\s*([A-Za-z_]+)\s*(?:,\s*rc\s*=\s*(-?\d+)\s*)?\)',
  );

  /// `engine_0: ##   0:00:04  Checking assertions in step 19..`, plus the
  /// induction and bound spellings. All of them carry a step number, and
  /// the deepest one seen is the depth actually reached.
  static final RegExp _step = RegExp(
    '(?:Checking assertions in step|Checking assumptions in step|'
    r'Trying induction in step|Solving for step|Reached bound)\s+(\d+)',
  );

  /// `summary: engine_0 (smtbmc boolector) returned pass`.
  static final RegExp _engineSummary = RegExp(
    r'summary:\s*engine_\d+\s*\(([^)]*)\)\s*returned',
  );

  /// `engine_0: smtbmc boolector` — the engine announcement, used only
  /// when the summary line never arrived.
  static final RegExp _engineAnnounce = RegExp(
    r'^engine_\d+:\s*((?:smtbmc|abc|aiger|btor|none)\b.*)$',
  );

  /// `summary: Elapsed clock time [H:MM:SS (secs)]: 0:00:07 (7)`.
  ///
  /// Anchored on the **trailing** parenthesized figure rather than on the
  /// `[H:MM:SS (secs)]` label, which itself contains colons and
  /// parentheses and differs between `sby` versions. Deliberately
  /// "clock", not "process": process time on a parallel engine exceeds
  /// wall time and would read as a slower proof than actually ran.
  static final RegExp _elapsed = RegExp(
    r'Elapsed clock time.*?\(\s*(\d+)\s*\)\s*$',
  );

  /// `##   0:00:01  Writing trace to VCD file: engine_0/trace.vcd` and
  /// `summary: counterexample trace: insn_add_ch0/engine_0/trace.vcd`.
  static final RegExp _traceWritten = RegExp(
    r'Writing trace to VCD file:\s*(\S+)',
  );
  static final RegExp _traceSummary = RegExp(
    r'summary:\s*(?:counterexample|cover)\s+trace:\s*(\S+)',
  );

  RiscvFormalVerdict? _verdict;
  int? _returnCode;
  int? _depth;
  String? _engine;
  String? _engineFallback;
  int? _elapsedSeconds;
  String? _errorLine;
  final List<String> _written = <String>[];
  final List<String> _summarized = <String>[];

  /// Feeds one log line. Safe to call for stderr lines too — `sby` writes
  /// its banner to stdout, but a wrapper may merge the pipes.
  void addLine(String raw) {
    final line = raw.replaceFirst(_prefix, '').trimRight();
    if (line.isEmpty) return;

    final done = _done.firstMatch(line);
    if (done != null) {
      final parsed = RiscvFormalVerdict.fromWireName(done.group(1));
      final rc = int.tryParse(done.group(2) ?? '');
      // Worst outcome wins. A multi-task `.sby` prints one DONE line per
      // task, and "one of several proofs passed" is not a pass. The
      // importer emits one test per task precisely so this rarely
      // matters — but when it does, silence would be the wrong answer.
      if (parsed != null && _isWorseThanCurrent(parsed)) {
        _verdict = parsed;
        _returnCode = rc;
      } else if (parsed == null && _isWorseThanCurrent(null)) {
        _verdict = RiscvFormalVerdict.error;
        _returnCode = rc;
        _errorLine ??= 'sby reported an unrecognized outcome: $line';
      }
    }

    final step = _step.firstMatch(line);
    if (step != null) {
      final value = int.tryParse(step.group(1)!);
      if (value != null && (_depth == null || value > _depth!)) {
        _depth = value;
      }
    }

    final engine = _engineSummary.firstMatch(line);
    if (engine != null) _engine ??= engine.group(1)!.trim();
    final announce = _engineAnnounce.firstMatch(line);
    if (announce != null) _engineFallback ??= announce.group(1)!.trim();

    final elapsed = _elapsed.firstMatch(line);
    if (elapsed != null) _elapsedSeconds ??= int.tryParse(elapsed.group(1)!);

    final written = _traceWritten.firstMatch(line);
    if (written != null && !_written.contains(written.group(1))) {
      _written.add(written.group(1)!);
    }
    final summarized = _traceSummary.firstMatch(line);
    if (summarized != null && !_summarized.contains(summarized.group(1))) {
      _summarized.add(summarized.group(1)!);
    }

    if (_errorLine == null && line.startsWith('ERROR:')) {
      _errorLine = line;
    }
  }

  /// Whether [candidate] should replace the verdict recorded so far.
  ///
  /// `pass` never overwrites a non-`pass`; anything else does. Null means
  /// "an unparseable DONE token", which is at least an error.
  bool _isWorseThanCurrent(RiscvFormalVerdict? candidate) {
    final current = _verdict;
    if (current == null) return true;
    if (candidate == RiscvFormalVerdict.pass) return false;
    return current == RiscvFormalVerdict.pass;
  }

  /// The outcome distilled from everything fed so far.
  ///
  /// Returns [RiscvFormalVerdict.noOutcome] when no `DONE (…)` line was
  /// ever seen — which the driver treats as a failure regardless of the
  /// process's exit code.
  SbyOutcome get outcome => SbyOutcome(
    verdict: _verdict ?? RiscvFormalVerdict.noOutcome,
    returnCode: _returnCode,
    depthReached: _depth,
    engine: _engine ?? _engineFallback,
    elapsedSeconds: _elapsedSeconds,
    // `summary: counterexample trace:` lines are `sby`'s own final word
    // and are spelled relative to the invocation directory; the
    // `Writing trace to VCD file:` lines are the engine's and are
    // relative to the task directory. Prefer the summary, fall back to
    // the engine's.
    traces: List<String>.unmodifiable(
      _summarized.isNotEmpty ? _summarized : _written,
    ),
    errorLine: _errorLine,
  );

  /// Convenience for tests, tools and demo replay of an already-captured
  /// blob. The incremental path is what production uses.
  ///
  /// Splits with [LineSplitter] — the *same* splitter the driver's demo
  /// replay feeds [addLine] from — rather than `split('\n')`, so a log
  /// captured on Windows (CRLF) or through a wrapper is cut into exactly
  /// the same lines here as in production. [addLine] already trims the
  /// stray `\r` a naive split would leave behind; this closes the other
  /// half, a lone `\r`.
  static SbyOutcome parse(String log) {
    final reader = SbyLogReader();
    const LineSplitter().convert(log).forEach(reader.addLine);
    return reader.outcome;
  }
}
