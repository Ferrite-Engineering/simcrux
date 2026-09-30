// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/filelist_expander.dart';

Future<String> Function(String) _fakeReader(Map<String, String> files) {
  // FilelistExpander reads via p.normalize(p.absolute(path)); the POSIX-
  // absolute fixture keys (`/proj/...`) become drive-rooted on Windows
  // (`D:\proj\...`). Normalize both sides so the fake reader is OS-agnostic.
  String key(String path) => p.normalize(p.absolute(path));
  final byPath = {for (final e in files.entries) key(e.key): e.value};
  return (String path) async {
    final normalized = key(path);
    final body = byPath[normalized];
    if (body == null) {
      throw StateError(
        'Fake reader has no entry for `$normalized`. '
        'Available: ${byPath.keys.join(", ")}',
      );
    }
    return body;
  };
}

void main() {
  group('FilelistExpander', () {
    test(
      'expands plain source paths relative to the .f file directory',
      () async {
        const projRoot = '/proj';
        const flPath = '/proj/filelists/cpu.f';
        final reader = _fakeReader({
          flPath: '''
rtl/alu.v
../rtl/cpu.v
# comment line
// another comment

tb/alu_tb.v
''',
        });
        final expander = FilelistExpander(readFile: reader);
        final result = await expander.expand(
          filelistPath: flPath,
          projectRoot: projRoot,
        );
        expect(result.sources, <String>[
          p.join('filelists', 'rtl', 'alu.v'),
          p.join('rtl', 'cpu.v'),
          p.join('filelists', 'tb', 'alu_tb.v'),
        ]);
        expect(result.includeDirs, isEmpty);
        expect(result.defines, isEmpty);
      },
    );

    test('parses +incdir+ and +define+ directives', () async {
      const projRoot = '/proj';
      const flPath = '/proj/lists/build.f';
      final reader = _fakeReader({
        flPath: '''
+incdir+include
+define+SIM=1
+define+WIDTH=32
src/top.v
''',
      });
      final expander = FilelistExpander(readFile: reader);
      final result = await expander.expand(
        filelistPath: flPath,
        projectRoot: projRoot,
      );
      expect(result.sources, [p.join('lists', 'src', 'top.v')]);
      expect(result.includeDirs, [p.join('lists', 'include')]);
      expect(result.defines, {'SIM': '1', 'WIDTH': '32'});
    });

    test('parses -I and -D directives', () async {
      const projRoot = '/proj';
      const flPath = '/proj/build.f';
      final reader = _fakeReader({
        flPath: '''
-I include
-Iinclude/headers
-D SIM=1
-DWIDTH=32
src/top.v
''',
      });
      final expander = FilelistExpander(readFile: reader);
      final result = await expander.expand(
        filelistPath: flPath,
        projectRoot: projRoot,
      );
      expect(result.includeDirs, contains('include'));
      expect(result.includeDirs, contains(p.join('include', 'headers')));
      expect(result.defines, {'SIM': '1', 'WIDTH': '32'});
      expect(result.sources, [p.join('src', 'top.v')]);
    });

    test('treats a bare define as KEY=1', () async {
      const projRoot = '/proj';
      const flPath = '/proj/build.f';
      final reader = _fakeReader({
        flPath: '''
+define+DEBUG
src/top.v
''',
      });
      final expander = FilelistExpander(readFile: reader);
      final result = await expander.expand(
        filelistPath: flPath,
        projectRoot: projRoot,
      );
      expect(result.defines, {'DEBUG': '1'});
    });

    test('honors absolute paths inside the .f file', () async {
      const projRoot = '/proj';
      const flPath = '/proj/build.f';
      // Use paths that are absolute on the host OS: `/absolute/...` is absolute
      // on POSIX but only root-relative on Windows (where the expander would
      // resolve it instead of preserving it). p.rootPrefix yields `/` or `D:\`.
      final root = p.rootPrefix(p.absolute(p.current));
      final absSrc = p.join(root, 'absolute', 'path', 'to', 'foo.v');
      final absInc = p.join(root, 'absolute', 'inc');
      final reader = _fakeReader({
        flPath: '$absSrc\n+incdir+$absInc\n',
      });
      final expander = FilelistExpander(readFile: reader);
      final result = await expander.expand(
        filelistPath: flPath,
        projectRoot: projRoot,
      );
      expect(result.sources, [absSrc]);
      expect(result.includeDirs, [absInc]);
    });

    test('surfaces a ConfigLoaderException on malformed directive', () async {
      const projRoot = '/proj';
      const flPath = '/proj/build.f';
      final reader = _fakeReader({
        flPath: '''
+incdir+
''',
      });
      final expander = FilelistExpander(readFile: reader);
      expect(
        () => expander.expand(filelistPath: flPath, projectRoot: projRoot),
        throwsA(isA<ConfigLoaderException>()),
      );
    });

    test('wraps read failures as ConfigLoaderException', () async {
      Future<String> throwing(String _) async {
        throw const FileSystemException('boom');
      }

      final expander = FilelistExpander(readFile: throwing);
      expect(
        () => expander.expand(
          filelistPath: '/proj/missing.f',
          projectRoot: '/proj',
        ),
        throwsA(isA<ConfigLoaderException>()),
      );
    });
  });
}
