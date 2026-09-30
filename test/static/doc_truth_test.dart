// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard for the mechanically checkable claims in the reference
// documents. Identical in shape to the Pro overlay's copy; the document set
// and the resolution roots differ per repo.
//
// The reference documents describe the tree: they name files, they state
// quantities derived from the code, and they enumerate registries. Every one
// of those claims decays silently as the tree moves under it — a renamed
// directory, a string added to an ARB file, a provider appended to an
// override list. Prose has no compiler, so the decay is only ever found by a
// human sweep, and a sweep is exactly what this guard replaces.
//
// Four claim classes are checked:
//
//  1. Path existence. A repo-relative path written in a document must resolve
//     to a file or directory on disk.
//  2. Documented absence. A document that asserts a path does *not* exist is
//     checked in the same direction: the path must stay gone. This is the
//     inverse of class 1 rather than a hole in it.
//  3. Derived quantities. A number stated in prose that is computable from
//     the tree must equal the computed value. Quantities that churn on every
//     feature commit are removed from the prose instead of being listed here,
//     since a guard that turns every string addition into a document edit
//     trades one maintenance burden for another.
//  4. Registry inventories. A document that enumerates the membership of an
//     override list does so inside a marked block whose contents must equal
//     the parsed list exactly. Over-listing and under-listing both fail.
//
// The extractor is scoped rather than allowlisted. It reads only backticked
// tokens and Markdown link targets, ignores fenced code blocks (worked
// examples and directory sketches are illustrative, not inventories), ignores
// anything carrying glob or placeholder punctuation, and requires a
// recognized top-level directory prefix so that cross-repo references resolve
// as prose rather than as broken local paths.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Documents whose claims are binding.
const _referenceDocs = [
  'CLAUDE.md',
  'docs/ARCHITECTURE.md',
  'verification/VERIFICATION_GUIDE.md',
  'verification/VERIFICATION_CHECKLIST.md',
];

/// Roots a documented path may resolve against. The open-core repo is
/// standalone, so its documents only ever name its own tree.
const _resolutionRoots = ['.'];

/// Top-level directories that mark a token as a repo-relative path. A token
/// without one of these prefixes is prose, a package reference, or a path in
/// another repository, and is not this guard's business.
const _pathPrefixes = [
  'lib/',
  'test/',
  'integration_test/',
  'tool/',
  'docs/',
  'verification/',
  'assets/',
  '.github/',
];

/// Documents whose unchecked checklist rows describe intended future state
/// rather than current state, so paths inside them are not yet expected to
/// exist. The verification checklist is deliberately excluded: its unchecked
/// rows record whether a check has been *run*, not whether the code exists.
const _futureStateDocs = ['docs/ARCHITECTURE.md'];

/// Paths a document asserts are absent, each with the claim it supports.
/// Checked in the negative direction, so recreating one of these fails the
/// guard and points at the prose that would become false.
const Map<String, String> _documentedAbsences = {};

/// Characters that mark a token as a pattern, a placeholder, or prose rather
/// than a literal path.
const _patternChars = ['*', '<', '>', '{', '}', '?', '…', '|', ',', '(', ')'];

final _linkRe = RegExp(r'\[((?:[^\]\\]|\\.)*)\]\(([^)\s]+)\)');
final _tickRe = RegExp(r'`([^`\n]+)`');
final _uriRe = RegExp('^[a-z][a-z0-9+.-]*:');
final _uncheckedRowRe = RegExp(r'^\s*[-*]\s*\[ \]');

/// A claim and the document location that makes it.
class _Claim {
  const _Claim(this.doc, this.line, this.text);

  final String doc;
  final int line;
  final String text;

  @override
  String toString() => '$doc:$line — $text';
}

/// Returns [source]'s lines with fenced-code content blanked, preserving line
/// numbering so findings point at the right row.
List<String> _linesOutsideFences(String source) {
  final lines = <String>[];
  var inFence = false;
  for (final line in const LineSplitter().convert(source)) {
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      lines.add('');
      continue;
    }
    lines.add(inFence ? '' : line);
  }
  return lines;
}

/// Extracts path-shaped tokens from one document line.
///
/// A Markdown link carries the path in its target when the target is
/// repo-relative, and in its label when the target is an external URL (the
/// label names the local file, the URL names its published copy). Both forms
/// are handled so neither hides a stale path.
List<String> _pathTokens(String line) {
  final tokens = <String>[];
  var remainder = line;
  for (final match in _linkRe.allMatches(line)) {
    final label = match.group(1)!;
    final target = match.group(2)!;
    if (_uriRe.hasMatch(target)) {
      tokens.addAll(_tickRe.allMatches(label).map((m) => m.group(1)!));
    } else {
      tokens.add(target);
    }
    remainder = remainder.replaceFirst(match.group(0)!, ' ');
  }
  tokens.addAll(_tickRe.allMatches(remainder).map((m) => m.group(1)!));
  return tokens;
}

/// Normalizes a token to a candidate path, or returns null if it is not one.
String? _asRepoPath(String token) {
  // `path::test name` cites one case inside a file; the file is the claim.
  var candidate = token.trim().split('::').first.split('#').first;
  while (candidate.isNotEmpty &&
      '.,;:'.contains(candidate[candidate.length - 1])) {
    candidate = candidate.substring(0, candidate.length - 1);
  }
  if (!candidate.contains('/')) return null;
  if (!_pathPrefixes.any(candidate.startsWith)) return null;
  if (_patternChars.any(candidate.contains)) return null;
  return candidate;
}

bool _existsInWindow(String relativePath) => _resolutionRoots.any((root) {
  final full = p.join(root, relativePath);
  return File(full).existsSync() || Directory(full).existsSync();
});

/// Every path-shaped token in the reference documents, with its location.
List<_Claim> _documentedPaths() {
  final claims = <_Claim>[];
  for (final doc in _referenceDocs) {
    final file = File(doc);
    if (!file.existsSync()) continue;
    final lines = _linesOutsideFences(file.readAsStringSync());
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (_futureStateDocs.contains(doc) && _uncheckedRowRe.hasMatch(line)) {
        continue;
      }
      for (final token in _pathTokens(line)) {
        final path = _asRepoPath(token);
        if (path != null) claims.add(_Claim(doc, i + 1, path));
      }
    }
  }
  return claims;
}

// --- Derived quantities ------------------------------------------------

const _numberWords = {
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
};

int? _parseCount(String raw) =>
    int.tryParse(raw.replaceAll(',', '').replaceAll(' ', '')) ??
    _numberWords[raw.toLowerCase()];

/// A quantity a document may state and the tree value it must equal.
class _DerivedQuantity {
  const _DerivedQuantity(this.description, this.pattern, this.actual);

  final String description;

  /// Must capture the written number in group 1.
  final RegExp pattern;

  final int Function() actual;
}

int _arbFileCount(String root) => Directory(p.join(root, 'lib', 'l10n'))
    .listSync()
    .whereType<File>()
    .where((f) => p.basename(f.path).startsWith('app_'))
    .where((f) => f.path.endsWith('.arb'))
    .length;

/// Provider names registered in the override list [listName] declared in
/// [source]. Reads the `<Override>[ ... ]` literal that follows the name and
/// collects every provider it overrides.
Set<String> _overrideListMembers(String sourcePath, String listName) {
  final source = File(sourcePath).readAsStringSync();
  final start = RegExp(
    '\\b$listName\\b[\\s\\S]{0,200}?<Override>\\[',
  ).firstMatch(source);
  if (start == null) {
    fail('Override list `$listName` not found in $sourcePath.');
  }
  var depth = 1;
  var i = start.end;
  while (i < source.length && depth > 0) {
    if (source[i] == '[') depth++;
    if (source[i] == ']') depth--;
    i++;
  }
  final body = source.substring(start.end, i);
  return RegExp(
    r'\b(\w+Provider)\s*\.\s*override',
  ).allMatches(body).map((m) => m.group(1)!).toSet();
}

const _tabOverridesSource =
    'lib/features/workspace/providers/simcrux_tab_overrides.dart';

final _derivedQuantities = <_DerivedQuantity>[
  _DerivedQuantity(
    'ARB files under lib/l10n/',
    RegExp(r'\b([\w,]+) ARB files\b'),
    () => _arbFileCount('.'),
  ),
  _DerivedQuantity(
    'providers re-bound by simcruxTabOverrides',
    RegExp(r'\b([\w,]+) overrides in total\b'),
    () => _overrideListMembers(
      _tabOverridesSource,
      'simcruxTabOverrides',
    ).length,
  ),
  _DerivedQuantity(
    'message keys in lib/l10n/app_en.arb',
    RegExp(r'\b([\w,]+) message keys\b'),
    () =>
        (jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
                as Map<String, dynamic>)
            .keys
            .where((k) => !k.startsWith('@'))
            .length,
  ),
];

// --- Registry inventories ----------------------------------------------

/// A document block that enumerates an override list's membership.
class _Inventory {
  const _Inventory(this.doc, this.listName, this.sourcePath, this.declaredIn);

  final String doc;

  /// Marker name, matching `<!-- inventory: <listName> -->` in the document.
  final String listName;

  /// Dart file declaring the list.
  final String sourcePath;

  /// Identifier of the list literal inside [sourcePath].
  final String declaredIn;
}

const _inventories = [
  _Inventory(
    'docs/ARCHITECTURE.md',
    'simcruxTabOverrides',
    _tabOverridesSource,
    'simcruxTabOverrides',
  ),
];

Set<String> _inventoryEntries(_Inventory inventory) {
  final source = File(inventory.doc).readAsStringSync();
  final block = RegExp(
    '<!-- inventory: ${inventory.listName} -->([\\s\\S]*?)<!-- /inventory -->',
  ).firstMatch(source);
  if (block == null) {
    fail(
      'No `<!-- inventory: ${inventory.listName} -->` block in '
      "${inventory.doc}. The block is the document's machine-checked copy of "
      'the list; removing it removes the only thing keeping the prose true.',
    );
  }
  return RegExp(
    r'`(\w+Provider)`',
  ).allMatches(block.group(1)!).map((m) => m.group(1)!).toSet();
}

void main() {
  test('every documented repo path exists', () {
    final missing =
        _documentedPaths()
            .where((c) => !_documentedAbsences.containsKey(c.text))
            .where((c) => !_existsInWindow(c.text))
            .map((c) => c.toString())
            .toSet()
            .toList()
          ..sort();
    expect(
      missing,
      isEmpty,
      reason:
          'A reference document names a path that is not in the tree. Either '
          'the file moved and the document was not updated, or the document '
          'describes something that was never built. Correct the document; do '
          'not exempt the path.\n${missing.join('\n')}',
    );
  });

  test('paths documented as absent are still absent', () {
    final resurrected =
        _documentedAbsences.entries
            .where((e) => _existsInWindow(e.key))
            .map((e) => '${e.key} — documented absent because: ${e.value}')
            .toList()
          ..sort();
    expect(
      resurrected,
      isEmpty,
      reason:
          'A path a reference document states does not exist has been '
          'created. The prose asserting its absence is now false and must be '
          'rewritten.\n${resurrected.join('\n')}',
    );
  });

  test('quantities stated in the documents match the tree', () {
    final wrong = <String>[];
    for (final doc in _referenceDocs) {
      final file = File(doc);
      if (!file.existsSync()) continue;
      final lines = _linesOutsideFences(file.readAsStringSync());
      for (var i = 0; i < lines.length; i++) {
        for (final quantity in _derivedQuantities) {
          for (final match in quantity.pattern.allMatches(lines[i])) {
            final written = _parseCount(match.group(1)!);
            if (written == null) continue;
            final actual = quantity.actual();
            if (written == actual) continue;
            wrong.add(
              '$doc:${i + 1} — states ${match.group(0)}, but '
              '${quantity.description} is $actual',
            );
          }
        }
      }
    }
    wrong.sort();
    expect(
      wrong,
      isEmpty,
      reason:
          'A reference document states a number that disagrees with the code '
          'it describes. Correct the number, or remove it — a quantity that '
          'changes on every feature commit reads better as prose without a '
          'figure.\n${wrong.join('\n')}',
    );
  });

  test('documented override inventories match the registered lists', () {
    for (final inventory in _inventories) {
      final documented = _inventoryEntries(inventory);
      final registered = _overrideListMembers(
        inventory.sourcePath,
        inventory.declaredIn,
      );
      final undocumented = registered.difference(documented).toList()..sort();
      final phantom = documented.difference(registered).toList()..sort();
      expect(
        [
          ...undocumented.map((n) => 'registered but not documented: $n'),
          ...phantom.map((n) => 'documented but not registered: $n'),
        ],
        isEmpty,
        reason:
            'The `${inventory.listName}` inventory in ${inventory.doc} does '
            'not match `${inventory.declaredIn}` in ${inventory.sourcePath}. A '
            'provider missing from the list is the silent per-tab scope-leak '
            'defect; a provider missing from the document leaves a reader '
            'with a false picture of which state is tab-scoped.',
      );
    }
  });
}
