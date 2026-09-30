// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/services/result_store/ndjson_recovery.dart';

/// Persistence durability & crash recovery (ndjson side). A crash
/// mid-run can leave `results.ndjson` with a truncated or garbled trailing
/// record; recovery trims to the last complete record and reports how many
/// survived, idempotently.
void main() {
  const recovery = FileNdjsonRecovery();
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('simcrux_ndjson_'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String row(int i) =>
      jsonEncode(<String, Object?>{'testId': 't$i', 'ok': true});

  File write(String contents) =>
      File('${tmp.path}/results.ndjson')..writeAsStringSync(contents);

  // 1. cleanTail — well-formed file, every line complete, trailing newline.
  test('cleanTail: no-op, all records retained', () async {
    final file = write('${row(0)}\n${row(1)}\n${row(2)}\n');
    final result = await recovery.recover(file.path);
    expect(result.trimmedPartialTail, isFalse);
    expect(result.recoveredRecords, 3);
    expect(file.readAsStringSync(), '${row(0)}\n${row(1)}\n${row(2)}\n');
  });

  // 2. truncatedLastLine — file ends mid-record (no trailing newline).
  // PRIMARY MUTATION TARGET: a recovery that returns the raw lines without
  // trimming the partial tail yields a malformed Nth record.
  test('truncatedLastLine: partial tail trimmed, N-1 recovered', () async {
    final file = write('${row(0)}\n${row(1)}\n{"testId":"t2","ok":tr');
    final result = await recovery.recover(file.path);
    expect(result.trimmedPartialTail, isTrue);
    expect(result.recoveredRecords, 2);
    expect(file.readAsStringSync(), '${row(0)}\n${row(1)}\n');
  });

  // 3. garbledLastLine — last line is framed (trailing newline) but fails
  // JSON parse (interleaved write).
  test('garbledLastLine: trimmed to the last parseable record', () async {
    final file = write('${row(0)}\n${row(1)}\n{"testId":"t2",,,}\n');
    final result = await recovery.recover(file.path);
    expect(result.trimmedPartialTail, isTrue);
    expect(result.recoveredRecords, 2);
    expect(file.readAsStringSync(), '${row(0)}\n${row(1)}\n');
  });

  // 4. emptyFile / zeroByteFile.
  test('emptyFile: 0 records, no throw, fresh append allowed', () async {
    final file = write('');
    final result = await recovery.recover(file.path);
    expect(result.recoveredRecords, 0);
    expect(result.trimmedPartialTail, isFalse);
    // A fresh run can still append.
    file.writeAsStringSync('${row(0)}\n', mode: FileMode.append);
    expect(file.readAsStringSync(), '${row(0)}\n');
  });

  test('missing file: clean no-op', () async {
    final result = await recovery.recover('${tmp.path}/does_not_exist.ndjson');
    expect(result, NdjsonRecoveryResult.clean);
  });

  // 6. midRecordNewline — a value legitimately containing \n is escaped by
  // the encoder so it never looks like a record boundary.
  test('midRecordNewline: embedded newline value is not mis-split', () async {
    final r = jsonEncode(<String, Object?>{
      'testId': 't0',
      'log': 'line one\nline two\nline three',
    });
    // jsonEncode escaped the newlines, so the record is a single physical
    // line — recovery must see exactly one record, not three.
    expect(r.contains('\n'), isFalse);
    final file = write('$r\n${row(1)}\n');
    final result = await recovery.recover(file.path);
    expect(result.trimmedPartialTail, isFalse);
    expect(result.recoveredRecords, 2);
  });

  // 12. recoveryIsIdempotent — running twice yields the same result.
  test('recoveryIsIdempotent: second pass is a no-op', () async {
    final file = write('${row(0)}\n${row(1)}\n{"partial":');
    final first = await recovery.recover(file.path);
    expect(first.trimmedPartialTail, isTrue);
    expect(first.recoveredRecords, 2);
    final afterFirst = file.readAsStringSync();

    final second = await recovery.recover(file.path);
    expect(second.trimmedPartialTail, isFalse);
    expect(second.recoveredRecords, 2);
    expect(file.readAsStringSync(), afterFirst);
  });

  test('multiple trailing garbled records all trim to last complete', () async {
    final file = write('${row(0)}\n{"bad":\n{"also bad"\n');
    final result = await recovery.recover(file.path);
    expect(result.recoveredRecords, 1);
    expect(file.readAsStringSync(), '${row(0)}\n');
  });

  test('NoopNdjsonRecovery never trims', () async {
    const noop = NoopNdjsonRecovery();
    final file = write('${row(0)}\n{"partial":');
    final result = await noop.recover(file.path);
    expect(result.trimmedPartialTail, isFalse);
    expect(result.repaired, isFalse);
    // File untouched.
    expect(file.readAsStringSync(), '${row(0)}\n{"partial":');
  });
}
