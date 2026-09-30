// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/services/export/result_exporter.dart';

void main() {
  late CliArgParser parser;

  setUp(() {
    parser = CliArgParser();
  });

  group('CliArgParser — happy paths', () {
    test('no args → defaults, no project', () {
      final args = parser.parse(<String>[]);
      expect(args, equals(const CliArgs()));
    });

    test('lone positional becomes projectPath', () {
      final args = parser.parse(<String>['my_project/simcrux.yaml']);
      expect(args.projectPath, equals('my_project/simcrux.yaml'));
      expect(args.hasProject, isTrue);
    });

    test('--filter is captured', () {
      final args = parser.parse(<String>[
        '--filter',
        'alu*',
        'p.yaml',
      ]);
      expect(args.filter, equals('alu*'));
      expect(args.projectPath, equals('p.yaml'));
    });

    test('--max-parallel parses to int', () {
      final args = parser.parse(<String>[
        '--max-parallel',
        '8',
        'p.yaml',
      ]);
      expect(args.maxParallel, equals(8));
    });

    test('--allow-project-tooling defaults off and parses on', () {
      // The CLI has no Settings, so this flag IS the user's decision to
      // let a project file choose what the run executes. Absent means
      // no. See `CliArgs.allowProjectTooling`.
      expect(parser.parse(<String>['p.yaml']).allowProjectTooling, isFalse);
      expect(
        parser.parse(<String>[
          '--ci',
          '--allow-project-tooling',
          'p.yaml',
        ]).allowProjectTooling,
        isTrue,
      );
    });

    test('--allow-project-tooling appears in --help', () {
      expect(parser.usage, contains('allow-project-tooling'));
    });

    test('--json implies --ci', () {
      final args = parser.parse(<String>['--json', 'p.yaml']);
      expect(args.jsonOutput, isTrue);
      expect(args.ciMode, isTrue);
    });

    test('--ci alone leaves jsonOutput off', () {
      final args = parser.parse(<String>['--ci', 'p.yaml']);
      expect(args.ciMode, isTrue);
      expect(args.jsonOutput, isFalse);
    });

    test('-f / -j short forms work', () {
      final args = parser.parse(<String>['-f', 'pattern', '-j', '2', 'p.yaml']);
      expect(args.filter, equals('pattern'));
      expect(args.maxParallel, equals(2));
    });

    test('arguments in any order are accepted', () {
      final args = parser.parse(<String>[
        'p.yaml',
        '--ci',
        '--filter',
        'x',
        '--max-parallel',
        '3',
      ]);
      expect(args.projectPath, equals('p.yaml'));
      expect(args.filter, equals('x'));
      expect(args.maxParallel, equals(3));
      expect(args.ciMode, isTrue);
    });
  });

  group('CliArgParser — help', () {
    test('--help returns sentinel', () {
      final args = parser.parse(<String>['--help']);
      expect(args, isA<HelpCliArgs>());
    });

    test('-h short form returns sentinel', () {
      final args = parser.parse(<String>['-h']);
      expect(args, isA<HelpCliArgs>());
    });

    test('usage string is non-empty and mentions each option', () {
      final usage = parser.usage;
      expect(usage, contains('--filter'));
      expect(usage, contains('--max-parallel'));
      expect(usage, contains('--json'));
      expect(usage, contains('--ci'));
      expect(usage, contains('--help'));
    });

    test('usage describes what the flags actually do', () {
      // Each of these once promised something the code does not do:
      // `--filter` is a literal substring (`spec.id.contains`), not a glob;
      // the FuseSoC import prints its warnings on stdout; `--max-parallel`
      // has no project or app setting to override.
      final usage = parser.usage.replaceAll(RegExp(r'\s+'), ' ');
      expect(usage, contains('literal substring (not a glob)'));
      expect(usage, isNot(contains('Substring/glob')));
      expect(usage, contains('any warnings to stdout'));
      expect(usage, isNot(contains('warnings to stderr')));
      expect(usage, isNot(contains('the user setting')));
    });
  });

  group('CliArgParser — error paths', () {
    test('unknown flag throws CliArgsException', () {
      expect(
        () => parser.parse(<String>['--nope']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('non-integer --max-parallel throws', () {
      expect(
        () => parser.parse(<String>['--max-parallel', 'eight']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('positive integer'),
          ),
        ),
      );
    });

    test('zero / negative --max-parallel throws', () {
      expect(
        () => parser.parse(<String>['--max-parallel', '0']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parser.parse(<String>['--max-parallel', '-1']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('multiple positional arguments produce one projectPath per arg '
        '(multi-config opens N tabs)', () {
      final args = parser.parse(<String>['a.yaml', 'b.yaml', 'c.yaml']);
      expect(args.projectPaths, equals(<String>['a.yaml', 'b.yaml', 'c.yaml']));
      expect(
        args.projectPath,
        equals('a.yaml'),
        reason: 'projectPath convenience getter returns the first one',
      );
      expect(args.hasProject, isTrue);
    });

    test('--workspace path is captured', () {
      final args = parser.parse(<String>[
        '--workspace',
        'team-morning.simcrux-workspace',
      ]);
      expect(args.workspacePath, equals('team-morning.simcrux-workspace'));
      expect(args.projectPaths, isEmpty);
    });

    test('--workspace + positional configs coexist', () {
      final args = parser.parse(<String>[
        '--workspace',
        'team.simcrux-workspace',
        'cpu/simcrux.yaml',
        'mem/simcrux.yaml',
      ]);
      expect(args.workspacePath, 'team.simcrux-workspace');
      expect(
        args.projectPaths,
        equals(['cpu/simcrux.yaml', 'mem/simcrux.yaml']),
      );
    });

    test('exception toString contains usage and message', () {
      try {
        parser.parse(<String>['--nope']);
        fail('Expected CliArgsException');
      } on CliArgsException catch (e) {
        final str = e.toString();
        expect(str, contains('simcrux:'));
        expect(str, contains(e.usage));
      }
    });
  });

  group('CliArgParser — export & ci', () {
    test('--export <fmt>=<path> may be supplied multiple times', () {
      final args = parser.parse(<String>[
        '--ci',
        '--export',
        'junit=report.xml',
        '--export',
        'json=results.json',
        'p.yaml',
      ]);
      expect(args.ciMode, isTrue);
      expect(args.exportTargets, hasLength(2));
      expect(args.exportTargets[0].formatId, 'junit');
      expect(args.exportTargets[0].outputPath, 'report.xml');
      expect(args.exportTargets[1].formatId, 'json');
    });

    test('every ExportFormat id is accepted by --export', () {
      for (final format in ExportFormat.values) {
        final args = parser.parse(<String>[
          '--export',
          '${format.id}=out.${format.extension}',
        ]);
        expect(args.exportTargets.single.formatId, format.id);
      }
    });

    test('an unknown --export format throws, naming the valid ones', () {
      for (final bad in const <String>['pdf', 'JUnit', 'xml']) {
        expect(
          () => parser.parse(<String>['--ci', '--export', '$bad=r', 'p.yaml']),
          throwsA(
            isA<CliArgsException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('unknown format "$bad"'),
                contains('Valid formats: junit, json, csv, html.'),
              ),
            ),
          ),
        );
      }
    });

    test('--export help lists the formats', () {
      expect(parser.usage, contains('junit, json, csv, html'));
    });

    // Help that described behaviour the code does not have.
    test('--session help does not promise a session restore', () {
      // `CliRegressionBootstrapper` opens the path as a project file; no
      // `.simcrux-session` document is parsed.
      expect(parser.usage, isNot(contains('to restore')));
      expect(parser.usage, contains('No session state is restored'));
    });

    test('--reset-telemetry-consent help says --ci acts on it', () {
      // `bootstrap()` resets consent before it parses anything else, so the
      // desktop app forgets the answer under `--ci` too.
      expect(parser.usage, isNot(contains('accepts and ignores it')));
      expect(parser.usage, contains('--ci included'));
    });

    test('--reset-eula is accepted and listed in --help', () {
      // `bootstrap()` acts on the raw argument list before this parser runs;
      // the parser only has to accept the flag rather than reject it as
      // unknown, beside GUI and --ci invocations alike.
      expect(() => parser.parse(<String>['--reset-eula']), returnsNormally);
      final ci = parser.parse(<String>['--reset-eula', '--ci', 'p.yaml']);
      expect(ci.ciMode, isTrue);
      expect(ci.projectPaths, <String>['p.yaml']);
      expect(parser.usage, contains('--reset-eula'));
      expect(
        () => parser.parse(<String>['--reset-eulas']),
        throwsA(isA<CliArgsException>()),
        reason: 'an unknown flag is still rejected',
      );
    });

    test('--allow-project-tooling help names the formal keys', () {
      expect(parser.usage, contains('formal command'));
      expect(parser.usage, contains('formal.sby_binary'));
    });

    test('--export without "=" throws CliArgsException', () {
      expect(
        () => parser.parse(<String>['--export', 'junit', 'p.yaml']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('<format>=<path>'),
          ),
        ),
      );
    });

    test('--fail-threshold parses as positive int and defaults to 1', () {
      expect(parser.parse(<String>[]).failThreshold, 1);
      expect(
        parser.parse(<String>['--fail-threshold', '0']).failThreshold,
        0,
      );
      expect(
        parser.parse(<String>['--fail-threshold', '5']).failThreshold,
        5,
      );
      expect(
        () => parser.parse(<String>['--fail-threshold', '-1']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parser.parse(<String>['--fail-threshold', 'oops']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('--session is captured', () {
      final args = parser.parse(<String>['--session', 'debug.simcrux-session']);
      expect(args.sessionPath, 'debug.simcrux-session');
    });

    test('--fail-on-regression and --baseline default to false / null', () {
      final args = parser.parse(<String>[]);
      expect(args.failOnRegression, isFalse);
      expect(args.baselineRunPath, isNull);
    });

    test('--fail-on-regression flag toggles', () {
      final args = parser.parse(<String>['--fail-on-regression']);
      expect(args.failOnRegression, isTrue);
    });

    test('--baseline option captures path', () {
      final args = parser.parse(<String>[
        '--baseline',
        'snapshots/baseline.ndjson',
      ]);
      expect(args.baselineRunPath, 'snapshots/baseline.ndjson');
    });

    test('--fail-on-regression + --baseline together', () {
      final args = parser.parse(<String>[
        '--ci',
        '--fail-on-regression',
        '--baseline',
        'snapshots/baseline.ndjson',
        'project.yaml',
      ]);
      expect(args.ciMode, isTrue);
      expect(args.failOnRegression, isTrue);
      expect(args.baselineRunPath, 'snapshots/baseline.ndjson');
      expect(args.projectPath, 'project.yaml');
    });

    test('--license-file captures the path and defaults to null', () {
      expect(parser.parse(<String>[]).licenseFile, isNull);
      final args = parser.parse(<String>[
        '--ci',
        '--license-file',
        'ci/simcrux.lic',
        'project.yaml',
      ]);
      expect(args.licenseFile, 'ci/simcrux.lic');
      expect(args.projectPath, 'project.yaml');
      expect(
        args,
        isNot(args.copyWith(licenseFile: 'other.lic')),
        reason: 'licenseFile takes part in equality',
      );
    });

    test('--import-fusesoc is captured', () {
      final args = parser.parse(<String>[
        '--import-fusesoc',
        'foo.core',
      ]);
      expect(args.importFusesoc, 'foo.core');
      expect(args.hasProject, isFalse);
    });

    test('--import-fusesoc and a positional both populate', () {
      // Edge: a user could supply both; bootstrap dispatches on the
      // importFusesoc field first, so the positional is simply
      // ignored. CLI parsing tolerates the combination.
      final args = parser.parse(<String>[
        '--import-fusesoc',
        'foo.core',
        'unused/simcrux.yaml',
      ]);
      expect(args.importFusesoc, 'foo.core');
      expect(args.projectPath, 'unused/simcrux.yaml');
    });
  });

  group('sub-commands', () {
    test('every recognized word is matched, and captured verbatim', () {
      // The words are matched BEFORE the primary option parser, because
      // everything after one belongs to that sub-command's own ArgParser —
      // `--extensions` and `--target-command` are not flags this parser has
      // ever heard of, and it treats an unknown flag as a usage error.
      for (final word in CliArgParser.kSubcommands) {
        final args = parser.parse(<String>[
          word,
          'some/path',
          '--extensions',
          'I,M',
        ]);
        expect(args.subcommand, word, reason: word);
        expect(
          args.subcommandArgs,
          ['some/path', '--extensions', 'I,M'],
          reason: word,
        );
      }
    });

    test('kSubcommands covers export-dashboard and both RISC-V imports', () {
      expect(CliArgParser.kSubcommands, [
        'export-dashboard',
        'import-riscv-arch-test',
        'import-riscv-formal',
      ]);
    });

    test('startsWithSubcommand only fires on the leading word', () {
      expect(
        CliArgParser.startsWithSubcommand(const ['import-riscv-formal']),
        isTrue,
      );
      expect(CliArgParser.startsWithSubcommand(const []), isFalse);
      expect(
        CliArgParser.startsWithSubcommand(const ['a.yaml', 'export-dashboard']),
        isFalse,
      );
    });

    test('a non-sub-command first argument still parses normally', () {
      final args = parser.parse(<String>['project.yaml', '--ci']);
      expect(args.subcommand, isNull);
      expect(args.projectPath, 'project.yaml');
      expect(args.ciMode, isTrue);
    });
  });
}
