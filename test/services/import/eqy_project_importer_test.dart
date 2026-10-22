// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/cli/simcrux_cli.dart';
import 'package:simcrux/domain/enums/formal_import_kind.dart';
import 'package:simcrux/domain/models/formal_import_result.dart';
import 'package:simcrux/services/config/config_loader.dart';
import 'package:simcrux/services/import/eqy_project_importer.dart';
import 'package:simcrux/services/import/formal_import_cli.dart';
import 'package:simcrux/services/simulator/eqy_driver.dart';

import '../../support/eqy_workdir_fixture.dart';

// The EQY importer (one test per .eqy file) and `simcrux import-eqy`: the
// same CLI contract as import-sby (help first on stdout, usage errors exit
// 2, machine output on stdout, diagnostics on stderr).

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('import_eqy_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String copyCorpus(String run) {
    for (final f in Directory(eqyCorpus).listSync().whereType<File>()) {
      if (f.path.endsWith('.eqy') || f.path.endsWith('.v')) {
        f.copySync(p.join(tmp.path, p.basename(f.path)));
      }
    }
    return p.join(tmp.path, '$run.eqy');
  }

  group('the importer', () {
    test(
      'one test, the eqy driver, the shared pass marker; it loads clean',
      () async {
        final file = copyCorpus('alu_pass2');
        final result = EqyProjectImporter().importFile(
          path: file,
          outputDirectory: tmp.path,
        );
        expect(result.testCount, 1);
        expect(result.jobs, ['alu_pass2.eqy']);
        expect(result.warnings, isEmpty);
        final yaml = result.simcruxYaml;
        expect(yaml, contains('simulator: eqy'));
        expect(yaml, contains("pass_string: 'DONE (PASS'"));
        expect(yaml, contains('eqy_file: alu_pass2.eqy'));
        final out = File(p.join(tmp.path, 'simcrux.yaml'))
          ..writeAsStringSync(yaml);
        final config = await ConfigLoader().load(out.path);
        final test = config.suites.single.tests.single;
        expect(test.simulatorId, EqyDriver.kId);
        expect(p.normalize(test.formal!.eqyFile!), p.normalize(file));
        expect(config.loadWarnings, isEmpty);
      },
    );

    test('a file outside the output directory is spelled absolute', () {
      final file = copyCorpus('alu_pass');
      final elsewhere = Directory(p.join(tmp.path, 'out'))..createSync();
      final yaml = EqyProjectImporter()
          .importFile(path: file, outputDirectory: elsewhere.path)
          .simcruxYaml;
      expect(yaml, contains(p.normalize(file)));
    });

    test('--eqy-binary lands under defaults.formal', () {
      final yaml = EqyProjectImporter()
          .importFile(
            path: copyCorpus('alu_pass'),
            outputDirectory: tmp.path,
            eqyBinary: '/opt/suite/bin/eqy',
          )
          .simcruxYaml;
      expect(yaml, contains('eqy_binary: /opt/suite/bin/eqy'));
    });

    test('refusals: missing, not .eqy, no [gate], unsafe name', () {
      final importer = EqyProjectImporter();
      expect(
        () => importer.importFile(
          path: p.join(tmp.path, 'none.eqy'),
          outputDirectory: tmp.path,
        ),
        throwsA(isA<FormalImportException>()),
      );
      final sby = File(p.join(tmp.path, 'x.sby'))..writeAsStringSync('');
      expect(
        () => importer.importFile(path: sby.path, outputDirectory: tmp.path),
        throwsA(isA<FormalImportException>()),
      );
      final half = File(p.join(tmp.path, 'half.eqy'))
        ..writeAsStringSync('[gold]\nread_verilog a.v\n');
      expect(
        () => importer.importFile(path: half.path, outputDirectory: tmp.path),
        throwsA(
          isA<FormalImportException>().having(
            (e) => e.message,
            'message',
            contains('[gate]'),
          ),
        ),
      );
      expect(
        () => EqyProjectImporter(
          fileExists: (_) => true,
          readFile: (_) => '[gold]\na\n[gate]\nb\n',
        ).importFile(path: '/p/bad:name.eqy', outputDirectory: '/p'),
        throwsA(isA<FormalImportException>()),
      );
    });

    test('a ghdl line SimCrux lowers imports clean', () {
      final file = File(p.join(tmp.path, 'v.eqy'))
        ..writeAsStringSync(
          '[gold]\nghdl --std=08 a.vhd -e a\n[gate]\nread_verilog b.v\n'
          '[strategy s]\nuse sby\n',
        );
      expect(
        EqyProjectImporter()
            .importFile(path: file.path, outputDirectory: tmp.path)
            .warnings,
        isEmpty,
      );
    });

    test('warnings: a GHDL plugin line that cannot be lowered, and no '
        'strategy', () {
      final file = File(p.join(tmp.path, 'v.eqy'))
        ..writeAsStringSync(
          '[gold]\nghdl -fsynopsys a.vhd -e a\n[gate]\nread_verilog b.v\n',
        );
      final result = EqyProjectImporter().importFile(
        path: file.path,
        outputDirectory: tmp.path,
      );
      expect(result.warnings.map((w) => w.code), [
        'vhdl_plugin',
        'no_strategy',
      ]);
      expect(result.simcruxYaml, contains('[vhdl_plugin]'));
    });
  });

  group('simcrux import-eqy', () {
    late List<String> out;
    late List<String> err;
    late Map<String, String> written;
    setUp(() {
      out = <String>[];
      err = <String>[];
      written = <String, String>{};
    });

    FormalImportCli cli() => FormalImportCli(
      stdoutWriter: out.add,
      stderrWriter: err.add,
      writeText: (path, contents) async => written[path] = contents,
      currentDirectory: () => tmp.path,
    );

    for (final flag in const ['-h', '--help']) {
      test('$flag prints the usage to stdout and touches no file', () async {
        final result = await cli().run(FormalImportKind.eqy, [
          '--bogus',
          flag,
          p.join(tmp.path, 'missing.eqy'),
        ]);
        expect(result.helpShown, isTrue);
        expect(out.single, contains('Usage: simcrux import-eqy <file.eqy>'));
        expect(out.single, contains('--eqy-binary'));
        expect(out.single, isNot(contains('--task')));
        expect(written, isEmpty);
      });
    }

    test(
      'an unknown flag and a wrong positional count are usage errors',
      () async {
        await expectLater(
          cli().run(FormalImportKind.eqy, [
            copyCorpus('alu_pass'),
            '--task',
            'x',
          ]),
          throwsA(isA<FormalImportCliException>()),
        );
        await expectLater(
          cli().run(FormalImportKind.eqy, const []),
          throwsA(
            isA<FormalImportCliException>().having(
              (e) => e.message,
              'message',
              contains('a .eqy file'),
            ),
          ),
        );
        expect(written, isEmpty);
      },
    );

    test(
      'writes ./simcrux.yaml, summary on stdout, tooling note on stderr',
      () async {
        copyCorpus('alu_pass');
        final result = await cli().run(FormalImportKind.eqy, [
          'alu_pass.eqy',
          '--eqy-binary',
          '/opt/eqy',
        ]);
        final target = p.join(tmp.path, 'simcrux.yaml');
        expect(result.outputPath, target);
        expect(written[target], contains('eqy_file: alu_pass.eqy'));
        expect(out.single, contains('1 test from 1 job file: alu_pass.eqy'));
        expect(err.single, contains('formal.eqy_binary'));
        expect(err.single, contains('--allow-project-tooling'));
      },
    );

    Future<int> runCli(List<String> args) => SimcruxCli().run(
      args,
      stdoutSink: out.add,
      stderrSink: err.add,
    );

    test('through the binary: -h exits 0, a usage error exits 2', () async {
      expect(await runCli(const ['import-eqy', '-h']), 0);
      expect(out.join('\n'), contains('Usage: simcrux import-eqy'));
      expect(err, isEmpty);
      expect(await runCli(['import-eqy', copyCorpus('alu_pass'), '--x']), 2);
      expect(err.join('\n'), contains('x'));
      expect(await runCli(['import-eqy', p.join(tmp.path, 'none.eqy')]), 2);
    });

    test('through the binary, the default output lands in the working '
        'directory (IOOverrides)', () async {
      final file = copyCorpus('alu_fail2');
      final code = await IOOverrides.runZoned(
        () => runCli(['import-eqy', file]),
        getCurrentDirectory: () => tmp,
      );
      expect(code, 0);
      final yaml = File(
        p.join(tmp.path, FormalImportResult.kSuggestedOutputFilename),
      );
      expect(yaml.readAsStringSync(), contains('eqy_file: alu_fail2.eqy'));
    });
  });
}
