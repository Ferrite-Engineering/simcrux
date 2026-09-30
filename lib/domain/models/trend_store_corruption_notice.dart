// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// What happened to a `trends.db` whose bytes turned out not to be a readable
/// SQLite database, as the UI reads it.
///
/// A **presentation** view of `package:crux_sqlite`'s
/// `CruxDatabaseCorruptionException`, not a second definition of it. There is
/// no SimCrux-side corruption *exception* any more — the package's type is the
/// one that is raised, reported and caught, exactly as LintCrux's store does
/// it. This exists for the one reason SimCrux differs from LintCrux:
/// `lib/domain/` and SimCrux's **web** tree must stay free of
/// `package:crux_sqlite`, whose open policy reaches `dart:io` through
/// `sqflite_common_ffi`, and `flutter build web` compiles `lib/main.dart`
/// including the App Diagnostics dialog that renders this. The io trend store
/// maps the package's exception into this; the web stub never produces one.
///
/// Its existence is itself the signal: a non-null notice means the user's
/// regression history is no longer in the file the app is now writing to. The
/// original bytes are at [quarantinedPath] — **never deleted**, because
/// `trends.db` holds history nothing else can regenerate
/// (`crux-shared/packages/crux_sqlite/README.md`, rule 5).
@immutable
class TrendStoreCorruptionNotice {
  /// Creates a [TrendStoreCorruptionNotice].
  const TrendStoreCorruptionNotice({
    required this.path,
    required this.quarantinedPath,
    required this.backupPath,
    required this.occurredAt,
    required this.causeDescription,
  });

  /// Absolute path of the database that could not be read — and of the fresh,
  /// empty database now open in its place.
  final String path;

  /// Absolute path the damaged bytes were renamed to, or `null` when the
  /// rename itself failed (in which case the damaged file is still at [path],
  /// under the fresh database).
  ///
  /// Never a path that was deleted: `renameAside` cannot delete.
  final String? quarantinedPath;

  /// Absolute path of the newest pre-upgrade `VACUUM INTO` snapshot sitting
  /// next to [path], or `null` when this file has never been migrated by a
  /// build that takes them.
  ///
  /// The better of the two recovery offers when it exists: a backup is a real
  /// database with real history in it, where a rebuild from `results.ndjson`
  /// can only reach the runs whose archives the user still has.
  final String? backupPath;

  /// When the failed open happened (UTC).
  final DateTime occurredAt;

  /// The underlying `DatabaseException`, rendered. Kept as a string rather
  /// than as the object so this model stays free of `package:sqflite_common`.
  final String causeDescription;

  @override
  bool operator ==(Object other) =>
      other is TrendStoreCorruptionNotice &&
      other.path == path &&
      other.quarantinedPath == quarantinedPath &&
      other.backupPath == backupPath &&
      other.occurredAt == occurredAt &&
      other.causeDescription == causeDescription;

  @override
  int get hashCode => Object.hash(
    path,
    quarantinedPath,
    backupPath,
    occurredAt,
    causeDescription,
  );

  @override
  String toString() =>
      'TrendStoreCorruptionNotice($path → ${quarantinedPath ?? 'not moved'})';
}
