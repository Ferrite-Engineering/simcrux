// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';

import 'posix_keyed_files.dart';

/// The Windows spellings are literals, so these run on a Linux or macOS host
/// and prove what the Windows leg of CI would otherwise be the only one to
/// find (simcrux#23).
void main() {
  group('posixKey', () {
    test('leaves a posix path alone', () {
      expect(posixKey('/proj/simcrux.yaml'), '/proj/simcrux.yaml');
    });

    test('drops the drive and turns backslashes into slashes', () {
      expect(posixKey(r'D:\proj\simcrux.yaml'), '/proj/simcrux.yaml');
    });

    test('accepts a drive with forward slashes and mixed separators', () {
      expect(posixKey('C:/proj/sub.yaml'), '/proj/sub.yaml');
      expect(posixKey(r'C:\proj/tb\top_tb.v'), '/proj/tb/top_tb.v');
    });

    test('folds dot segments, as the loader does', () {
      expect(posixKey(r'D:\proj\inc\..\sub.yaml'), '/proj/sub.yaml');
      expect(posixKey(r'D:\proj\.\sub.yaml'), '/proj/sub.yaml');
    });

    test('keeps a relative path relative', () {
      expect(posixKey(r'tb\alu_tb.v'), 'tb/alu_tb.v');
    });
  });

  group('readFromPosixKeyed', () {
    final read = readFromPosixKeyed({
      '/proj/simcrux.yaml': 'root',
      '/proj/sub.yaml': 'sub',
    });

    test('finds a file by its posix key', () async {
      expect(await read('/proj/sub.yaml'), 'sub');
    });

    test('finds the same file asked for with Windows separators', () async {
      expect(await read(r'D:\proj\simcrux.yaml'), 'root');
      expect(await read(r'D:\proj\sub.yaml'), 'sub');
    });

    test('an unknown path throws, naming both spellings', () {
      expect(
        read(r'D:\proj\missing.yaml'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('/proj/missing.yaml'), contains(r'D:\proj')),
          ),
        ),
      );
    });
  });
}
