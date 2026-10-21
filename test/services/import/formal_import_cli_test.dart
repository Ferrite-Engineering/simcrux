// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/services/import/formal_import_cli.dart';

// `simcrux import-sby`: help first and on stdout, usage errors exit 2 (the
// grandfathered code every `simcrux import-*` sub-command shares), machine
// output on stdout, diagnostics on stderr.

const String _job = '''
[tasks]
prove
cover

[options]
prove: mode prove
cover: mode cover

[engines]
smtbmc

[script]
read -formal top.sv
prep -top top

[files]
top.sv
''';

void main() {
  late Directory tmp;
  late List<String> out;
  late List<String> err;
  late Map<String, String> written;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('import_sby_cli_');
    out = <String>[];
    err = <String>[];
    written = <String, String>{};
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  FormalImportCli cli() => FormalImportCli(
    stdoutWriter: out.add,
    stderrWriter: err.add,
    writeText: (path, contents) async => written[path] = contents,
    currentDirectory: () => tmp.path,
  );

  String job([String name = 'top.sby', String text = _job]) {
    final file = File(p.join(tmp.path, name))..writeAsStringSync(text);
    return file.path;
  }

  group('help comes first', () {
    for (final flag in const ['-h', '--help']) {
      test('$flag prints the usage to stdout and touches no file', () async {
        final result = await cli().run(FormalImportKind.sby, [
          flag,
          p.join(tmp.path, 'does-not-exist.sby'),
        ]);
        expect(result.helpShown, isTrue);
        expect(out.single, contains('Usage: simcrux import-sby'));
        expect(out.single, contains('--task'));
        expect(err, isEmpty);
        expect(written, isEmpty);
      });
    }

    test('help wins over a flag the parser would refuse', () async {
      final result = await cli().run(FormalImportKind.sby, [
        '--bogus',
        '-h',
      ]);
      expect(result.helpShown, isTrue);
      expect(written, isEmpty);
    });

    test('a -h after -- is a positional, not a request for help', () async {
      await expectLater(
        cli().run(FormalImportKind.sby, ['--', '-h']),
        throwsA(isA<FormalImportException>()),
      );
    });
  });

  group('usage errors', () {
    test('an unknown flag is a usage error naming it', () async {
      await expectLater(
        cli().run(FormalImportKind.sby, [job(), '--bogus']),
        throwsA(
          isA<FormalImportCliException>().having(
            (e) => e.message,
            'message',
            contains('bogus'),
          ),
        ),
      );
      expect(written, isEmpty);
    });

    test('no positional, or two, is a usage error', () async {
      await expectLater(
        cli().run(FormalImportKind.sby, const []),
        throwsA(isA<FormalImportCliException>()),
      );
      await expectLater(
        cli().run(FormalImportKind.sby, [job(), job('b.sby')]),
        throwsA(isA<FormalImportCliException>()),
      );
    });
  });

  group('the import', () {
    test('writes ./simcrux.yaml and says so on stdout', () async {
      final result = await cli().run(FormalImportKind.sby, [job()]);
      final target = p.join(tmp.path, 'simcrux.yaml');
      expect(result.outputPath, target);
      expect(result.testCount, 2);
      expect(written.keys, [target]);
      expect(written[target], contains('sby_file: top.sby'));
      expect(out.single, contains(target));
      expect(out.single, contains('2 tests'));
      expect(err, isEmpty);
    });

    test('a relative input and --out resolve against the working '
        'directory', () async {
      job();
      final result = await cli().run(FormalImportKind.sby, [
        'top.sby',
        '--out',
        'out/project.yaml',
      ]);
      expect(result.outputPath, p.join(tmp.path, 'out', 'project.yaml'));
      // Not below the project file's directory, so spelled absolute.
      expect(written.values.single, contains(p.join(tmp.path, 'top.sby')));
      expect(written.values.single, isNot(contains('sby_file: top.sby')));
    });

    test('--task, repeated or comma-separated, keeps those tasks', () async {
      final repeated = await cli().run(FormalImportKind.sby, [
        job(),
        '--task',
        'cover',
      ]);
      expect(repeated.testCount, 1);
      final listed = await cli().run(FormalImportKind.sby, [
        job(),
        '--task',
        'cover,prove',
      ]);
      expect(listed.testCount, 2);
    });

    test('warnings and the tooling note go to stderr, not stdout', () async {
      final quiet = job(
        'quiet.sby',
        '[script]\nread -formal -noassert q.sv\nprep -top q\n',
      );
      await cli().run(FormalImportKind.sby, [
        quiet,
        '--sby-binary',
        '/opt/sby',
      ]);
      expect(out, hasLength(1));
      expect(err.any((l) => l.contains('[assertions_disabled]')), isTrue);
      expect(err.any((l) => l.contains('--allow-project-tooling')), isTrue);
    });
  });

  group('through the headless binary', () {
    Future<int> runCli(List<String> args) => SimcruxCli().run(
      args,
      stdoutSink: out.add,
      stderrSink: err.add,
    );

    test('import-sby -h exits 0 with the usage on stdout', () async {
      expect(await runCli(const ['import-sby', '-h']), 0);
      expect(out.join('\n'), contains('Usage: simcrux import-sby'));
      expect(err, isEmpty);
    });

    test('an unknown flag exits 2 with the reason on stderr', () async {
      expect(await runCli(['import-sby', job(), '--bogus']), 2);
      expect(out, isEmpty);
      expect(err.join('\n'), contains('bogus'));
    });

    test('a path with no job file exits 2 with the reason on stderr', () async {
      expect(
        await runCli(['import-sby', p.join(tmp.path, 'missing.sby')]),
        2,
      );
      expect(err.join('\n'), contains('missing.sby'));
    });

    test('--out into a directory that does not exist yet creates it', () async {
      final out = p.join(tmp.path, 'new', 'dir', 'simcrux.yaml');
      expect(await runCli(['import-sby', job(), '--out', out]), 0);
      expect(File(out).existsSync(), isTrue);
    });

    test('the default output lands in the working directory '
        '(IOOverrides)', () async {
      final sby = job();
      final code = await IOOverrides.runZoned(
        () => runCli(['import-sby', sby]),
        getCurrentDirectory: () => tmp,
      );
      expect(code, 0);
      final yaml = File(
        p.join(tmp.path, FormalImportResult.kSuggestedOutputFilename),
      );
      expect(yaml.existsSync(), isTrue);
      expect(yaml.readAsStringSync(), contains('task: cover'));
    });
  });
}
