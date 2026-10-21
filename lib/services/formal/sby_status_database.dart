// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:simcrux/services/formal/sby_status_reader.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A property `status.sqlite` declares for a task, with or without any
/// status rows.
@immutable
class SbyDeclaredProperty {
  /// Creates a declaration.
  const SbyDeclaredProperty({
    required this.task,
    required this.kind,
    required this.location,
    required this.name,
  });

  /// The `[tasks]` name.
  final String task;

  /// `ASSERT`, `COVER`, ….
  final String kind;

  /// The location (`task_property.src`).
  final String location;

  /// The hierarchical name (`task_property.hdlname`).
  final String name;

  /// Same key as [SbyStatusRecord.key].
  String get key => '$task\u0000$kind\u0000$location';
}

/// What `status.sqlite` holds for one task.
@immutable
class SbyStatusSnapshot {
  /// Creates a snapshot.
  const SbyStatusSnapshot({
    required this.properties,
    required this.records,
    required this.truncated,
  });

  /// Every declared property, in declaration order.
  final List<SbyDeclaredProperty> properties;

  /// Every status row, oldest first, as records.
  final List<SbyStatusRecord> records;

  /// True when a row cap cut the read short.
  final bool truncated;
}

/// Reads the `status.sqlite` that `sby` writes in a task directory.
///
/// **Read-only, and it writes nothing beside the file.** The database is in
/// WAL mode, and even a read-only open of a WAL database creates a `-shm`
/// file next to it. It is opened with the URI flag `immutable=1`, which
/// tells SQLite the file cannot change while it is open, so no lock, no
/// `-shm` and no `-wal` is touched. The driver reads it only after `sby`
/// has exited, which is what makes that promise true. Content still in an
/// uncheckpointed `-wal` (an `sby` that was killed) is not seen, so a read
/// can only miss statuses, never invent one.
///
/// This is a direct open, pinned in `sqlite_migration_guards_test.dart`:
/// `crux_sqlite` has no read-only open for a database another program
/// owns yet, and its policy open would run SimCrux's own migrations
/// against `sby`'s file. When `crux_sqlite` gains one, this moves onto it
/// and the pin goes.
///
/// The open runs on sqflite's background isolate, and the row count is
/// capped, so a large status history is never one blocking read.
abstract final class SbyStatusDatabase {
  /// The most rows read from either table.
  static const int kMaxRows = 200000;

  static bool _ffiReady = false;

  /// Reads [path] for [task] (every task when null), or returns null when
  /// there is no readable database there.
  static Future<SbyStatusSnapshot?> read(String path, {String? task}) async {
    if (!File(path).existsSync()) return null;
    // The FFI factory itself, never sqflite's global default: replacing
    // that is the trend store's business (and prints a warning each time).
    if (!_ffiReady) {
      sqfliteFfiInit();
      _ffiReady = true;
    }
    final uri = Uri.file(
      File(path).absolute.path,
    ).replace(queryParameters: const <String, String>{'immutable': '1'});
    final Database db;
    try {
      db = await databaseFactoryFfi.openDatabase(
        uri.toString(),
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
    } on DatabaseException {
      return null;
    }
    try {
      final where = task == null ? '' : 'WHERE t.name = ?';
      final args = <Object?>[?task, kMaxRows + 1];
      final propertyRows = await db.rawQuery(
        'SELECT t.name AS task, tp.kind AS kind, tp.src AS src, '
        'tp.hdlname AS hdlname FROM task_property tp '
        'JOIN task t ON tp.task = t.id $where ORDER BY tp.id LIMIT ?',
        args,
      );
      final statusRows = await db.rawQuery(
        'SELECT t.name AS task, t.mode AS mode, tp.kind AS kind, '
        'tp.src AS src, tp.hdlname AS hdlname, s.status AS status, '
        's.data AS data, tr.path AS trace, tr.engine_case AS engine_case '
        'FROM task_property_status s '
        'JOIN task_property tp ON s.task_property = tp.id '
        'JOIN task t ON tp.task = t.id '
        'LEFT JOIN task_trace tr ON s.task_trace = tr.id '
        '$where ORDER BY s.id LIMIT ?',
        args,
      );
      final properties = <SbyDeclaredProperty>[
        for (final row in propertyRows.take(kMaxRows))
          SbyDeclaredProperty(
            task: _text(row['task']),
            kind: _text(row['kind']),
            location: _text(row['src']),
            name: _text(row['hdlname']),
          ),
      ];
      final records = <SbyStatusRecord>[
        for (final row in statusRows.take(kMaxRows)) _record(row),
      ];
      return SbyStatusSnapshot(
        properties: List<SbyDeclaredProperty>.unmodifiable(properties),
        records: List<SbyStatusRecord>.unmodifiable(records),
        truncated:
            propertyRows.length > kMaxRows || statusRows.length > kMaxRows,
      );
    } on DatabaseException {
      // A file that opens but is not sby's schema (or a schema a newer sby
      // changed): no status from it, and the log's verdict stands.
      return null;
    } finally {
      await db.close();
    }
  }

  static String _text(Object? value) => value is String ? value : '';

  static SbyStatusRecord _record(Map<String, Object?> row) {
    int? step;
    String? engine;
    final data = row['data'];
    if (data is String && data.isNotEmpty) {
      try {
        final decoded = jsonDecode(data);
        if (decoded is Map) {
          final s = decoded['step'];
          if (s is int) step = s;
          final e = decoded['engine'];
          if (e is String) engine = e;
        }
      } on FormatException {
        // Unreadable `data`: the status itself still counts.
      }
    }
    final trace = row['trace'];
    final traceText = trace is String && trace.isNotEmpty ? trace : null;
    final engineCase = row['engine_case'];
    return SbyStatusRecord(
      task: _text(row['task']),
      kind: _text(row['kind']),
      location: _text(row['src']),
      name: _text(row['hdlname']),
      status: _text(row['status']),
      mode: row['mode'] is String ? row['mode']! as String : null,
      engine: engine,
      depth: step,
      trace: traceText,
      induction:
          engineCase == 'induction' ||
          (traceText != null && SbyStatusRecord.isInductionTrace(traceText)),
    );
  }
}
