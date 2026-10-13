// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_guards/crux_guards.dart';
import 'package:path/path.dart' as p;

/// The hand-written Dart under [root] (relative to the repository root, so
/// `lib`), as `crux_guards` sources named by their repository-relative
/// path with forward slashes, which is how an exemption names a file.
///
/// Generated code is left out: the localisations declare a getter per ARB
/// key, which would make every key look read, and `.g.dart` output is not
/// anyone's to fix.
List<CruxGuardSource> cruxGuardSourcesUnder(String root) {
  final dir = Directory(root);
  if (!dir.existsSync()) {
    throw StateError('$root is missing; run from the repository root');
  }
  final sources = <CruxGuardSource>[];
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final path = p.relative(entity.path).replaceAll(r'\', '/');
    if (path.contains('/generated/') || path.endsWith('.g.dart')) continue;
    sources.add(CruxGuardSource(path: path, source: entity.readAsStringSync()));
  }
  sources.sort((a, b) => a.path.compareTo(b.path));
  return sources;
}
