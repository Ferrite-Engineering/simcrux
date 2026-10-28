// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/services/flow/flow_archive_extractor.dart';
import 'package:simcrux/services/job_scheduler/gls_scratch.dart';
import 'package:simcrux/services/scratch/simcrux_scratch.dart';

// SimCrux's own scratch never sits at a fixed name in Linux's shared /tmp,
// and a base another user could have made or swapped is refused rather than
// written into.
//
// Outside test/services because it runs `chmod` to make a world-writable
// directory, and test/services spawns no real process.
void main() {
  group('SimcruxScratch.defaultBase', () {
    test('on Linux is in the user cache directory, not the system temp', () {
      final base = SimcruxScratch.defaultBase(
        environment: const {'HOME': '/home/ada'},
        operatingSystem: 'linux',
        systemTemp: '/tmp',
      );
      expect(base, '/home/ada/.cache/simcrux');
    });

    test(r'on Linux follows an absolute $XDG_CACHE_HOME', () {
      final base = SimcruxScratch.defaultBase(
        environment: const {'HOME': '/home/ada', 'XDG_CACHE_HOME': '/c/ada'},
        operatingSystem: 'linux',
        systemTemp: '/tmp',
      );
      expect(base, '/c/ada/simcrux');
    });

    test(r'on Linux ignores a relative $XDG_CACHE_HOME', () {
      final base = SimcruxScratch.defaultBase(
        environment: const {'HOME': '/home/ada', 'XDG_CACHE_HOME': 'cache'},
        operatingSystem: 'linux',
        systemTemp: '/tmp',
      );
      expect(base, '/home/ada/.cache/simcrux');
    });

    test('on Linux without a home is a fresh directory, not a fixed name', () {
      final temp = Directory.systemTemp.createTempSync('scratch_nohome_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final base = SimcruxScratch.defaultBase(
        environment: const {},
        operatingSystem: 'linux',
        systemTemp: temp.path,
      );
      expect(base, isNot(p.join(temp.path, SimcruxScratch.kName)));
      expect(p.basename(base), startsWith('${SimcruxScratch.kName}-'));
      if (!Platform.isWindows) {
        // Made under the umask (0775 under 002) it would be refused, and
        // under 022 others could read it.
        expect(FileStat.statSync(base).mode & 0x3F, 0, reason: 'mode 0700');
      }
    });

    test('elsewhere is in the per-user system temporary directory', () {
      expect(
        SimcruxScratch.defaultBase(
          environment: const {'HOME': '/Users/ada'},
          operatingSystem: 'macos',
          systemTemp: '/var/folders/x/T',
        ),
        p.join('/var/folders/x/T', 'simcrux'),
      );
    });

    test('gate level, ingest and the scheduler share the one base', () {
      final base = SimcruxScratch.defaultBase();
      expect(p.isWithin(base, SimcruxScratch.gateLevel()), isTrue);
      expect(p.isWithin(base, SimcruxScratch.ingest()), isTrue);
      expect(SimcruxScratch.jobs(), base);
      expect(GlsScratch().root, SimcruxScratch.gateLevel());
    });
  });

  group('SimcruxScratch.chmodExecutable', () {
    test('is a fixed path when one exists', () {
      expect(
        SimcruxScratch.chmodExecutable(exists: (p) => p == '/usr/bin/chmod'),
        '/usr/bin/chmod',
      );
    });

    test('is found on PATH when neither fixed path exists (NixOS)', () {
      expect(SimcruxScratch.chmodExecutable(exists: (_) => false), 'chmod');
    });
  });

  group('SimcruxScratch.prepare', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('simcrux_scratch_');
      SimcruxScratch.resetForTesting();
    });

    tearDown(() {
      SimcruxScratch.runProcess = Process.runSync;
      SimcruxScratch.resetForTesting();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('refuses a base that belongs to another user', () {
      // A 0755 base someone else made: its mode passes, but chmod, which
      // only the owner may run on it, fails.
      final base = Directory(p.join(tmp.path, 'simcrux'))..createSync();
      // Set, not left to the umask: under 002 it would be 0775 and refused
      // by the mode check before ownership is asked.
      expect(Process.runSync('chmod', ['755', base.path]).exitCode, 0);
      SimcruxScratch.runProcess = (exe, args) => ProcessResult(
        0,
        args.first == 'u+rwx' ? 1 : 0,
        '',
        'Operation not permitted',
      );
      expect(
        () => SimcruxScratch.prepare(p.join(base.path, 'gls'), base: base.path),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            contains('another user'),
          ),
        ),
      );
      expect(Directory(p.join(base.path, 'gls')).existsSync(), isFalse);
    }, skip: Platform.isWindows ? 'no POSIX owners on Windows' : false);

    test("probes the user's own base once, and leaves its mode alone", () {
      final base = p.join(tmp.path, 'simcrux');
      SimcruxScratch.prepare(base, base: base);
      final before = FileStat.statSync(base).mode;
      final probes = <List<String>>[];
      SimcruxScratch.resetForTesting();
      SimcruxScratch.runProcess = (exe, args) {
        probes.add(args);
        return Process.runSync(exe, args);
      };
      for (var i = 0; i < 3; i++) {
        SimcruxScratch.prepare(p.join(base, 'runs'), base: base);
      }
      expect(probes, hasLength(1));
      expect(probes.single.first, 'u+rwx');
      expect(FileStat.statSync(base).mode, before);
    }, skip: Platform.isWindows ? 'no POSIX owners on Windows' : false);

    test('makes a missing base private to the user', () {
      final base = p.join(tmp.path, 'simcrux');
      final dir = SimcruxScratch.prepare(p.join(base, 'gls'), base: base);
      expect(Directory(dir).existsSync(), isTrue);
      if (!Platform.isWindows) {
        expect(FileStat.statSync(base).mode & 0x3F, 0, reason: 'mode 0700');
      }
      expect(SimcruxScratch.refusal(base), isNull);
    });

    test('refuses a base that is a symbolic link', () {
      final target = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
      final base = p.join(tmp.path, 'simcrux');
      Link(base).createSync(target.path);
      expect(SimcruxScratch.refusal(base), contains('symbolic link'));
      expect(
        () => SimcruxScratch.prepare(p.join(base, 'gls'), base: base),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(p.join(target.path, 'gls')).existsSync(), isFalse);
    }, skip: Platform.isWindows ? 'links need privilege on Windows' : false);

    test('refuses a base other users can write (mode 777)', () async {
      final base = Directory(p.join(tmp.path, 'simcrux'))..createSync();
      final chmod = await Process.run('chmod', ['777', base.path]);
      expect(chmod.exitCode, 0);
      expect(SimcruxScratch.refusal(base.path), contains('other users'));
      expect(
        () => SimcruxScratch.prepare(p.join(base.path, 'gls'), base: base.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(p.join(base.path, 'gls')).existsSync(), isFalse);
    }, skip: Platform.isWindows ? 'no POSIX modes on Windows' : false);

    test('refuses a base that is a file', () {
      final base = p.join(tmp.path, 'simcrux');
      File(base).writeAsStringSync('');
      expect(SimcruxScratch.refusal(base), contains('not a directory'));
    });

    test('gate-level scratch refuses a world-writable root', () async {
      final root = Directory(p.join(tmp.path, 'gls'))..createSync();
      await Process.run('chmod', ['777', root.path]);
      final scratch = GlsScratch(root: root.path);
      await expectLater(
        scratch.allocateRun('r1'),
        throwsA(isA<FileSystemException>()),
      );
      expect(root.listSync(), isEmpty);
    }, skip: Platform.isWindows ? 'no POSIX modes on Windows' : false);

    test('zip extraction refuses a world-writable scratch', () async {
      final root = Directory(p.join(tmp.path, 'ingest'))..createSync();
      await Process.run('chmod', ['777', root.path]);
      final zip = File(p.join(tmp.path, 'run.zip'))
        ..writeAsBytesSync(
          ZipEncoder().encodeBytes(
            Archive()..add(ArchiveFile.bytes('run/a.txt', utf8.encode('a'))),
          ),
        );
      final result = await FlowArchiveExtractor(
        scratch: root.path,
      ).extract(zip.path);
      expect(result.directory, isNull);
      expect(result.refusal, FlowArchiveRefusal.unreadable);
      expect(result.message, contains('other users'));
      expect(root.listSync(), isEmpty);
    }, skip: Platform.isWindows ? 'no POSIX modes on Windows' : false);
  });
}
