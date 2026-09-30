// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for the Crux suite's clinical-comment convention.
// Canonical spec: the "Comment Hygiene" section of both CLAUDE.md files.
// Identical copies of this test live in the core repo and the Pro overlay.
//
// A comment must describe the code as it stands, for a reader who has no
// access to the development process that produced it. Four classes of prose
// fail that test and are rejected here:
//
//  1. Backlog / track identifiers used as anchors. A quality-round row id is
//     deleted when the round closes, so a comment anchored to one becomes
//     unreadable. This includes cross-repo issue / PR numbers (`issue #NN`),
//     which resolve only against a tracker the code reader has no access to.
//     Section marks of a document published with the code (`ARCHITECTURE.md`,
//     the verification guide, a public specification URL) are NOT in this
//     class — the reference stays resolvable for every reader. Plans and
//     trackers that are not published are, and
//     `no_private_references_test.dart` rejects them in every tracked file.
//  2. Dates used as process notes. A stamp narrating when work happened
//     carries no information about the code. Dates that are data — licence
//     headers, fixture payloads, format examples — are unaffected.
//  3. Session / process voice. Prose scoped to the sitting that wrote it
//     ("this round", "for now", person-addressed TODOs) expires immediately
//     and cannot be evaluated later.
//  4. Reviewer voice. A comment addressed to someone reading the change,
//     rather than to someone reading the code, is misfiled — that content
//     belongs in the commit message.
//
// Scope: classes 1–4 over `lib/`; class 1 alone over `test/` and
// `integration_test/`, where the identifier-anchor defect has recurred but
// change-narration in a test's own docstring is legitimate.
//
// Only comment text is examined. String literals are skipped by the scanner,
// so identifier-shaped domain data (source-location fragments, state names,
// fixture strings) cannot trigger a finding, and the patterns written below
// do not match themselves.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Directories scanned for every class.
const _fullScanRoots = ['lib'];

/// Directories scanned for the identifier-anchor class only.
const _identifierScanRoots = ['lib', 'test', 'integration_test'];

/// Files exempt from every class, keyed by path suffix, each with the reason
/// it cannot be cleaned. Kept empty deliberately: an entry here is a permanent
/// hole in the guard, so a violation is fixed rather than listed.
const Map<String, String> _allowlist = {};

/// Round identifiers: a two-letter product prefix plus a row number. Bare
/// match — no such token has a legitimate meaning in this codebase. `CS` is
/// the crux-shared round prefix.
final _roundIdRe = RegExp(r'\b(?:NC|WC|LC|SC|CS)\d{1,2}\b');

/// Track identifiers: a single-letter prefix plus a number. Matched only
/// behind a backlog-reference marker, because the bare form collides with
/// real domain vocabulary — FSM state names, source-line fragments, cache
/// levels, algorithm versions. `A`/`B` are the suite migration-track
/// prefixes.
final _trackIdRe = RegExp(
  r'''(?:§|\bitems?[ -]|\btracks?[ -]|\bprompts?[ -]|\bbacklog[ -])'''
  r'[ABGNWLSX]\d{1,2}\b',
);

/// Prose forms of the same anchor, which name a backlog without an id.
final _backlogProseRe = RegExp(
  r'\bbacklog (?:item|anchor|row)\b|\bper the batch\b|'
  r'\btracked in PENDING\b|\bexecution prompt\b',
  caseSensitive: false,
);

/// Cross-repo tracker anchors: an `issue`/`PR`/`ticket` reference plus a
/// number. Scoped to those nouns so a legitimate ordinal in a comment
/// (`driver #5`) is not mistaken for a tracker citation.
final _issueAnchorRe = RegExp(
  r'\b(?:issues?|PRs?|pull requests?|tickets?)\s+#?\d+\b',
  caseSensitive: false,
);

/// Process-note dates. Any calendar date in a comment; the licence-header
/// carve-out below is the only exemption.
final _dateRe = RegExp(
  r'\b(?:19|20)\d{2}-\d{2}-\d{2}\b|'
  r'\b(?:January|February|March|April|May|June|July|August|September|'
  r'October|November|December)\s+\d{1,2},\s*(?:19|20)\d{2}\b',
);

/// Markers that identify a comment as a licence or copyright header, where a
/// date is a required part of the notice rather than a process note.
final _licenceHeaderRe = RegExp(
  r'\bCopyright\b|\bSPDX-|\bLicensed under\b|\bAll rights reserved\b',
  caseSensitive: false,
);

/// Session / process voice. "session" is matched only behind a preposition:
/// bare "this session" is domain vocabulary here — a saved workspace session
/// is a first-class model.
final _sessionVoiceRe = RegExp(
  r'\b(?:in|during|from|since) this session\b|'
  r'\bthis (?:round|batch|sweep)\b|\bfor now\b|'
  r'\bas discussed\b|\bwe decided\b|\bnote to self\b|'
  r'\bat the time of writing\b|\bas of (?:today|this writing)\b|'
  r'\bTODO\((?:martin|mfink|me|self)\)',
  caseSensitive: false,
);

/// Reviewer voice. First-person-plural change narration is included; bare
/// "we" is not, because it reads naturally in design rationale.
final _reviewerVoiceRe = RegExp(
  r'\bas you can see\b|\bnote that we\b|\bto the reviewer\b|'
  r'\breviewer note\b|\bin this (?:commit|PR|pull request|patch|diff|'
  r'changeset)\b|\b(?:before|after) this change\b|'
  r'\bwe (?:added|removed|changed|renamed|moved|introduced|reverted)\b|'
  r"\bI (?:added|removed|kept|decided)\b|\blet's\b|\bdon't forget\b|"
  r'\bper the review\b',
  caseSensitive: false,
);

/// A comment occurrence: the 1-based line it starts on and its raw text.
class _Comment {
  const _Comment(this.line, this.text);

  final int line;
  final String text;
}

/// Extracts every comment from [source], skipping string literals so that
/// quoted data is never mistaken for prose.
List<_Comment> _extractComments(String source) {
  final comments = <_Comment>[];
  var line = 1;
  var i = 0;
  while (i < source.length) {
    final c = source[i];
    if (c == '\n') {
      line++;
      i++;
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '/') {
      final nl = source.indexOf('\n', i);
      final end = nl == -1 ? source.length : nl;
      comments.add(_Comment(line, source.substring(i, end)));
      i = end;
      continue;
    }
    if (c == '/' && i + 1 < source.length && source[i + 1] == '*') {
      final startLine = line;
      final close = source.indexOf('*/', i + 2);
      final end = close == -1 ? source.length : close + 2;
      final text = source.substring(i, end);
      comments.add(_Comment(startLine, text));
      line += '\n'.allMatches(text).length;
      i = end;
      continue;
    }
    if (c == "'" || c == '"') {
      final before = i;
      i = _skipString(source, i);
      line += '\n'.allMatches(source.substring(before, i)).length;
      continue;
    }
    i++;
  }
  return comments;
}

/// Advances past the string literal starting at [start] (its opening quote),
/// honouring raw prefixes, triple quotes, and backslash escapes.
int _skipString(String source, int start) {
  final quote = source[start];
  final isRaw = start > 0 && source[start - 1] == 'r';
  final triple = source.startsWith(quote * 3, start);
  final delimiter = triple ? quote * 3 : quote;
  var i = start + delimiter.length;
  while (i < source.length) {
    if (!isRaw && source[i] == r'\') {
      i += 2;
      continue;
    }
    if (source.startsWith(delimiter, i)) return i + delimiter.length;
    // An unterminated single-quoted literal cannot cross a line; bail out so
    // a malformed file degrades into over-scanning rather than swallowing the
    // rest of the source.
    if (!triple && source[i] == '\n') return i;
    i++;
  }
  return source.length;
}

List<File> _dartFilesUnder(Iterable<String> roots) {
  final files = <File>[];
  for (final root in roots) {
    final dir = Directory(root);
    if (!dir.existsSync()) continue;
    files.addAll(
      dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          // Generated output is not hand-written prose and is rewritten by
          // build_runner / gen-l10n on every codegen run.
          .where((f) => !f.path.endsWith('.g.dart'))
          .where((f) => !f.path.endsWith('.freezed.dart'))
          .where((f) => !p.split(f.path).contains('generated')),
    );
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

bool _isAllowlisted(String relativePath) =>
    _allowlist.keys.any(relativePath.endsWith);

/// Runs [pattern] over every comment in [roots] and returns `path:line —
/// matched text` for each hit.
List<String> _scan(
  Iterable<String> roots,
  RegExp pattern, {
  bool Function(String commentText)? exempt,
}) {
  final offenders = <String>[];
  for (final file in _dartFilesUnder(roots)) {
    final relative = p.relative(file.path);
    if (_isAllowlisted(relative)) continue;
    for (final comment in _extractComments(file.readAsStringSync())) {
      if (exempt != null && exempt(comment.text)) continue;
      final match = pattern.firstMatch(comment.text);
      if (match == null) continue;
      offenders.add('$relative:${comment.line} — "${match.group(0)}"');
    }
  }
  return offenders;
}

void main() {
  test('no backlog or track identifiers used as comment anchors', () {
    final offenders = [
      ..._scan(_identifierScanRoots, _roundIdRe),
      ..._scan(_identifierScanRoots, _trackIdRe),
      ..._scan(_identifierScanRoots, _backlogProseRe),
      ..._scan(_identifierScanRoots, _issueAnchorRe),
    ]..sort();
    expect(
      offenders,
      isEmpty,
      reason:
          'A comment anchors on a backlog or track identifier. Those rows are '
          'deleted when the round closes, leaving the comment unreadable. '
          'State what the code does and why; cite a document published with '
          'the code if an external reference is genuinely needed.\n'
          '${offenders.join('\n')}',
    );
  });

  test('no dates used as process notes in comments', () {
    final offenders = _scan(
      _fullScanRoots,
      _dateRe,
      exempt: _licenceHeaderRe.hasMatch,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'A comment carries a date narrating when work happened. When the '
          'work was done is recorded by git; the comment should record what '
          'the code does.\n${offenders.join('\n')}',
    );
  });

  test('no session or process voice in comments', () {
    final offenders = _scan(_fullScanRoots, _sessionVoiceRe);
    expect(
      offenders,
      isEmpty,
      reason:
          'A comment is scoped to the sitting that wrote it. Such prose '
          'cannot be evaluated by a later reader — describe the state of the '
          'code, not the state of the work.\n${offenders.join('\n')}',
    );
  });

  test('no reviewer voice in comments', () {
    final offenders = _scan(_fullScanRoots, _reviewerVoiceRe);
    expect(
      offenders,
      isEmpty,
      reason:
          'A comment addresses a reader of the change rather than a reader of '
          'the code. Change narration belongs in the commit message.\n'
          '${offenders.join('\n')}',
    );
  });
}
