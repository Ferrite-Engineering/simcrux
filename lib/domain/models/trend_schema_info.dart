// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// One row of the trend store's migration ledger, as the UI reads it.
@immutable
class TrendSchemaLedgerEntry {
  /// Creates a [TrendSchemaLedgerEntry].
  const TrendSchemaLedgerEntry({
    required this.version,
    required this.description,
    required this.appliedAt,
    required this.appliedByAppVersion,
  });

  /// The schema version this migration produced.
  final int version;

  /// What it did, in the migration author's own words.
  final String description;

  /// When it ran, or `null` when it predates the ledger.
  final DateTime? appliedAt;

  /// The build that ran it, or `null` when it predates the ledger.
  final String? appliedByAppVersion;

  @override
  bool operator ==(Object other) =>
      other is TrendSchemaLedgerEntry &&
      other.version == version &&
      other.description == description &&
      other.appliedAt == appliedAt &&
      other.appliedByAppVersion == appliedByAppVersion;

  @override
  int get hashCode =>
      Object.hash(version, description, appliedAt, appliedByAppVersion);

  @override
  String toString() =>
      'TrendSchemaLedgerEntry(v$version, ${appliedAt ?? 'unknown'})';
}

/// What the trend database says about its own schema, for App Diagnostics.
///
/// A **presentation** view of `crux_sqlite`'s shared `schema_meta` /
/// `schema_migrations` shape, not a second definition of it. The shape itself
/// is defined and written in one place for all four Crux SQLite databases; this
/// is the SimCrux-side model the dialog renders, and it exists for one concrete
/// reason: `lib/domain/` and SimCrux's **web** tree must stay free of
/// `package:crux_sqlite`, whose open policy reaches `dart:io` through
/// `sqflite_common_ffi`. The io trend store maps `CruxSchemaHistory` into this;
/// the web stub returns [absent].
@immutable
class TrendSchemaInfo {
  /// Creates a [TrendSchemaInfo].
  const TrendSchemaInfo({
    required this.schemaVersion,
    required this.migratedByAppVersion,
    required this.lastMigratedAt,
    required this.lastOpenedByAppVersion,
    required this.ledger,
  });

  /// A database that carries no `schema_meta` at all.
  ///
  /// Every existing `trends.db` looks like this until the launch that migrates
  /// it to v4, and so does the web stub. It is a state to render — "not
  /// recorded" — never an error.
  static const TrendSchemaInfo absent = TrendSchemaInfo(
    schemaVersion: null,
    migratedByAppVersion: null,
    lastMigratedAt: null,
    lastOpenedByAppVersion: null,
    ledger: <TrendSchemaLedgerEntry>[],
  );

  /// The schema version recorded in the file, or `null` when it records none.
  final int? schemaVersion;

  /// The build that last migrated the file.
  ///
  /// Distinct from [lastOpenedByAppVersion] on purpose: the build that
  /// *changed* the schema is the one a support conversation asks about, and it
  /// is usually not the one running now.
  final String? migratedByAppVersion;

  /// When that migration ran.
  final DateTime? lastMigratedAt;

  /// The build that opened the file most recently.
  final String? lastOpenedByAppVersion;

  /// The most recent ledger rows, newest version first.
  final List<TrendSchemaLedgerEntry> ledger;

  /// Whether the file records anything about itself.
  bool get isRecorded => schemaVersion != null;

  @override
  String toString() =>
      'TrendSchemaInfo(v${schemaVersion ?? 'unrecorded'}, '
      '${ledger.length} ledger rows)';
}
