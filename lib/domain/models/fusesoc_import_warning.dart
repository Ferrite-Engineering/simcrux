// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// A non-fatal issue surfaced by the FuseSoC `.core` importer.
///
/// The importer is intentionally lenient: CAPI2 has many fields
/// SimCrux doesn't (yet) consume — generator targets, scripts blocks,
/// VPI module declarations, vendor-simulator tool blocks. Encountering
/// those isn't a parse failure, just a heads-up that the produced
/// `simcrux.yaml` may not exercise every aspect of the original
/// `.core`. The UI surfaces the warnings inline next to the generated
/// file path; the CLI prints them to stderr.
@immutable
class FuseSoCImportWarning {
  /// Creates a [FuseSoCImportWarning].
  const FuseSoCImportWarning({required this.code, required this.message});

  /// Stable machine-readable id (e.g. `unsupported_tool`,
  /// `complex_parameter`, `unknown_file_type`). Tests assert on this
  /// field rather than on the [message] so wording changes don't
  /// break the contract.
  final String code;

  /// Human-readable English description. Logged verbatim to stderr
  /// and rendered in the UI's import-result dialog.
  final String message;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FuseSoCImportWarning &&
        other.code == code &&
        other.message == message;
  }

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'FuseSoCImportWarning($code: $message)';
}
