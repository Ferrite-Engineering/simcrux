// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Static guard for the ARCHITECTURE.md §6.2 dependency flow:
///
/// ```text
/// features/ → services/ → domain/     (+ everyone may use core/ utils)
/// domain/   → pure Dart (no Flutter, no Riverpod, no upward simcrux deps)
/// core/     → SDK + domain only, except the sanctioned composition root
/// plugins/  → domain/ (+ services/); never features/
/// ```
///
/// The guard reads every `lib/**.dart` source and flags an import that
/// points *up* the layer stack. It is auto-discovering: a new file in
/// the wrong layer, or a new upward import added to an existing file,
/// turns this red with a `path:line` pointer and the rule it broke.
///
/// MUTATION: add `import 'package:simcrux/features/...';` to any
/// `lib/services/**` or `lib/domain/**` file, or import Flutter from
/// `lib/domain/**`, and this guard fails.
///
/// The single sanctioned exception is the **composition root** — the
/// two `lib/core/` files that wire concrete feature screens/providers
/// into the router and the theme bootstrap. Those are the suite's
/// "wiring tier" (see ARCHITECTURE.md §6.2); they legitimately reach
/// into `features/` and are allowlisted below. Adding a third entry to
/// the allowlist must be a conscious decision, reviewed in the PR — do
/// not grow it to paper over ordinary layering rot.
void main() {
  // Repo-relative paths that may import `package:simcrux/features/**`
  // despite living outside `lib/features/`. Keep this list SHORT and
  // justified — every entry is a documented composition-root seam.
  const compositionRootAllowlist = <String>{
    // Router: maps routes to concrete feature screens.
    'lib/core/router/app_router.dart',
    // Theme bootstrap: bridges the settings feature's persisted theme
    // overrides into the crux_theme runtime at app start.
    'lib/core/theme/simcrux_color_theme_bootstrap.dart',
    // Action-dispatch map: the central SimcruxAction → concrete-feature
    // handler wiring extracted from SimcruxApp.build() (god-file
    // decomposition). It is composition-root by nature — it must reference
    // every feature's opener/provider to route actions from the palette,
    // menu bar, and shortcuts, exactly as the in-app build() did before.
    'lib/core/shortcuts/simcrux_action_handlers.dart',
  };

  final lib = Directory('lib');
  setUpAll(() {
    expect(
      lib.existsSync(),
      isTrue,
      reason: 'run from the package root (cwd = simcrux/)',
    );
  });

  // Returns every `package:simcrux/...` import in [file], paired with
  // its 1-based line number.
  List<({String import, int line})> simcruxImports(File file) {
    final result = <({String import, int line})>[];
    final importPattern = RegExp(
      r'''^\s*import\s+['"](package:simcrux/[^'"]+)['"]''',
    );
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final m = importPattern.firstMatch(lines[i]);
      if (m != null) result.add((import: m.group(1)!, line: i + 1));
    }
    return result;
  }

  Iterable<File> dartFilesUnder(String dir) sync* {
    final root = Directory(dir);
    if (!root.existsSync()) return;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File &&
          entity.path.endsWith('.dart') &&
          !entity.path.endsWith('.g.dart')) {
        yield entity;
      }
    }
  }

  String rel(File f) => p.relative(f.path).replaceAll(r'\', '/');

  test('domain/ is pure — no Flutter, Riverpod, or upward simcrux deps', () {
    final offenders = <String>[];
    // Forbidden import prefixes for the domain layer.
    const forbidden = <String>[
      'package:flutter/',
      'package:flutter_riverpod/',
      'package:riverpod/',
      'package:simcrux/services/',
      'package:simcrux/features/',
      'package:simcrux/core/',
      'package:simcrux/plugins/',
    ];
    final anyImport = RegExp(r'''^\s*import\s+['"]([^'"]+)['"]''');
    for (final file in dartFilesUnder('lib/domain')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final m = anyImport.firstMatch(lines[i]);
        if (m == null) continue;
        final uri = m.group(1)!;
        if (forbidden.any(uri.startsWith)) {
          offenders.add('${rel(file)}:${i + 1} → $uri');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'domain/ must be pure Dart (§6.1). A pure data class that a '
          'service or feature needs belongs in domain/, but domain must '
          'never import up the stack. Offenders:\n${offenders.join('\n')}',
    );
  });

  test('services/ must not import features/', () {
    final offenders = <String>[];
    for (final file in dartFilesUnder('lib/services')) {
      for (final imp in simcruxImports(file)) {
        if (imp.import.startsWith('package:simcrux/features/')) {
          offenders.add('${rel(file)}:${imp.line} → ${imp.import}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'services/ sits below features/ in the §6.2 flow. A service '
          'that reaches into a feature provider is either (a) a pure '
          'model misfiled in services/ — move it to domain/ — or (b) a '
          'coordinator/provider misfiled in services/ — move it to the '
          'owning feature module. Offenders:\n${offenders.join('\n')}',
    );
  });

  test('plugins/ must not import features/', () {
    final offenders = <String>[];
    for (final file in dartFilesUnder('lib/plugins')) {
      for (final imp in simcruxImports(file)) {
        if (imp.import.startsWith('package:simcrux/features/')) {
          offenders.add('${rel(file)}:${imp.line} → ${imp.import}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'plugins/ is registry infrastructure below features/ (§6.2). '
          'Offenders:\n${offenders.join('\n')}',
    );
  });

  test('core/ must not import features/ (except the composition root)', () {
    final offenders = <String>[];
    for (final file in dartFilesUnder('lib/core')) {
      final relPath = rel(file);
      if (compositionRootAllowlist.contains(relPath)) continue;
      for (final imp in simcruxImports(file)) {
        if (imp.import.startsWith('package:simcrux/features/')) {
          offenders.add('$relPath:${imp.line} → ${imp.import}');
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'core/ is the shared utility + composition-root layer. Only '
          'the allowlisted composition-root files may wire concrete '
          'features; everything else in core/ stays feature-agnostic. '
          'If this is a new composition-root seam, add it to '
          'compositionRootAllowlist with a justifying comment. '
          'Offenders:\n${offenders.join('\n')}',
    );
  });

  test('composition-root allowlist has no stale entries', () {
    // Guard the guard: if a move/rename leaves an allowlist entry
    // pointing at a file that no longer imports features/ (or no longer
    // exists), drop it so the list keeps meaning what it says.
    final stale = <String>[];
    for (final entry in compositionRootAllowlist) {
      final file = File(entry);
      if (!file.existsSync()) {
        stale.add('$entry (file missing)');
        continue;
      }
      final importsFeatures = simcruxImports(
        file,
      ).any((i) => i.import.startsWith('package:simcrux/features/'));
      if (!importsFeatures) {
        stale.add('$entry (no longer imports features/)');
      }
    }
    expect(
      stale,
      isEmpty,
      reason:
          'remove stale composition-root allowlist entries:\n'
          '${stale.join('\n')}',
    );
  });
}
