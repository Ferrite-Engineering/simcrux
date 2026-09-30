// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/enums/riscv_import_kind.dart';
import 'package:simcrux/domain/models/riscv_import_result.dart';
import 'package:simcrux/services/import/riscv_import_cli.dart';

// Unit coverage for the argument surface of the two `simcrux import-riscv-…`
// sub-commands. What the emitted YAML *means* — that it loads, that its paths
// resolve, that it runs — is pinned end to end in
// test/integration/riscv_import_fixture_test.dart against committed fixtures;
// this file stays on the flags.
//
// Nothing here touches the disk: `writeText` is injected, so a usage-error
// test cannot leave a stray simcrux.yaml in the repo root when the default
// output path (`./simcrux.yaml`) is exercised.

const String _archFixture = 'test/fixtures/riscv_arch_test';
const String _formalFixture = 'test/fixtures/riscv_formal_checks';

void main() {
  late Map<String, String> written;
  late List<String> printed;
  late RiscvImportCli cli;

  setUp(() {
    written = <String, String>{};
    printed = <String>[];
    cli = RiscvImportCli(
      writeText: (path, contents) async => written[path] = contents,
      stdoutWriter: printed.add,
    );
  });

  group('positional argument', () {
    test('exactly one is required', () async {
      for (final args in const [
        <String>[],
        ['a', 'b'],
      ]) {
        await expectLater(
          cli.run(RiscvImportKind.archTest, args),
          throwsA(
            isA<RiscvImportCliException>().having(
              (e) => e.message,
              'message',
              contains('exactly one positional argument'),
            ),
          ),
        );
      }
      expect(written, isEmpty);
    });

    test('names the right thing per sub-command', () async {
      await expectLater(
        cli.run(RiscvImportKind.archTest, const []),
        throwsA(
          isA<RiscvImportCliException>().having(
            (e) => e.message,
            'message',
            contains('riscv-arch-test checkout'),
          ),
        ),
      );
      await expectLater(
        cli.run(RiscvImportKind.formal, const []),
        throwsA(
          isA<RiscvImportCliException>().having(
            (e) => e.message,
            'message',
            contains('`checks/` directory'),
          ),
        ),
      );
    });
  });

  group('--out', () {
    test('defaults to ./simcrux.yaml in the working directory', () async {
      final result = await cli.run(RiscvImportKind.formal, [
        p.absolute(_formalFixture),
      ]);
      expect(p.basename(result.outputPath), 'simcrux.yaml');
      expect(p.isAbsolute(result.outputPath), isTrue);
      // Never inside the scanned tree: that tree is somebody else's git
      // checkout, and a generated file dropped into it shows up as
      // untracked (or fails outright when the checkout is read-only).
      expect(
        p.isWithin(p.absolute(_formalFixture), result.outputPath),
        isFalse,
      );
      expect(written.keys.single, result.outputPath);
    });

    test('is honored, and absolutized', () async {
      final result = await cli.run(RiscvImportKind.formal, [
        p.absolute(_formalFixture),
        '--out',
        'nested/out.yaml',
      ]);
      expect(p.isAbsolute(result.outputPath), isTrue);
      expect(result.outputPath, endsWith(p.join('nested', 'out.yaml')));
    });
  });

  group('--mode', () {
    test('rejects riscof_passthrough with an explanation', () async {
      await expectLater(
        cli.run(RiscvImportKind.archTest, [
          p.absolute(_archFixture),
          '--mode',
          'riscof_passthrough',
        ]),
        throwsA(
          isA<RiscvImportCliException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('must be `normal` or `demo`'),
              contains('nothing for an importer to enumerate'),
            ),
          ),
        ),
      );
    });

    test('rejects an unknown value', () async {
      await expectLater(
        cli.run(RiscvImportKind.archTest, [
          p.absolute(_archFixture),
          '--mode',
          'turbo',
        ]),
        throwsA(isA<RiscvImportCliException>()),
      );
    });
  });

  group('--target-command', () {
    test('is split like a shell would split it', () async {
      await cli.run(RiscvImportKind.archTest, [
        p.absolute(_archFixture),
        '--target-command',
        """'./my core' --elf "{elf}" --signature {signature}""",
      ]);
      final yaml = written.values.single;
      // Quoted back on the way out, because the emitter quotes any scalar
      // containing whitespace.
      expect(yaml, contains("- './my core'"));
      // The placeholders survive verbatim — the driver expands them at
      // spawn time, so pre-resolving or de-bracing either one would corrupt
      // it into a path.
      expect(yaml, contains("- '{elf}'"));
      expect(yaml, contains("- '{signature}'"));
    });

    test('supplying it silences the missing_target_command warning', () async {
      final result = await cli.run(RiscvImportKind.archTest, [
        p.absolute(_archFixture),
        '--target-command',
        './my_core --elf {elf} --signature {signature}',
      ]);
      expect(result.warnings, isEmpty);
    });

    test('omitting it warns, because the loader will refuse', () async {
      final result = await cli.run(RiscvImportKind.archTest, [
        p.absolute(_archFixture),
      ]);
      expect(
        result.warnings.map((w) => w.code),
        contains('missing_target_command'),
      );
    });

    test('rejects a blank value', () async {
      await expectLater(
        cli.run(RiscvImportKind.archTest, [
          p.absolute(_archFixture),
          '--target-command',
          '   ',
        ]),
        throwsA(
          isA<RiscvImportCliException>().having(
            (e) => e.message,
            'message',
            contains('--target-command was empty'),
          ),
        ),
      );
    });
  });

  group('the remaining arch-test options land in defaults.riscv', () {
    test('isa / toolchain / reference / word-size', () async {
      await cli.run(RiscvImportKind.archTest, [
        p.absolute(_archFixture),
        '--target-command',
        './my_core',
        '--isa',
        'rv64imafdc',
        '--toolchain-prefix',
        'riscv64-unknown-elf-',
        '--toolchain-path',
        '/opt/riscv/bin',
        '--reference-model',
        'sail',
        '--reference-path',
        '/opt/sail/bin/riscv_sim',
        '--word-size',
        '8',
      ]);
      final yaml = written.values.single;
      expect(yaml, contains('isa: rv64imafdc'));
      expect(yaml, contains('prefix: riscv64-unknown-elf-'));
      expect(yaml, contains('path: /opt/riscv/bin'));
      expect(yaml, contains('model: sail'));
      expect(yaml, contains('path: /opt/sail/bin/riscv_sim'));
      expect(yaml, contains('word_size: 8'));
    });

    test(
      '--reference-model rejects an unknown model, listing the set',
      () async {
        await expectLater(
          cli.run(RiscvImportKind.archTest, [
            p.absolute(_archFixture),
            '--reference-model',
            'qemu',
          ]),
          throwsA(
            isA<RiscvImportCliException>().having(
              (e) => e.message,
              'message',
              allOf(contains('spike'), contains('qemu')),
            ),
          ),
        );
      },
    );

    test('--word-size rejects a non-positive integer', () async {
      for (final bad in const ['0', '-4', 'four']) {
        await expectLater(
          cli.run(RiscvImportKind.archTest, [
            p.absolute(_archFixture),
            '--word-size',
            bad,
          ]),
          throwsA(
            isA<RiscvImportCliException>().having(
              (e) => e.message,
              'message',
              contains('--word-size'),
            ),
          ),
          reason: bad,
        );
      }
    });
  });

  group('formal options', () {
    test('--sby-binary lands under defaults.riscv.formal', () async {
      await cli.run(RiscvImportKind.formal, [
        p.absolute(_formalFixture),
        '--sby-binary',
        '/opt/oss-cad-suite/bin/sby',
      ]);
      expect(
        written.values.single,
        contains('sby_binary: /opt/oss-cad-suite/bin/sby'),
      );
    });
  });

  group('a wrong path fails as an import error, not a usage error', () {
    test('arch-test', () async {
      await expectLater(
        cli.run(RiscvImportKind.archTest, ['/nope/not/a/checkout']),
        throwsA(isA<RiscvImportException>()),
      );
      expect(written, isEmpty);
    });

    test('formal', () async {
      await expectLater(
        cli.run(RiscvImportKind.formal, ['/nope/not/a/checks/dir']),
        throwsA(isA<RiscvImportException>()),
      );
      expect(written, isEmpty);
    });

    test('an unknown flag is a usage error carrying the usage block', () async {
      await expectLater(
        cli.run(RiscvImportKind.formal, [
          p.absolute(_formalFixture),
          '--nope',
        ]),
        throwsA(
          isA<RiscvImportCliException>().having(
            (e) => e.message,
            'message',
            allOf(contains('Could not find'), contains('Usage: simcrux')),
          ),
        ),
      );
    });
  });

  group('--help', () {
    test('prints usage and writes nothing', () async {
      final result = await cli.run(RiscvImportKind.archTest, const ['--help']);
      expect(written, isEmpty);
      expect(result.testCount, 0);
      expect(printed.single, contains('Usage: simcrux'));
      expect(printed.single, contains('--target-command'));
    });

    test('each sub-command documents only its own flags', () {
      final arch = RiscvImportCli.usageFor(RiscvImportKind.archTest);
      final formal = RiscvImportCli.usageFor(RiscvImportKind.formal);
      expect(arch, contains('--extensions'));
      expect(arch, isNot(contains('--groups')));
      expect(formal, contains('--groups'));
      expect(formal, isNot(contains('--target-command')));
      // Both carry the shared trio.
      for (final usage in [arch, formal]) {
        expect(usage, contains('--out'));
        expect(usage, contains('--mode'));
        expect(usage, contains('--isa'));
      }
    });
  });

  group('splitCommandLine', () {
    test('splits on whitespace runs', () {
      expect(splitCommandLine('a  b\tc\nd'), ['a', 'b', 'c', 'd']);
    });

    test('honors single and double quotes', () {
      expect(
        splitCommandLine(""" './my core' "two words" bare """),
        ['./my core', 'two words', 'bare'],
      );
    });

    test('keeps an empty quoted argument', () {
      // `--flag ''` is a real thing to pass a simulator; dropping it would
      // silently shift every later argv position.
      expect(splitCommandLine("--flag '' next"), ['--flag', '', 'next']);
    });

    test('honors backslash escapes outside and inside double quotes', () {
      expect(splitCommandLine(r'a\ b c'), ['a b', 'c']);
      expect(splitCommandLine(r'"a\"b"'), ['a"b']);
      // A backslash inside SINGLE quotes is literal, as in a POSIX shell.
      expect(splitCommandLine(r"'a\b'"), [r'a\b']);
    });

    test('leaves placeholders untouched', () {
      expect(
        splitCommandLine('./core --elf {elf} --signature {signature}'),
        ['./core', '--elf', '{elf}', '--signature', '{signature}'],
      );
    });

    test('an empty or blank string yields no arguments', () {
      expect(splitCommandLine(''), isEmpty);
      expect(splitCommandLine('   \t '), isEmpty);
    });
  });
}
