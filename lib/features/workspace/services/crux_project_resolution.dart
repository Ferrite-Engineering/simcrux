// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_project/crux_project.dart';
import 'package:path/path.dart' as p;

/// The `<design>.crux-project` `artifacts:` key SimCrux consumes.
///
/// The key lives here rather than in `crux_project` on purpose: artifact kinds
/// are opaque strings in the shared package, so each product owns the constant
/// for the kind it consumes; the key set is defined by the `crux_project`
/// package in crux-shared.
const String kSimulationArtifactKind = 'simulation';

/// The outcome of pointing SimCrux at a path that might be a design manifest
/// or a design directory holding one.
///
/// Every refusal carries data, not prose: the widget layer turns it into a
/// localized message.
sealed class CruxProjectResolution {
  const CruxProjectResolution();
}

/// The path was not a manifest — open it as an ordinary config or session.
class NotAManifest extends CruxProjectResolution {
  /// Creates the pass-through outcome.
  const NotAManifest(this.path);

  /// The path, unchanged.
  final String path;
}

/// The manifest named a regression config and it is on disk.
class ManifestSimulation extends CruxProjectResolution {
  /// Creates the success outcome.
  const ManifestSimulation({
    required this.configPath,
    required this.designId,
    required this.displayName,
    required this.manifestPath,
    this.warnings = const <String>[],
  });

  /// The `simcrux.yaml` to open.
  final String configPath;

  /// CXP design id, derived from the manifest's directory.
  final String designId;

  /// The manifest's human label.
  final String displayName;

  /// The manifest that was read.
  final String manifestPath;

  /// Non-fatal parse warnings, in English, as `crux_project` reports them.
  final List<String> warnings;

  /// True when the manifest uses the legacy bare `.crux-project` name, which
  /// file pickers and Finder hide. It still opens; the user is told to rename
  /// it to [suggestedFileName].
  bool get isLegacyFileName =>
      CruxProjectParser.isLegacyManifestPath(manifestPath);

  /// The name a legacy manifest should be renamed to: the design directory's
  /// name with the manifest extension.
  String get suggestedFileName {
    final stem = p.basename(p.dirname(p.absolute(manifestPath)));
    return '${stem.isEmpty ? 'design' : stem}.$kCruxProjectExtension';
  }
}

/// The path was a manifest (or a design directory) but there is nothing here
/// SimCrux can open.
sealed class ManifestUnusable extends CruxProjectResolution {
  const ManifestUnusable();
}

/// The manifest could not be parsed.
class ManifestInvalid extends ManifestUnusable {
  /// Creates the parse-failure outcome.
  const ManifestInvalid({required this.manifestPath, required this.detail});

  /// The manifest that failed to parse.
  final String manifestPath;

  /// The parser's diagnostic, in English.
  final String detail;
}

/// The manifest names a regression config that is not on disk.
class ManifestConfigMissing extends ManifestUnusable {
  /// Creates the missing-config outcome.
  const ManifestConfigMissing(this.configPath);

  /// The `simulation:` entry as written in the manifest.
  final String configPath;
}

/// The manifest has no `simulation:` entry.
class ManifestNoSimulation extends ManifestUnusable {
  /// Creates the no-entry outcome.
  const ManifestNoSimulation(this.displayName);

  /// The manifest's human label.
  final String displayName;
}

/// A design directory holds more than one manifest, so none is opened.
class ManifestAmbiguous extends ManifestUnusable {
  /// Creates the ambiguous-directory outcome.
  const ManifestAmbiguous({required this.directory, required this.candidates});

  /// The directory that was searched.
  final String directory;

  /// Every manifest found in it, as full paths, sorted.
  final List<String> candidates;
}

/// Resolves a possible manifest path, or a design directory, to the config
/// SimCrux opens.
class CruxProjectResolver {
  /// Creates a resolver.
  const CruxProjectResolver({this.parser = const CruxProjectParser()});

  /// The manifest parser. Injectable for tests.
  final CruxProjectParser parser;

  /// Resolves [path]: a `<design>.crux-project` (or the legacy bare
  /// `.crux-project`), a directory holding exactly one of them, or anything
  /// else, which passes through unchanged.
  CruxProjectResolution resolve(
    String path, {
    bool Function(String path)? exists,
  }) {
    final String manifestPath;
    if (FileSystemEntity.isDirectorySync(path)) {
      final String? found;
      try {
        found = CruxProjectParser.locate(path);
      } on CruxProjectAmbiguousException catch (e) {
        return ManifestAmbiguous(
          directory: e.directory,
          candidates: e.candidates,
        );
      }
      if (found == null) return NotAManifest(path);
      manifestPath = found;
    } else if (CruxProjectParser.isManifestPath(path)) {
      manifestPath = path;
    } else {
      return NotAManifest(path);
    }

    final CruxProjectManifest manifest;
    try {
      manifest = parser.parseFile(manifestPath);
    } on CruxProjectFormatException catch (e) {
      return ManifestInvalid(manifestPath: manifestPath, detail: e.message);
    }

    final plan = const CruxProjectOpenPlanner().plan(
      manifest,
      kind: kSimulationArtifactKind,
      exists: exists,
    );

    final artifact = plan.artifactPath;
    if (artifact != null) {
      return ManifestSimulation(
        configPath: artifact,
        designId: plan.designId,
        displayName: manifest.displayName,
        manifestPath: manifestPath,
        warnings: manifest.warnings,
      );
    }

    return switch (plan.refusal) {
      CruxOpenRefusal.pathMissing => ManifestConfigMissing(
        manifest.rawArtifacts[kSimulationArtifactKind] ?? '',
      ),
      CruxOpenRefusal.kindAbsent || null => ManifestNoSimulation(
        manifest.displayName,
      ),
    };
  }
}
