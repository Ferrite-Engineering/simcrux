// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Static guard: the rehearsal entry point never reaches a release build.
//
// `rehearsal/main.dart` starts SimCrux with a VM service extension that
// clicks, types and takes screenshots on request. That is what a rehearsal
// of a recording script needs from a debug build, and it is never something
// a shipped build should carry. Three things keep it out:
//
//  * it lives outside lib/, so a build compiles it only when it is named as
//    the target, and nothing in lib/ may import it;
//  * no build script, workflow or platform project names it;
//  * the extension refuses to register in a release build at all.
//
// This test holds the first two and checks the third is still in place.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Files that build, package or release SimCrux. None may name the
/// rehearsal entry point.
const _buildRoots = [
  '.github',
  'scripts',
  'tool',
  'installer',
  'linux',
  'macos',
  'windows',
  'web',
];

const _buildSuffixes = [
  '.sh',
  '.yml',
  '.yaml',
  '.ps1',
  '.bat',
  '.cmake',
  '.txt',
  '.xcconfig',
  '.pbxproj',
  '.xcscheme',
  '.iss',
  '.json',
  '.py',
  '.dart',
];

final _mentions = RegExp(r'rehearsal/|crux_rehearsal|ext\.crux\.rehearsal');

List<File> _filesUnder(String root, bool Function(String path) wanted) {
  final dir = Directory(root);
  if (!dir.existsSync()) return const [];
  return [
    for (final entity in dir.listSync(recursive: true))
      if (entity is File &&
          !entity.path.contains('${p.separator}ephemeral${p.separator}') &&
          !entity.path.contains('${p.separator}build${p.separator}') &&
          wanted(entity.path))
        entity,
  ];
}

List<String> _offenders(Iterable<File> files) => [
  for (final file in files)
    if (_mentions.hasMatch(file.readAsStringSync()))
      p.relative(file.path).replaceAll(r'\', '/'),
];

void main() {
  test('the rehearsal entry point exists outside lib/', () {
    expect(File('rehearsal/main.dart').existsSync(), isTrue);
    expect(File('rehearsal/crux_rehearsal.dart').existsSync(), isTrue);
    expect(Directory('lib/rehearsal').existsSync(), isFalse);
  });

  test('nothing in lib/ imports the rehearsal code', () {
    final offenders = _offenders(
      _filesUnder('lib', (path) => path.endsWith('.dart')),
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'lib/ is what every release build compiles; the rehearsal '
          'extension must stay reachable only from rehearsal/main.dart',
    );
  });

  test('no build script, workflow or platform project names it', () {
    final files = [
      for (final root in _buildRoots)
        ..._filesUnder(root, (path) => _buildSuffixes.any(path.endsWith)),
      for (final name in ['Makefile', 'pubspec.yaml', 'wrangler.jsonc'])
        if (File(name).existsSync()) File(name),
    ];
    expect(files, isNotEmpty, reason: 'run from the repository root');
    expect(
      _offenders(files),
      isEmpty,
      reason:
          'a release build must compile lib/main.dart; build the rehearsal '
          'target by hand, in debug, for an unattended rehearsal only',
    );
  });

  test('the entry point registers the extension before the app starts', () {
    final source = File('rehearsal/main.dart').readAsStringSync();
    final register = source.indexOf('registerCruxRehearsal();');
    final start = source.indexOf('app.main(args)');
    expect(register, isNonNegative);
    expect(start, greaterThan(register));
  });

  test('the extension refuses to register in a release build', () {
    final source = File('rehearsal/crux_rehearsal.dart').readAsStringSync();
    expect(
      source,
      matches(RegExp(r'if \(kReleaseMode\) \{\s*throw StateError')),
    );
  });
}
