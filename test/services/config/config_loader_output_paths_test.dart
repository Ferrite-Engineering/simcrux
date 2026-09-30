// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// The loader half of the output-path rule: `output.results_path` and
/// `output.summary_path` name files a `--ci` run creates and truncates, so a
/// value that leads outside the project directory stops the project from
/// loading, at the value's line and column, unless project tooling is
/// allowed. The writer applies the same rule again before it opens either
/// file (`streaming_results_writer_test.dart`).
void main() {
  late Directory tmp;
  late String project;
  late String projectFile;

  setUp(() {
    tmp = Directory(
      Directory.systemTemp
          .createTempSync('simcrux_output_loader_')
          .resolveSymbolicLinksSync(),
    );
    project = p.join(tmp.path, 'project');
    Directory(project).createSync();
    projectFile = p.join(project, 'simcrux.yaml');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // The value is spliced in as written, so each case chooses its own YAML
  // spelling: double-quoted where the shape needs an escape, single-quoted
  // for a path, whose Windows backslashes a double-quoted scalar would read
  // as escapes.
  String withOutput(String key, String scalar) =>
      '''
version: '1'
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
output:
  $key: $scalar
''';

  // Line 10 is `  <key>: <value>`; the span starts at the value, after two
  // spaces of indent and `<key>: `.
  const valueLine = 10;
  int valueColumn(String key) => 2 + '$key: '.length + 1;

  List<ConfigLoaderError> errorsFrom(String yaml, {bool allow = false}) {
    final loader = ConfigLoader(
      readFile: (_) async => '',
      allowProjectDefinedTooling: allow,
    );
    try {
      loader.parse(yaml, projectFile);
      return const <ConfigLoaderError>[];
    } on ConfigLoaderException catch (e) {
      return e.errors;
    }
  }

  // Each shape, its YAML spelling, and the reason the message gives.
  final refused = <(String, String, String)>[
    ('a climb with ../', '../../.zshrc', 'climbs out'),
    ('a climb through a subdirectory', 'build/../../victim.txt', 'climbs out'),
    (r'a climb with ..\', r"'..\..\victim.txt'", 'climbs out'),
    (
      'an absolute path elsewhere',
      "'${p.join(Directory.systemTemp.path, 'victim.txt')}'",
      'absolute path outside',
    ),
    ('the project directory itself', '.', 'itself'),
    ('a NUL byte', r'"a\0b"', 'NUL byte'),
    ('empty', '""', 'empty'),
  ];

  for (final key in const ['results_path', 'summary_path']) {
    group('output.$key', () {
      for (final (shape, scalar, reason) in refused) {
        test('$shape is refused at its line and column', () {
          final errors = errorsFrom(withOutput(key, scalar));
          final error = errors.singleWhere(
            (e) => e.message.contains('output.$key'),
            orElse: () => fail('loaded clean: `$key: $scalar` was accepted'),
          );
          expect(error.path, projectFile);
          expect(error.line, valueLine, reason: error.message);
          expect(error.column, valueColumn(key), reason: error.message);
          expect(error.severity, ConfigLoaderErrorSeverity.error);
          expect(error.message, contains(reason));
        });
      }

      test(
        'a directory link that leads out is refused at its line and column',
        () {
          final outside = Directory(p.join(tmp.path, 'outside'))..createSync();
          Link(p.join(project, 'build')).createSync(outside.path);
          final errors = errorsFrom(withOutput(key, 'build/out.json'));
          final error = errors.singleWhere(
            (e) => e.message.contains('output.$key'),
            orElse: () => fail('loaded clean through a link that leads out'),
          );
          expect(error.line, valueLine);
          expect(error.column, valueColumn(key));
          expect(error.message, contains('symbolic links'));
        },
        skip: Platform.isWindows ? 'creating links needs a privilege' : false,
      );

      test('allowing project tooling lifts it', () {
        final elsewhere = p.join(Directory.systemTemp.path, 'artifacts', 'r');
        for (final value in ['../../shared/out.json', elsewhere]) {
          final config = ConfigLoader(
            readFile: (_) async => '',
            allowProjectDefinedTooling: true,
          ).parse(withOutput(key, "'$value'"), projectFile);
          final loaded = key == 'results_path'
              ? config.output.streamingResultsPath
              : config.output.streamingSummaryPath;
          expect(loaded, value);
        }
      });

      for (final value in [
        'out.json',
        'build/out.json',
        'build/../out.json',
      ]) {
        test('"$value" loads unchanged', () {
          expect(errorsFrom(withOutput(key, value)), isEmpty);
        });
      }

      test('an absolute path inside the project loads unchanged', () {
        final inside = p.join(project, 'build', 'out.json');
        expect(errorsFrom(withOutput(key, "'$inside'")), isEmpty);
      });

      test('a value that is not a string is refused, not ignored', () {
        final error = errorsFrom(withOutput(key, '5')).single;
        expect(error.message, contains('`output.$key` must be a path string'));
        expect(error.line, valueLine);
      });
    });
  }

  test('the message says why, and how to write elsewhere on purpose', () {
    final message = errorsFrom(
      withOutput('results_path', '../../.zshrc'),
    ).single.message;
    expect(message, contains('`output.results_path`'));
    expect(message, contains('"../../.zshrc"'));
    expect(message, contains('truncates'));
    expect(message, contains(project));
    expect(message, contains('--allow-project-tooling'));
  });
}
