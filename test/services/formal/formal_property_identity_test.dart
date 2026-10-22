// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_io/crux_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/formal_property_status.dart';
import 'package:simcrux/services/formal/formal_property_identity.dart';
import 'package:simcrux/services/formal/formal_reconciliation.dart';

// The id of an unlabelled property is the suite's crux-fnv1a64/1 signature
// over task, kind, file and the property's source text: the same in the next
// run of the same design, different when the property is different.

FormalPropertyResult _property({
  String task = 'prove',
  String kind = 'ASSERT',
  String file = 'top.sv',
  int line = 3,
  String? label,
}) => FormalPropertyResult(
  task: task,
  kind: kind,
  location: '$file:$line',
  rawLocation: '$file:$line.1-$line.20',
  name: 'top._witness_.check',
  status: FormalPropertyStatus.inconclusive,
  label: label,
  file: file,
  line: line,
);

void main() {
  late Directory root;
  late String taskDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('formal_property_identity_');
    taskDir = p.join(root.path, 'work', 'prove');
    Directory(taskDir).createSync(recursive: true);
  });
  tearDown(() => root.deleteSync(recursive: true));

  File source(String name, List<String> lines) =>
      File(p.join(root.path, name))..writeAsStringSync('${lines.join('\n')}\n');

  Future<Map<String, String>> ids(
    List<FormalPropertyResult> properties, {
    String? projectRoot,
  }) => FormalPropertyIdentity.signatures(
    properties: properties,
    projectRoot: projectRoot ?? root.path,
    taskDirectory: taskDir,
  );

  test('uses the shared scheme over task, kind, file and text', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final property = _property();
    final id = (await ids([property]))[property.key];
    expect(
      id,
      CruxSignature.compute(['prove', 'ASSERT', 'top.sv'], '  assert (a);'),
    );
    expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
  });

  test('is the same across two runs of the same design', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final first = await ids([_property()]);
    final second = await ids([_property()]);
    expect(first, isNotEmpty);
    expect(second, first);
  });

  test('does not move when lines are added above, or white space is '
      'reflowed', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final before = (await ids([_property()])).values.single;
    source('top.sv', [
      'module top;',
      '// a new comment',
      '// another',
      '',
      '    assert   (a);   ',
      'endmodule',
    ]);
    final after = (await ids([_property(line: 5)])).values.single;
    expect(after, before);
  });

  test('changes when the property text changes', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final before = (await ids([_property()])).values.single;
    source('top.sv', ['module top;', '', '  assert (a && b);', 'endmodule']);
    final after = (await ids([_property()])).values.single;
    expect(after, isNot(before));
  });

  test('changes with the task, the kind and the file', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    source('other.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final base = (await ids([_property()])).values.single;
    expect((await ids([_property(task: 'bmc')])).values.single, isNot(base));
    expect((await ids([_property(kind: 'COVER')])).values.single, isNot(base));
    expect(
      (await ids([_property(file: 'other.sv')])).values.single,
      isNot(base),
    );
  });

  test('a labelled property gets no signature: its label is its id', () async {
    source('top.sv', ['module top;', '', '  assert (a);', 'endmodule']);
    final labelled = _property(label: 'a_holds');
    expect(await ids([labelled]), isEmpty);
    expect(labelled.crossRunIdentity, 'a_holds');
  });

  test('an unreadable source gives no id, never a guessed one', () async {
    final missing = _property(file: 'gone.sv');
    expect(await ids([missing]), isEmpty);
    source('short.sv', ['module top;']);
    expect(await ids([_property(file: 'short.sv', line: 9)]), isEmpty);
    expect(missing.crossRunIdentity, isNull);
  });

  test('a file outside the project falls back to the task copy', () async {
    final src = Directory(p.join(taskDir, 'src'))..createSync();
    File(
      p.join(src.path, 'top.sv'),
    ).writeAsStringSync('module top;\n\n  assert (a);\nendmodule\n');
    final other = Directory(p.join(root.path, 'elsewhere'))..createSync();
    final id = (await ids([
      _property(),
    ], projectRoot: other.path)).values.single;
    expect(
      id,
      CruxSignature.compute(['prove', 'ASSERT', 'top.sv'], 'assert (a);'),
    );
  });

  test('withSignature feeds crossRunIdentity and changes nothing else', () {
    final property = _property();
    expect(property.crossRunIdentity, isNull);
    final signed = property.withSignature('0123456789abcdef');
    expect(signed.crossRunIdentity, '0123456789abcdef');
    expect(signed.status, property.status);
    expect(signed.key, property.key);
  });
}
