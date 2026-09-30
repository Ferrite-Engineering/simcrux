// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: nothing in this public repository points at a private
// repository or at a planning document only the maintainers can read.
//
// SimCrux open core is published. The suite's planning repository, the Pro
// overlays, the marketing sites, the update and commerce services, and every
// plan, campaign, charter and tracker kept in them are not. A reference to one
// of them is a dead end for every reader of this repository — a comment whose
// reasoning lives somewhere the reader cannot go explains nothing — and it
// names internal structure that has no business in a public tree.
//
// So every tracked text file is scanned: code, tests, fixtures, ARB files,
// workflows, user documentation, the engineering manual and the verification
// guide. Tracked, because `git ls-files` is exactly what a clone receives;
// untracked scratch files and build output are not published and are not this
// guard's business. The `crux-shared` submodule is scanned by crux-shared's
// own copy of this guard.
//
// What is NOT a finding: the public repositories (`wavecrux`, `netcrux`,
// `lintcrux`, `simcrux`, `crux-shared`, `crux-vscode`, `edacrux-edu-packs`,
// `wavecrux-sigrok-bridge`), public URLs (`https://edacrux.app/cxp`,
// `https://docs.simcrux.app/...`), section marks of documents published with
// the code (`docs/ARCHITECTURE.md`, `verification/VERIFICATION_GUIDE.md`,
// the CXP specification), and the shipped Pro executable and app identifiers
// in the allowlist below.
//
// When this fails, do not respell the pointer. State the reason inline in
// present tense, link the public page that carries it, or delete the pointer
// if it only said "see the other document".

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// One family of private reference and the pattern that finds it.
class _Rule {
  const _Rule(this.name, this.pattern, this.fix);

  final String name;
  final RegExp pattern;

  /// What to do instead, printed with every finding.
  final String fix;
}

final _rules = <_Rule>[
  _Rule(
    'private repository path',
    // `edacrux/docs/...` and `../edacrux/...`, but not the deployed policy
    // location `/etc/edacrux/` or the public `edacrux.app` / `edacrux-*` names.
    RegExp(r'(?<![\w.\-/])edacrux/|\.\./edacrux/'),
    'the planning repository is private; state the reason inline or link '
        'the public page on https://edacrux.app',
  ),
  _Rule(
    'private Pro overlay repository',
    RegExp(
      r'\b(?:wavecrux|netcrux|lintcrux|simcrux)[-_]pro\b',
      caseSensitive: false,
    ),
    'say "the Pro overlay"; describe the seam, not the private path',
  ),
  _Rule(
    'private website repository',
    RegExp(
      r'\b(?:wavecrux|netcrux|lintcrux|simcrux|edacrux|ferrite)-website\b',
      caseSensitive: false,
    ),
    'user documentation lives in docs-site/; link https://docs.simcrux.app',
  ),
  _Rule(
    'private service or product repository',
    RegExp(
      r'\b(?:crux-updates|crux-commerce|wavecrux-updates|pulsecrux|vcd_parser|anneal)\b'
      // The beta repos close at the open-core flip (L4), so a
      // reference to one is a link that dies on flip day.
      r'|\b(?:wavecrux|netcrux|lintcrux|simcrux)-beta\b',
      caseSensitive: false,
    ),
    'name the public endpoint or behaviour, not the private repository',
  ),
  _Rule(
    'private repository in prose',
    RegExp(
      r'\b(?:private|planning) (?:planning |docs? )?repo(?:sitory)?\b|'
      r"\bthe docs repo\b|\b(?:website|marketing[- ]site)(?:'s)? repo(?:sitory)?\b",
      caseSensitive: false,
    ),
    'state the reason inline; a reader cannot follow the pointer',
  ),
  _Rule(
    'private planning document',
    RegExp(
      'RISCV_ECOSYSTEM_PLAN|ENGINE_BUNDLING_GATE|UI_CONSISTENCY_CHARTER|'
      r'ecosystem-plan\.md|project-plan\.md|commercial-launch-plan',
    ),
    'state the decision and its reason inline',
  ),
  _Rule(
    'plan citation',
    RegExp(
      r'\b(?:project|suite|strategic|ecosystem|commercial[- ]launch|business|'
      r'robustness(?: (?:&|and) performance)?) plan\b|\bplan\s*§',
      caseSensitive: false,
    ),
    'state the reason inline; plans are not published',
  ),
  _Rule(
    'plan phase or track',
    RegExp(r'\bPhase[- ]\d+(?:\.\d+)?\b|\bTrack [A-Z]\b'),
    'describe the feature, not the plan phase that scheduled it',
  ),
  _Rule(
    'charter or ruling',
    RegExp(
      r'\bconsistency charter\b|\bcharter\s*§|\brulings?\b',
      caseSensitive: false,
    ),
    'state the convention and why it holds',
  ),
  _Rule(
    'prompt reference',
    RegExp(
      r'\bexecution prompts?\b|\bprompt set\b|\bPrompt \d+\b',
      caseSensitive: false,
    ),
    'describe the code, not the prompt that produced it',
  ),
  _Rule(
    'tracking id',
    RegExp(
      r'\bWS-[A-Z]\b|\bWS\d+\b|\bF-\d{1,3}\b|\b(?:CS|SC|NC|WC|LC)\d{1,2}\b|'
      r'\bR-CS\d*\b|\bIssue-\d+\b|'
      r'\((?:[ABFGLNPSWX]|MD)\d{1,2}(?:[,/ ]+(?:[ABFGLNPSWX]|MD)\d{1,2})*\)',
    ),
    'tracker rows are private and deleted when closed; describe the behaviour',
  ),
  _Rule(
    'issue number',
    RegExp(r'\bissues? #\d+\b|\bitem #\d+\b', caseSensitive: false),
    'describe the defect; a bare number resolves against no public tracker',
  ),
  _Rule(
    'beta bug id',
    RegExp(
      r'\bbeta[- ]bug [A-Z]\d{1,2}\b|\bbeta-[A-Z]\d{1,2}\b|\bbeta [A-Z]\d{1,2}\b',
      caseSensitive: false,
    ),
    'describe the defect the test pins, not its tracker id',
  ),
  _Rule(
    'audit finding id',
    RegExp(
      r"\baudit(?:'s)? (?:item |finding )?[A-Z]{1,2}-?\d{1,3}\b",
      caseSensitive: false,
    ),
    'describe the defect class, not the private audit row',
  ),
  _Rule(
    'campaign',
    RegExp(r'\bcampaigns?\b', caseSensitive: false),
    'campaigns are private work tracking; describe the code',
  ),
  _Rule(
    'personal path',
    RegExp(r'/Users/mfink\b|~/Develop(?:er|ment)/'),
    'use a repository-relative path',
  ),
];

/// A legitimate occurrence of a private-looking name, pinned to the exact
/// file and the exact text around it so the exemption cannot spread.
class _Allowance {
  const _Allowance(this.path, this.text, this.reason);

  final String path;

  /// The finding must lie inside an occurrence of this text on its line.
  final String text;
  final String reason;
}

const _allowlist = <_Allowance>[
  _Allowance(
    'docs-site/docs/administration.md',
    'simcrux-pro push-results',
    'the shipped Pro CLI executable a CI job runs, documented for users',
  ),
  _Allowance(
    'docs-site/docs/integrations.md',
    'simcrux-pro push-results',
    'the shipped Pro CLI executable a CI job runs, documented for users',
  ),
  _Allowance(
    'docs-site/docs/team-database.md',
    'simcrux-pro push-results',
    'the shipped Pro CLI executable a CI job runs, documented for users',
  ),
  _Allowance(
    'test/core/platform/linux_desktop_identity_test.dart',
    'com.ferriteengineering.simcrux_pro',
    "the Pro app's shipped freedesktop id, asserted ABSENT from open core",
  ),
];

/// This file defines the patterns and their positive samples.
const _selfPath = 'test/static/no_private_references_test.dart';

class _Finding {
  const _Finding(this.path, this.line, this.rule, this.match, this.start);

  final String path;
  final int line;
  final _Rule rule;
  final String match;
  final int start;

  @override
  String toString() => '$path:$line — ${rule.name}: "$match" (${rule.fix})';
}

/// Every tracked path, NUL-separated so unusual names round-trip.
List<String> _trackedFiles() {
  final result = Process.runSync('git', ['ls-files', '-z']);
  if (result.exitCode != 0) {
    fail(
      'this guard needs a git checkout (cwd = the repository root): '
      'git ls-files failed with ${result.exitCode}: ${result.stderr}',
    );
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((path) => path.isNotEmpty)
      .toList()
    ..sort();
}

/// The file's text, or null for a directory entry (the submodule gitlink),
/// a binary, or anything that is not UTF-8.
String? _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

/// Leading indentation and comment or quote markers of a continuation line.
final _continuationPrefix = RegExp(r'^\s*(?:///?|#|\*|--|>)?\s*');

List<_Finding> _scanText(String path, String text) {
  final findings = <_Finding>[];
  final lines = const LineSplitter().convert(text);
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (final rule in _rules) {
      for (final m in rule.pattern.allMatches(line)) {
        findings.add(_Finding(path, i + 1, rule, m.group(0)!, m.start));
      }
    }
    // A reference wrapped across a line break ("the project\n/// plan") is
    // the same reference. Join the next line, minus its comment marker, and
    // keep only the matches that straddle the join.
    if (i + 1 == lines.length) continue;
    final next = lines[i + 1].replaceFirst(_continuationPrefix, '');
    final joined = '$line $next';
    for (final rule in _rules) {
      for (final m in rule.pattern.allMatches(joined)) {
        if (m.start < line.length && m.end > line.length + 1) {
          findings.add(_Finding(path, i + 1, rule, m.group(0)!, m.start));
        }
      }
    }
  }
  return findings;
}

bool _covers(_Allowance allowance, _Finding finding, String lineText) {
  if (allowance.path != finding.path) return false;
  var from = 0;
  while (true) {
    final at = lineText.indexOf(allowance.text, from);
    if (at < 0) return false;
    final end = at + allowance.text.length;
    if (finding.start >= at && finding.start + finding.match.length <= end) {
      return true;
    }
    from = at + 1;
  }
}

void main() {
  test('no tracked file references a private repository or plan', () {
    final offenders = <String>[];
    final used = <_Allowance>{};
    for (final path in _trackedFiles()) {
      if (path == _selfPath) continue;
      final text = _readText(path);
      if (text == null) continue;
      final lines = const LineSplitter().convert(text);
      for (final finding in _scanText(path, text)) {
        final line = lines[finding.line - 1];
        final allowance = _allowlist
            .where((a) => _covers(a, finding, line))
            .firstOrNull;
        if (allowance != null) {
          used.add(allowance);
          continue;
        }
        offenders.add(finding.toString());
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'A tracked file points at a private repository, plan, charter, '
          'campaign or tracker. This repository is public: the reader cannot '
          'follow the pointer. State the reason inline, link the public page, '
          'or delete the pointer — do not add an allowlist entry for prose.\n'
          '${offenders.join('\n')}',
    );
    final stale = _allowlist
        .where((a) => !used.contains(a))
        .map((a) => '${a.path}: "${a.text}"')
        .toList();
    expect(
      stale,
      isEmpty,
      reason:
          'An allowlist entry no longer matches anything. Delete it, so the '
          'exemption cannot quietly cover a future occurrence.\n'
          '${stale.join('\n')}',
    );
  });

  test('every allowlisted file is tracked', () {
    final tracked = _trackedFiles().toSet();
    final missing = _allowlist
        .map((a) => a.path)
        .where((path) => !tracked.contains(path))
        .toSet()
        .toList();
    expect(missing, isEmpty, reason: 'Allowlisted paths that do not exist.');
  });

  group('the rules', () {
    // Positive samples: each is the shape of a reference this repository
    // actually carried before the guard existed. A rule that stops matching
    // its sample has silently stopped guarding.
    const mustMatch = <String>[
      'see `edacrux/docs/plans/simcrux/simcrux-project-plan.md` §15.8',
      '[plan](../../../edacrux/docs/plans/x.md)',
      'the `simcrux-pro` overlay registers it',
      'lives at the four `simcrux-website` repos',
      'the ingestion Worker (crux-updates/telemetry/src/index.js)',
      'the private planning repo holds the canon',
      'reported as simcrux-beta issue #12',
      '(`RISCV_ECOSYSTEM_PLAN.md` §3.4)',
      'the SimCrux project plan §5.2.7',
      'Suite plan §9.3 rules out test names',
      'Phase 4 §5.2.8 driver plugin SDK',
      'the Track E hand-off',
      'the UI consistency charter would require it',
      'Off by default per the 2026-07-21 ruling.',
      'CXP Cross-Probe Increment WS-D',
      'Closes audit F-09',
      'Lifecycle robustness (SC3)',
      'bottom status bar (P23)',
      'launch-time regressions for beta bug S2',
      'the 2026-08-phase7-acceleration campaign',
      '~/Development/Projects/Flutter/wavecrux-pro/wavecrux/lib/app.dart',
      'the vendor-wrapper driver of Phase-5',
      'command-palette reachability (issue #38)',
      '/// See the SimCrux project\n/// plan §5.2.7.',
      '// the hand-written demos in the marketing-site\n// repo',
    ];
    // Negative samples: public names and ordinary vocabulary that must stay
    // clean, or the guard would push authors into worse prose.
    const mustNotMatch = <String>[
      'https://edacrux.app/cxp#sec-9-9',
      '/etc/edacrux/.crux-policy.json',
      'https://github.com/Ferrite-Engineering/edacrux-edu-packs',
      'the `wavecrux` repository and `crux-shared`',
      'CXP §9.4 requires an honoured ack to carry its reason',
      '`docs/ARCHITECTURE.md` §6.2',
      'the pass/fail detector returns `unknown`',
      'Run Regression (`F5`) and Alt-F4',
      'Archiving to S3 or GCS',
      'the users most likely to hit a beta bug',
      'the query plan uses the composite index',
      'cross-probe to a peer',
      'G1 — no shipped migration was edited',
      'https://github.com/Ferrite-Engineering/simcrux/issues/38',
      '/// The four-pane project\n/// layout',
    ];

    for (final sample in mustMatch) {
      test('flags: $sample', () {
        expect(
          _scanText('sample', sample),
          isNotEmpty,
          reason: 'no rule matches a known private reference',
        );
      });
    }
    for (final sample in mustNotMatch) {
      test('passes: $sample', () {
        expect(
          _scanText('sample', sample).map((f) => f.toString()),
          isEmpty,
          reason: 'a rule flags public or ordinary text',
        );
      });
    }
  });
}
