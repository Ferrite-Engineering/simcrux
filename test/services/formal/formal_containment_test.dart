// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/formal/formal_containment.dart';

// Adversarial names and paths for the formal drivers' containment rules
// (VERIFICATION_GUIDE.md §26.8). Every case runs on Linux: both separator
// spellings and both absolute spellings are refused on every host.

void main() {
  group('a task directory is one safe segment', () {
    const refused = <String, String>{
      '': 'empty',
      '..': 'parent',
      '.': 'working directory',
      '../x': 'separator',
      'a/b': 'separator',
      r'a\b': 'separator',
      r'..\..\x': 'separator',
      '/etc': 'absolute',
      r'C:\Windows': 'absolute',
      'C:/Windows': 'absolute',
      r'\\server\share': 'absolute',
      'C:x': 'colon',
      'task:stream': 'colon',
      'a\u0000b': 'NUL',
      'a\nb': 'line break',
    };
    for (final MapEntry(key: name, value: why) in refused.entries) {
      test(
        'refuses ${name.replaceAll('\u0000', r'\0').replaceAll('\n', r'\n')} ($why)',
        () {
          expect(FormalContainment.segmentProblem(name), isNotNull);
        },
      );
    }

    for (final name in ['prove', 'prove_bug', 'insn_add_ch0', 'a.b-c', '...']) {
      test('accepts $name', () {
        expect(FormalContainment.segmentProblem(name), isNull);
      });
    }
  });

  group('a path a tool announced stays inside its directory', () {
    late Directory root;
    late Directory task;
    late Directory outside;

    setUp(() {
      root = Directory.systemTemp.createTempSync('formal_contain_');
      task = Directory(p.join(root.path, 'task'))..createSync();
      outside = Directory(p.join(root.path, 'outside'))..createSync();
      File(p.join(outside.path, 'secret.vcd')).writeAsStringSync('x');
      Directory(p.join(task.path, 'engine_0')).createSync();
      File(p.join(task.path, 'engine_0', 'trace.vcd')).writeAsStringSync('x');
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('a relative path inside is accepted', () {
      expect(
        FormalContainment.containedPath(task.path, 'engine_0/trace.vcd'),
        p.join(task.path, 'engine_0', 'trace.vcd'),
      );
    });

    test('an absolute path inside is accepted', () {
      final inside = p.join(task.path, 'engine_0', 'trace.vcd');
      expect(FormalContainment.containedPath(task.path, inside), inside);
    });

    test('../ out of the directory is refused', () {
      expect(
        FormalContainment.containedPath(task.path, '../outside/secret.vcd'),
        isNull,
      );
    });

    test('an absolute path elsewhere is refused', () {
      expect(
        FormalContainment.containedPath(
          task.path,
          p.join(outside.path, 'secret.vcd'),
        ),
        isNull,
      );
      expect(FormalContainment.containedPath(task.path, '/etc/passwd'), isNull);
    });

    test('the directory itself is not a path inside it', () {
      expect(FormalContainment.containedPath(task.path, '.'), isNull);
      expect(FormalContainment.containedPath(task.path, ''), isNull);
    });

    test('a NUL is refused', () {
      expect(
        FormalContainment.containedPath(task.path, 'engine_0/\u0000x'),
        isNull,
      );
    });

    test('a symlink inside that points out is refused', () {
      final link = Link(p.join(task.path, 'engine_0', 'escape.vcd'))
        ..createSync(p.join(outside.path, 'secret.vcd'));
      expect(link.existsSync(), isTrue);
      expect(
        FormalContainment.containedPath(task.path, 'engine_0/escape.vcd'),
        isNull,
      );
    });

    test('a symlinked directory inside that points out is refused', () {
      Link(p.join(task.path, 'engine_1')).createSync(outside.path);
      expect(
        FormalContainment.containedPath(task.path, 'engine_1/secret.vcd'),
        isNull,
      );
    });

    test('Windows-shaped escapes are refused on this host too', () {
      for (final hostile in [
        r'..\outside\secret.vcd',
        r'C:\outside\secret.vcd',
        r'\\server\share\secret.vcd',
      ]) {
        final resolved = FormalContainment.containedPath(task.path, hostile);
        // On POSIX a backslash is an ordinary character, so the name stays
        // a single file inside the directory (which does not exist): never a
        // path outside it.
        if (resolved != null) {
          expect(p.isWithin(task.path, resolved), isTrue, reason: hostile);
          expect(File(resolved).existsSync(), isFalse, reason: hostile);
        }
      }
    });
  });
}
