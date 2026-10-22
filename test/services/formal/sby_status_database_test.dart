// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/sby_status_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/formal_fixture_checks.dart';

// status.sqlite is sby's file, in WAL mode. Even a read-only open of a WAL
// database writes a `-shm` beside it, so the reader opens it immutable and
// must leave the directory exactly as it found it.

void main() {
  late Directory tmp;

  setUpAll(sqfliteFfiInit);
  setUp(() => tmp = Directory.systemTemp.createTempSync('sby_status_db_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A WAL-mode database with sby's schema and one property, closed.
  Future<String> walDatabase() async {
    final path = p.join(tmp.path, 'status.sqlite');
    final db = await databaseFactoryFfiNoIsolate.openDatabase(path);
    await db.rawQuery('PRAGMA journal_mode=WAL');
    await db.execute(
      'CREATE TABLE task (id INTEGER PRIMARY KEY, workdir TEXT, name TEXT, '
      'mode TEXT, created REAL)',
    );
    await db.execute(
      'CREATE TABLE task_property (id INTEGER PRIMARY KEY, task INTEGER, '
      'src TEXT, name TEXT, hdlname TEXT, kind TEXT, created REAL)',
    );
    await db.execute(
      'CREATE TABLE task_property_status (id INTEGER PRIMARY KEY, '
      'task_property INTEGER, task_trace INTEGER, status TEXT, data TEXT, '
      'created REAL)',
    );
    await db.execute(
      'CREATE TABLE task_trace (id INTEGER PRIMARY KEY, task INTEGER, '
      'trace TEXT, path TEXT, kind TEXT, engine_case TEXT, created REAL)',
    );
    await db.insert('task', {'id': 1, 'name': 'prove', 'mode': 'prove'});
    await db.insert('task_property', {
      'id': 1,
      'task': 1,
      'src': 'a.sv:3.1-3.9',
      'hdlname': 'top.a_x',
      'kind': 'ASSERT',
    });
    await db.insert('task_trace', {
      'id': 1,
      'task': 1,
      'path': 'engine_0/trace_induct.vcd',
      'kind': 'vcd',
      'engine_case': 'induction',
    });
    await db.insert('task_property_status', {
      'id': 1,
      'task_property': 1,
      'task_trace': 1,
      'status': 'FAIL',
      'data': '{"source": "summary_event", "engine": "engine_0"}',
    });
    await db.close();
    return path;
  }

  test('reads a WAL database without writing anything beside it', () async {
    final path = await walDatabase();
    final before = tmp.listSync().map((e) => p.basename(e.path)).toSet();
    expect(before, {'status.sqlite'}, reason: 'the fixture closed cleanly');

    final snapshot = await SbyStatusDatabase.read(path);

    expect(snapshot, isNotNull);
    expect(snapshot!.properties.single.location, 'a.sv:3.1-3.9');
    final record = snapshot.records.single;
    expect(record.status, 'FAIL');
    expect(record.induction, isTrue, reason: 'engine_case induction');
    final after = tmp.listSync().map((e) => p.basename(e.path)).toSet();
    expect(after, before, reason: 'no -shm, no -wal, no journal');
  });

  test(
    'a missing file and a file that is not a database read as none',
    () async {
      expect(await SbyStatusDatabase.read(p.join(tmp.path, 'nope')), isNull);
      final junk = File(p.join(tmp.path, 'status.sqlite'))
        ..writeAsStringSync('not a database');
      expect(await SbyStatusDatabase.read(junk.path), isNull);
    },
  );

  test('a finished database reads, and says nothing was refused', () async {
    final path = await walDatabase();
    final result = await SbyStatusDatabase.readDetailed(path);
    expect(result.unreadable, isNull);
    expect(result.snapshot!.records, hasLength(1));
  });

  test('a leftover non-empty -wal is refused, never read and never '
      'touched', () async {
    final path = await walDatabase();
    final wal = File('$path-wal')..writeAsBytesSync(const <int>[1, 2, 3]);
    final before = tmp.listSync().map((e) => p.basename(e.path)).toSet();

    final result = await SbyStatusDatabase.readDetailed(path);

    expect(result.snapshot, isNull);
    expect(result.unreadable, SbyStatusUnreadable.notCheckpointed);
    expect(await SbyStatusDatabase.read(path), isNull);
    expect(wal.readAsBytesSync(), const <int>[1, 2, 3]);
    final after = tmp.listSync().map((e) => p.basename(e.path)).toSet();
    expect(after, before, reason: 'no -shm, and nothing removed');
    expect(after, isNot(contains('status.sqlite-shm')));
  });

  test('an empty -wal is what a clean close leaves, and reads', () async {
    final path = await walDatabase();
    File('$path-wal').writeAsBytesSync(const <int>[]);
    final result = await SbyStatusDatabase.readDetailed(path);
    expect(result.unreadable, isNull);
    expect(result.snapshot, isNotNull);
  });

  test('every refusal carries its reason', () async {
    expect(
      (await SbyStatusDatabase.readDetailed(
        p.join(tmp.path, 'nope'),
      )).unreadable,
      SbyStatusUnreadable.missing,
    );
    expect(
      (await SbyStatusDatabase.readDetailed(tmp.path)).unreadable,
      SbyStatusUnreadable.notAFile,
    );
    final junk = File(p.join(tmp.path, 'status.sqlite'))
      ..writeAsStringSync('not a database');
    final reason = (await SbyStatusDatabase.readDetailed(junk.path)).unreadable;
    expect(
      reason,
      isIn(<SbyStatusUnreadable>[
        SbyStatusUnreadable.notADatabase,
        SbyStatusUnreadable.unknownSchema,
      ]),
    );
  });

  test('the corpus copy filters by task', () async {
    final path = p.join(
      p.absolute(kFormalFixtureRoot),
      'sby',
      'fifo_slang',
      'captured',
      'status.sqlite',
    );
    expect(File(path).existsSync(), isTrue, reason: path);
    final bug = await SbyStatusDatabase.read(path, task: 'bug');
    expect(bug!.properties.map((d) => d.task).toSet(), {'bug'});
    expect(bug.properties, hasLength(7));
    final fail = bug.records.where((r) => r.status == 'FAIL').toList();
    expect(fail, isNotEmpty);
    expect(
      fail.every((r) => r.location.startsWith('fifo_slang.sv:38.')),
      isTrue,
    );
    expect(fail.first.depth, 8);
    final all = await SbyStatusDatabase.read(path);
    expect(all!.properties.map((d) => d.task).toSet(), {
      'ok',
      'bug',
      'dis',
      'cov',
    });
  });
}
