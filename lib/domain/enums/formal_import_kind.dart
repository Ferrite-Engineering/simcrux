// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The formal job files `simcrux import-…` reads.
///
/// An enum for the reason `RiscvImportKind` is one: the sub-command word is
/// matched in `core/` (the CLI parser), parsed in `services/` (the import
/// command) and named by the GUI import, and `domain/` is the one layer all
/// three may depend on.
enum FormalImportKind {
  /// A SymbiYosys `.sby` job file: one SimCrux test per task, driven by
  /// `sby`.
  sby('import-sby'),

  /// An EQY `.eqy` file: one SimCrux test, driven by `eqy`, with its
  /// partitions reported on that test's row.
  eqy('import-eqy');

  const FormalImportKind(this.subcommand);

  /// The `simcrux <word>` sub-command that runs this import.
  final String subcommand;

  /// Parses a [subcommand] word back to its kind, or null when unknown.
  static FormalImportKind? fromSubcommand(String? word) {
    for (final kind in FormalImportKind.values) {
      if (kind.subcommand == word) return kind;
    }
    return null;
  }

  /// Every sub-command word, for the CLI parser's dispatch table.
  static List<String> get subcommands =>
      FormalImportKind.values.map((k) => k.subcommand).toList(growable: false);
}
