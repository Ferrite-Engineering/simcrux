// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Aggregate counts parsed from a UVM testbench's stdout.
///
/// UVM (Universal Verification Methodology, Accellera IEEE 1800.2)
/// emits per-message lines and a summary table near end-of-simulation.
/// Per-message lines look like:
///
///     UVM_INFO @ 0: reporter [RNTST] Running test test_dut::randomized_burst...
///     UVM_WARNING tb.dut.sv(42) @ 12 ns: reporter [SCRBD] Scoreboard X
///     UVM_ERROR tb.dut.sv(73) @ 24 ns: reporter [CHKR] expected 0x42, got 0x41
///     UVM_FATAL tb.env.sv(15) @ 30 ns: reporter [BUILD] missing config object
///
/// The end-of-test summary looks like:
///
///     --- UVM Report Summary ---
///
///     ** Report counts by severity
///     UVM_INFO :   42
///     UVM_WARNING :    1
///     UVM_ERROR :    2
///     UVM_FATAL :    0
///
/// The parser prefers the summary table when present (one read, no
/// double-counting per-message and per-summary), falling back to
/// counting per-message lines when only those are emitted (e.g.
/// when the testbench was killed before reaching the summary block).
class UvmReportCounts {
  /// Creates a [UvmReportCounts].
  const UvmReportCounts({
    required this.info,
    required this.warning,
    required this.error,
    required this.fatal,
    required this.source,
  });

  /// Zero count (used as the "no UVM signal seen" sentinel).
  static const UvmReportCounts empty = UvmReportCounts(
    info: 0,
    warning: 0,
    error: 0,
    fatal: 0,
    source: UvmReportCountSource.none,
  );

  /// `UVM_INFO` count.
  final int info;

  /// `UVM_WARNING` count.
  final int warning;

  /// `UVM_ERROR` count.
  final int error;

  /// `UVM_FATAL` count.
  final int fatal;

  /// Where the counts came from. Surfaced so callers can downgrade
  /// confidence when the summary table was absent and only
  /// per-message lines were available.
  final UvmReportCountSource source;

  /// True when at least one UVM-shaped line was seen — used to gate
  /// the detector's "no signal" branch.
  bool get hasAnySignal => source != UvmReportCountSource.none;
}

/// How the counts were derived.
enum UvmReportCountSource {
  /// Neither the summary table nor any per-message UVM line was found.
  none,

  /// Counts came from the `--- UVM Report Summary ---` table.
  summary,

  /// Counts came from scanning per-message `UVM_INFO` /
  /// `UVM_WARNING` / `UVM_ERROR` / `UVM_FATAL` lines.
  perMessage,
}

/// Parses [text] (typically stdout, optionally concatenated with
/// stderr) into a [UvmReportCounts].
///
/// Behavior:
/// - If the `--- UVM Report Summary ---` block is present, uses its
///   per-severity counts and ignores per-message lines (the summary
///   is authoritative).
/// - Otherwise, scans every line for `UVM_INFO` / `UVM_WARNING` /
///   `UVM_ERROR` / `UVM_FATAL` prefixes and counts each occurrence.
/// - When neither is found, returns [UvmReportCounts.empty].
UvmReportCounts parseUvmReport(String text) {
  final summary = _parseSummaryTable(text);
  if (summary != null) return summary;
  return _countPerMessageLines(text);
}

UvmReportCounts? _parseSummaryTable(String text) {
  // Locate the summary header. The exact decoration varies across UVM
  // versions ("--- UVM Report Summary ---" with leading/trailing
  // hyphens; sometimes inside a `** ` decoration). Match generously.
  final headerRe = RegExp(
    r'-+\s*UVM\s+Report\s+Summary\s*-+',
    caseSensitive: false,
  );
  final header = headerRe.firstMatch(text);
  if (header == null) return null;

  final body = text.substring(header.end);
  // Limit body to a reasonable window so a runaway log doesn't make
  // us scan megabytes searching for the four count lines.
  final tail = body.length > 4096 ? body.substring(0, 4096) : body;

  final infoRe = RegExp(r'UVM_INFO\s*:\s*(\d+)', caseSensitive: false);
  final warnRe = RegExp(r'UVM_WARNING\s*:\s*(\d+)', caseSensitive: false);
  final errRe = RegExp(r'UVM_ERROR\s*:\s*(\d+)', caseSensitive: false);
  final fatRe = RegExp(r'UVM_FATAL\s*:\s*(\d+)', caseSensitive: false);

  final info = int.tryParse(infoRe.firstMatch(tail)?.group(1) ?? '');
  final warn = int.tryParse(warnRe.firstMatch(tail)?.group(1) ?? '');
  final err = int.tryParse(errRe.firstMatch(tail)?.group(1) ?? '');
  final fat = int.tryParse(fatRe.firstMatch(tail)?.group(1) ?? '');

  // At least one of the four count lines must be present for the
  // summary block to be considered valid; otherwise fall through to
  // per-message counting so we don't return an all-zero summary just
  // because the header text appeared somewhere.
  if (info == null && warn == null && err == null && fat == null) return null;

  return UvmReportCounts(
    info: info ?? 0,
    warning: warn ?? 0,
    error: err ?? 0,
    fatal: fat ?? 0,
    source: UvmReportCountSource.summary,
  );
}

UvmReportCounts _countPerMessageLines(String text) {
  // Per-message UVM lines start with the severity token followed by a
  // space, `@`, file path, or paren. Examples:
  //   UVM_INFO @ 0: reporter [RNTST] …
  //   UVM_WARNING tb.sv(42) @ 12 ns: …
  //   UVM_ERROR  : custom-formatter omitting whitespace separator
  // Match the prefix `^UVM_<SEV>` permissively but require a
  // non-identifier follower so `UVM_INFOXY` is not counted.
  final lineRe = RegExp(
    r'(?:^|\n)UVM_(INFO|WARNING|ERROR|FATAL)(?=[^A-Za-z0-9_])',
  );
  var info = 0;
  var warn = 0;
  var err = 0;
  var fat = 0;
  for (final m in lineRe.allMatches(text)) {
    switch (m.group(1)) {
      case 'INFO':
        info++;
      case 'WARNING':
        warn++;
      case 'ERROR':
        err++;
      case 'FATAL':
        fat++;
    }
  }
  final saw = info + warn + err + fat;
  if (saw == 0) return UvmReportCounts.empty;
  return UvmReportCounts(
    info: info,
    warning: warn,
    error: err,
    fatal: fat,
    source: UvmReportCountSource.perMessage,
  );
}
