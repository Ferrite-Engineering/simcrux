// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/models/fusesoc_import_warning.dart';

/// Output of the FuseSoC importer.
///
/// Carries the synthesized `simcrux.yaml` content as a string (the
/// CLI / UI writes it to disk), the suggested output filename for the
/// user (derived from the source `.core`'s `name:` and the source
/// path), and the list of [warnings] surfaced during translation. The
/// list of warnings is non-empty for `.core` files that exercise
/// CAPI2 features SimCrux doesn't yet consume; the importer never
/// throws on unsupported features, it just records them and continues.
@immutable
class FuseSoCImportResult {
  /// Creates a [FuseSoCImportResult].
  FuseSoCImportResult({
    required this.simcruxYaml,
    required this.suggestedOutputFilename,
    List<FuseSoCImportWarning>? warnings,
  }) : warnings = List<FuseSoCImportWarning>.unmodifiable(
         warnings ?? const <FuseSoCImportWarning>[],
       );

  /// The translated SimCrux config, ready to write to disk and load
  /// through `ConfigLoader.load()`. Always non-empty when the importer
  /// completes; uses two-space indentation and an explicit
  /// `version: '1'` header. Round-trip property tests verify that
  /// `ConfigLoader().parse(simcruxYaml, ...)` accepts the output.
  final String simcruxYaml;

  /// File name (not path) the UI suggests when prompting the user to
  /// save the result. Derived from the CAPI2 `name:` field with
  /// vendor/library/version stripped, falling back to the input
  /// `.core` file's basename when `name:` is absent. Always ends in
  /// `simcrux.yaml`.
  final String suggestedOutputFilename;

  /// Warnings encountered during translation. Each warning is a
  /// non-fatal observation: an unsupported CAPI2 feature, a
  /// vendor-specific tool block we can't run on Open Core, a complex
  /// parameter type that doesn't map cleanly to SimCrux's
  /// defines/parameters surface. Empty when the `.core` file maps
  /// cleanly.
  final List<FuseSoCImportWarning> warnings;

  /// True when the importer surfaced at least one [FuseSoCImportWarning].
  bool get hasWarnings => warnings.isNotEmpty;
}
