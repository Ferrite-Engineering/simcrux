// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/models/pass_fail_config.dart';

/// The longest failure message the scheduler derives from a log line.
///
/// A dashboard row, a JUnit `message` attribute and a PR annotation all want
/// one line; a 4 kB UVM report line is not that.
const int kDerivedFailureMessageMaxChars = 240;

/// The first line of a failed test's output that says why, or `null` when
/// nothing in it looks like a reason.
///
/// For a test that failed under a detector the user configured, the line
/// that detector fired on is the reason: the first line containing
/// `fail_string`, or matching `fail_pattern`. For the default `exit_code`
/// detector and for everything else, the first line that reads like an error
/// in the vocabularies the supported simulators and testbench frameworks
/// use: Icarus / Verilator `ERROR:` and `FATAL:`, `%Error`, UVM
/// `UVM_ERROR` / `UVM_FATAL`, a C or GHDL `error:`, an assertion, cocotb's
/// `FAIL` and a Python `Traceback`. Searched in [stderr] first, where
/// simulators put their diagnostics, then [stdout].
///
/// Bounded to [kDerivedFailureMessageMaxChars]. Never invented: a test that
/// failed with nothing that looks like a reason keeps a null message, and the
/// row says so by saying nothing, rather than quoting its last line as though
/// it were one.
String? firstFailingLine({
  required PassFailConfig config,
  required String stdout,
  required String stderr,
}) {
  final lines = <String>[
    ..._nonBlankLines(stderr),
    ..._nonBlankLines(stdout),
  ];
  if (lines.isEmpty) return null;

  String? pick(bool Function(String line) matches) {
    for (final line in lines) {
      if (matches(line)) return _bounded(line);
    }
    return null;
  }

  switch (config) {
    case StringMatchPassFailConfig(:final failString?):
      final found = pick((l) => l.contains(failString));
      if (found != null) return found;
    case RegexPassFailConfig(:final failPattern?):
      final RegExp regex;
      try {
        regex = RegExp(failPattern);
      } on FormatException {
        // The loader validated it; a pattern that still does not compile
        // falls through to the generic vocabulary.
        break;
      }
      final found = pick(regex.hasMatch);
      if (found != null) return found;
    default:
      break;
  }
  return pick(_looksLikeAnError.hasMatch);
}

/// The error vocabularies of the supported simulators and frameworks, at the
/// start of the line (after optional whitespace, a timestamp, `#`, or a GHDL
/// / GCC style `file:line:col:` location) so a `$display` that mentions the
/// word error mid-sentence is not a verdict.
final RegExp _looksLikeAnError = RegExp(
  r'^\s*(?:#\s*|\[[^\]]*\]\s*|\d+(?:\.\d+)?\s*[a-z]*s?\s+|'
  r'\S+:\d+(?::\d+)?:\s*)*'
  r'(?:ERROR\b|FATAL\b|%Error|%Fatal|UVM_ERROR|UVM_FATAL|error:|fatal:|'
  r'Error:|Fatal:|Assertion\b|assert(?:ion)? failed|FAIL(?:ED|URE)?\b|'
  r'Traceback \(most recent call last\))',
);

Iterable<String> _nonBlankLines(String text) => text
    .split('\n')
    .map((l) => l.trimRight())
    .where((l) => l.trim().isNotEmpty);

String _bounded(String line) {
  final trimmed = line.trim();
  if (trimmed.length <= kDerivedFailureMessageMaxChars) return trimmed;
  return '${trimmed.substring(0, kDerivedFailureMessageMaxChars - 1)}…';
}
