// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/flow_archive_extractor.dart';

/// A zipped CI artifact is extracted into SimCrux's own scratch, contained
/// and bounded: every hostile entry refuses the whole archive before
/// anything is written, and nothing lands outside the extraction.
void main() {
  late Directory tmp;
  late String scratch;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('flow_zip_');
    scratch = p.join(tmp.path, 'scratch');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Writes a zip of [entries] (name to content) and returns its path.
  String zip(
    Map<String, String> entries, {
    String name = 'GDS_logs.zip',
    Map<String, int> modes = const {},
  }) {
    final archive = Archive();
    for (final MapEntry(:key, :value) in entries.entries) {
      final file = ArchiveFile.bytes(key, utf8.encode(value));
      if (modes[key] case final mode?) file.mode = mode;
      archive.add(file);
    }
    final path = p.join(tmp.path, name);
    File(path).writeAsBytesSync(ZipEncoder().encodeBytes(archive));
    return path;
  }

  /// Every file under [dir], relative.
  Set<String> filesUnder(String dir) => <String>{
    if (Directory(dir).existsSync())
      for (final e in Directory(dir).listSync(recursive: true))
        if (e is File) p.relative(e.path, from: dir),
  };

  test('a run inside the archive is extracted under the scratch', () async {
    final path = zip(<String, String>{
      'runs/adder/r1/report.json': '{}',
      'runs/adder/r1/pnr.log': 'Info: done',
    });
    final result = await FlowArchiveExtractor(scratch: scratch).extract(path);
    expect(result.ok, isTrue, reason: result.message);
    expect(p.isWithin(scratch, result.directory!), isTrue);
    expect(filesUnder(result.directory!), <String>{
      p.join('runs', 'adder', 'r1', 'report.json'),
      p.join('runs', 'adder', 'r1', 'pnr.log'),
      FlowArchiveExtractor.kCompleteMarker,
    });
    // Nothing next to the archive, nothing in the project.
    expect(filesUnder(tmp.path).where((f) => !f.startsWith('scratch')), {
      'GDS_logs.zip',
    });
  });

  test(
    'extracting the same artifact twice reuses the first extraction',
    () async {
      final path = zip(<String, String>{'runs/a/report.json': '{}'});
      final extractor = FlowArchiveExtractor(scratch: scratch);
      final first = await extractor.extract(path);
      final second = await extractor.extract(path);
      expect(second.directory, first.directory);
      expect(Directory(scratch).listSync(), hasLength(1));
    },
  );

  test('a Windows-style path inside the archive is honoured', () async {
    final path = zip(<String, String>{r'runs\a\report.json': '{}'});
    final result = await FlowArchiveExtractor(scratch: scratch).extract(path);
    expect(result.ok, isTrue, reason: result.message);
    expect(
      File(p.join(result.directory!, 'runs', 'a', 'report.json')).existsSync(),
      isTrue,
    );
  });

  group('refusals, each before anything is written', () {
    Future<FlowArchiveExtraction> refused(
      Map<String, String> entries, {
      FlowArchiveLimits limits = FlowArchiveLimits.defaults,
      Map<String, int> modes = const {},
    }) async {
      final result = await FlowArchiveExtractor(
        scratch: scratch,
        limits: limits,
      ).extract(zip(entries, modes: modes));
      expect(result.ok, isFalse);
      expect(result.message, isNotEmpty);
      // The plan refuses before an extraction directory is even made.
      expect(filesUnder(scratch), isEmpty);
      return result;
    }

    test('an absolute path', () async {
      final r = await refused(<String, String>{'/etc/evil': 'x'});
      expect(r.refusal, FlowArchiveRefusal.absolutePath);
    });

    test('a drive-letter path', () async {
      final r = await refused(<String, String>{r'C:\Windows\evil': 'x'});
      expect(r.refusal, FlowArchiveRefusal.absolutePath);
    });

    test('a UNC path', () async {
      final r = await refused(<String, String>{r'\\host\share\evil': 'x'});
      expect(r.refusal, FlowArchiveRefusal.absolutePath);
    });

    test('a ".." segment', () async {
      final r = await refused(<String, String>{'runs/../../evil': 'x'});
      expect(r.refusal, FlowArchiveRefusal.parentSegment);
    });

    test('a ".." segment written with backslashes', () async {
      final r = await refused(<String, String>{r'runs\..\..\evil': 'x'});
      expect(r.refusal, FlowArchiveRefusal.parentSegment);
    });

    test('a symbolic link', () async {
      final r = await refused(
        <String, String>{'runs/link': '/etc/passwd'},
        modes: <String, int>{'runs/link': 0xa1ff},
      );
      expect(r.refusal, FlowArchiveRefusal.symlink);
    });

    test('a NUL in a name', () async {
      final r = await refused(<String, String>{'runs/a\u0000b': 'x'});
      expect(r.refusal, FlowArchiveRefusal.unsafeName);
    });

    test('a name nested deeper than the limit', () async {
      final r = await refused(
        <String, String>{'a/b/c/d/e/f': 'x'},
        limits: const FlowArchiveLimits(maxDepth: 4),
      );
      expect(r.refusal, FlowArchiveRefusal.unsafeName);
    });

    test('more entries than the limit', () async {
      final r = await refused(
        <String, String>{for (var i = 0; i < 6; i++) 'runs/f$i': 'x'},
        limits: const FlowArchiveLimits(maxEntries: 5),
      );
      expect(r.refusal, FlowArchiveRefusal.tooManyEntries);
    });

    test('one entry larger than the per-entry limit', () async {
      final r = await refused(
        <String, String>{'runs/big': 'x' * 200},
        limits: const FlowArchiveLimits(maxEntryBytes: 100),
      );
      expect(r.refusal, FlowArchiveRefusal.entryTooLarge);
    });

    test('entries together larger than the total limit', () async {
      final r = await refused(
        <String, String>{
          for (var i = 0; i < 4; i++) 'runs/f$i': 'x' * 60,
        },
        limits: const FlowArchiveLimits(
          maxEntryBytes: 100,
          maxTotalBytes: 200,
        ),
      );
      expect(r.refusal, FlowArchiveRefusal.totalTooLarge);
    });

    test('an archive file larger than the limit', () async {
      final r = await refused(
        <String, String>{'runs/a': 'x' * 400},
        limits: const FlowArchiveLimits(maxArchiveBytes: 100),
      );
      expect(r.refusal, FlowArchiveRefusal.totalTooLarge);
    });
  });

  test('a file that is not a zip is unreadable', () async {
    final path = p.join(tmp.path, 'not.zip');
    File(path).writeAsStringSync('PK but not really');
    final result = await FlowArchiveExtractor(scratch: scratch).extract(path);
    expect(result.refusal, FlowArchiveRefusal.unreadable);
  });

  test('the name check alone', () {
    const extractor = FlowArchiveExtractor();
    expect(extractor.entrySegments('a/./b//c').segments, ['a', 'b', 'c']);
    expect(extractor.entrySegments('').refusal, FlowArchiveRefusal.unsafeName);
    expect(
      extractor.entrySegments('~/x').refusal,
      FlowArchiveRefusal.absolutePath,
    );
  });
}
