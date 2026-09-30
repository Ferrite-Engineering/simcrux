// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/workspace/services/crux_project_resolution.dart';

/// SimCrux's half of the `<design>.crux-project` contract.
void main() {
  const resolver = CruxProjectResolver();

  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('sc_crux_project'));
  tearDown(() => tmp.deleteSync(recursive: true));

  const uartYaml =
      'version: 1\nname: uart\nartifacts:\n  simulation: sim/simcrux.yaml\n';

  ({String manifest, String dir}) writeDesign(
    String yaml, {
    String fileName = 'uart.crux-project',
    List<String> files = const <String>[],
  }) {
    final dir = Directory(p.join(tmp.path, 'uart'))
      ..createSync(recursive: true);
    for (final f in files) {
      File(p.join(dir.path, f))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
    }
    final manifest = p.join(dir.path, fileName);
    File(manifest).writeAsStringSync(yaml);
    return (manifest: manifest, dir: dir.path);
  }

  test('an ordinary simcrux.yaml passes through untouched', () {
    final r = resolver.resolve('/d/simcrux.yaml');
    expect(r, isA<NotAManifest>());
    expect((r as NotAManifest).path, '/d/simcrux.yaml');
  });

  test('a file that only mentions the extension is not a manifest', () {
    final notes = File(p.join(tmp.path, 'notes.crux-project.txt'))
      ..writeAsStringSync(uartYaml);
    expect(resolver.resolve(notes.path), isA<NotAManifest>());
  });

  test('a named manifest resolves to its config and design id', () {
    final d = writeDesign(uartYaml, files: ['sim/simcrux.yaml']);
    final r = resolver.resolve(d.manifest);
    expect(r, isA<ManifestSimulation>());
    final s = r as ManifestSimulation;
    // p.join, not a POSIX literal: this is a host-resolved absolute path, so
    // on a Windows runner the tail legitimately uses backslashes.
    expect(s.configPath, endsWith(p.join('sim', 'simcrux.yaml')));
    expect(s.displayName, 'uart');
    expect(s.designId, cxpDesignIdForPath(d.dir));
    expect(s.manifestPath, d.manifest);
    expect(s.isLegacyFileName, isFalse);
  });

  test('the extension matches case-insensitively, as pickers match it', () {
    final d = writeDesign(
      uartYaml,
      fileName: 'UART.CRUX-PROJECT',
      files: ['sim/simcrux.yaml'],
    );
    expect(resolver.resolve(d.manifest), isA<ManifestSimulation>());
  });

  test('a legacy bare .crux-project still opens, flagged for a rename', () {
    final d = writeDesign(
      uartYaml,
      fileName: '.crux-project',
      files: ['sim/simcrux.yaml'],
    );
    final r = resolver.resolve(d.manifest);
    expect(r, isA<ManifestSimulation>());
    final s = r as ManifestSimulation;
    expect(s.isLegacyFileName, isTrue);
    // The design directory's name plus the extension: what the notice tells
    // the user to rename the file to.
    expect(s.suggestedFileName, 'uart.crux-project');
    // crux_project's own English notice stays in the warnings; SimCrux shows
    // its localized one instead.
    expect(s.warnings, isNotEmpty);
  });

  test('a design directory resolves through the one manifest inside it', () {
    final d = writeDesign(uartYaml, files: ['sim/simcrux.yaml']);
    final r = resolver.resolve(d.dir);
    expect(r, isA<ManifestSimulation>());
    final s = r as ManifestSimulation;
    expect(s.manifestPath, d.manifest);
    // Same design identity whether the directory or the file was opened.
    expect(
      s.designId,
      (resolver.resolve(d.manifest) as ManifestSimulation).designId,
    );
  });

  test('a directory with no manifest passes through untouched', () {
    expect(resolver.resolve(tmp.path), isA<NotAManifest>());
  });

  test('a directory holding two manifests opens neither and names both', () {
    final d = writeDesign(uartYaml, files: ['sim/simcrux.yaml']);
    File(p.join(d.dir, 'uart_old.crux-project')).writeAsStringSync(uartYaml);
    final r = resolver.resolve(d.dir);
    expect(r, isA<ManifestAmbiguous>());
    final a = r as ManifestAmbiguous;
    expect(p.equals(a.directory, d.dir), isTrue);
    expect(a.candidates.map(p.basename), [
      'uart.crux-project',
      'uart_old.crux-project',
    ]);
  });

  test('the legacy file beside a named one counts as two', () {
    final d = writeDesign(uartYaml, files: ['sim/simcrux.yaml']);
    File(p.join(d.dir, '.crux-project')).writeAsStringSync(uartYaml);
    expect(resolver.resolve(d.dir), isA<ManifestAmbiguous>());
    // Naming one file is never ambiguous.
    expect(resolver.resolve(d.manifest), isA<ManifestSimulation>());
  });

  test('a manifest with no simulation entry names the design', () {
    final d = writeDesign(
      'version: 1\nname: uart\nartifacts:\n  waveform: sim/u.vcd\n',
    );
    final r = resolver.resolve(d.manifest);
    expect(r, isA<ManifestNoSimulation>());
    expect((r as ManifestNoSimulation).displayName, 'uart');
  });

  test('a named-but-missing config names the path', () {
    final d = writeDesign(
      'version: 1\nartifacts:\n  simulation: gone.yaml\n',
    );
    final r = resolver.resolve(d.manifest);
    expect(r, isA<ManifestConfigMissing>());
    expect((r as ManifestConfigMissing).configPath, 'gone.yaml');
  });

  test('an invalid manifest is reported, not opened', () {
    final d = writeDesign('name: no version\n');
    final r = resolver.resolve(d.manifest);
    expect(r, isA<ManifestInvalid>());
    final invalid = r as ManifestInvalid;
    expect(invalid.detail, contains('version'));
    expect(invalid.manifestPath, d.manifest);
  });
}
