// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: a hand-rolled "*Empty*"-named widget class must either be
// replaced with the shared `CruxPanelEmptyState` (`package:crux_ide_layout`)
// or be listed below with the reason it is a genuinely different surface.
//
// The defect this stops recurring: `InspectorEmpty` was a byte-for-byte copy
// of `CruxPanelEmptyState`'s canonical form — 24 px padding, a centred
// `bodyMedium` message in `onSurfaceVariant`. A second copy of a shared
// widget drifts silently: when the shared one gained its short-region scroll
// fix, the copy did not. It was deleted and `InspectorPane` now renders
// `CruxPanelEmptyState` directly.
//
// Heuristic and its limit: this matches any class whose NAME contains
// "Empty" and requires it to be listed with a reviewed reason. It cannot tell
// a duplicate by shape — a copy named `InspectorPlaceholder` would pass. It is
// deliberately over-inclusive by name, so the richer surfaces below are
// listed rather than skipped, and a new "Empty"-named class always stops the
// build until someone either uses the shared widget or explains why not.
//
// Scope: this repository's own `lib/` only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A reviewed "*Empty*"-named class, pinned to its file and class name.
class _Allowance {
  const _Allowance(this.path, this.className, this.reason);
  final String path;
  final String className;
  final String reason;
}

const _allowlist = <_Allowance>[
  _Allowance(
    'lib/web/web_dashboard_screen.dart',
    '_EmptyState',
    'a full-page "no results in this file" state for the web results '
        'viewer, with a separate title AND body. CruxPanelEmptyState takes a '
        'single message, with no title tier.',
  ),
  _Allowance(
    'lib/features/workspace/widgets/empty_canvas_content.dart',
    'EmptyCanvasContent',
    'the welcome screen content hosted in EmptyCanvasState (crux_workspace): '
        'app icon, recent configs, and the Open Config / Open Session / Open '
        'Workspace / New Config actions. A different surface, not a panel '
        'placeholder.',
  ),
];

final _emptyClass = RegExp(r'\bclass\s+(_?[A-Za-z0-9]*Empty[A-Za-z0-9]*)\b');

class _Finding {
  const _Finding(this.path, this.className, this.line);
  final String path;
  final String className;
  final int line;

  @override
  String toString() => '$path:$line: class $className';
}

List<_Finding> _scan(Directory root) {
  final findings = <_Finding>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = entity.path.replaceAll(r'\', '/');
    final lines = entity.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final m = _emptyClass.firstMatch(lines[i]);
      if (m != null) findings.add(_Finding(path, m.group(1)!, i + 1));
    }
  }
  return findings;
}

bool _matches(_Allowance a, _Finding f) =>
    f.path.endsWith(a.path) && f.className == a.className;

void main() {
  test('every "*Empty*"-named class in lib/ is reviewed', () {
    final root = Directory('lib');
    expect(root.existsSync(), isTrue, reason: 'run from the repository root');

    final findings = _scan(root);
    expect(
      findings,
      isNotEmpty,
      reason:
          'expected at least the listed classes — the scan is not walking '
          'lib/ correctly',
    );

    final offenders = findings
        .where((f) => !_allowlist.any((a) => _matches(a, f)))
        .toList();
    expect(
      offenders,
      isEmpty,
      reason:
          'A new "*Empty*"-named class appeared. If it shows a message in a '
          'panel with nothing to show, use CruxPanelEmptyState(message: ...) '
          'from package:crux_ide_layout instead of a local copy. If it is a '
          'genuinely different surface, list it in _allowlist with the '
          'reason.\n${offenders.join('\n')}',
    );

    final stale = _allowlist
        .where((a) => !findings.any((f) => _matches(a, f)))
        .toList();
    expect(
      stale,
      isEmpty,
      reason:
          'An allowlist entry matches nothing — the class was renamed or '
          'deleted. Delete the entry.\n'
          '${stale.map((a) => '${a.path}: ${a.className}').join('\n')}',
    );
  });

  test('the detector recognizes the shape of the removed InspectorEmpty', () {
    const sample = 'class InspectorEmpty extends StatelessWidget {';
    expect(_emptyClass.firstMatch(sample)?.group(1), 'InspectorEmpty');
  });

  test('the detector recognizes a private underscore-prefixed variant', () {
    const sample = 'class _EmptyCenter extends StatelessWidget {';
    expect(_emptyClass.firstMatch(sample)?.group(1), '_EmptyCenter');
  });

  test('the detector ignores an isEmpty check', () {
    expect(_emptyClass.hasMatch('if (rows.isEmpty) return;'), isFalse);
  });
}
