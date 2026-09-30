// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_arg_parser.dart';
import 'package:simcrux/services/cli/cli_args.dart' as launch_cli;

void main() {
  group('parseCliArgs (launch flags)', () {
    test('defaults: reset and noRestore are false', () {
      final cli = launch_cli.parseCliArgs(const []);
      expect(cli.reset, isFalse);
      expect(cli.noRestore, isFalse);
    });

    test('--reset sets reset', () {
      final cli = launch_cli.parseCliArgs(const ['--reset']);
      expect(cli.reset, isTrue);
      expect(cli.noRestore, isFalse);
    });

    test('--no-restore sets noRestore', () {
      final cli = launch_cli.parseCliArgs(const ['--no-restore']);
      expect(cli.noRestore, isTrue);
      expect(cli.reset, isFalse);
    });

    test('--reset and --no-restore compose with a positional config', () {
      final cli = launch_cli.parseCliArgs(
        const ['--reset', '--no-restore', 'simcrux.yaml'],
      );
      expect(cli.reset, isTrue);
      expect(cli.noRestore, isTrue);
    });

    test('unknown flags are silently ignored by the launch-flag parser', () {
      final cli = launch_cli.parseCliArgs(
        const ['--foo', '--bar=baz', 'simcrux.yaml'],
      );
      expect(cli.reset, isFalse);
      expect(cli.noRestore, isFalse);
    });
  });

  group('stripLaunchFlags', () {
    test('removes --reset and --no-restore, keeps everything else', () {
      expect(
        launch_cli.stripLaunchFlags(
          const ['--reset', '--no-restore', 'simcrux.yaml', '--ci'],
        ),
        equals(['simcrux.yaml', '--ci']),
      );
    });

    test('no-op on args without launch flags', () {
      expect(
        launch_cli.stripLaunchFlags(const [
          'simcrux.yaml',
          '--filter',
          'smoke',
        ]),
        equals(['simcrux.yaml', '--filter', 'smoke']),
      );
    });

    test('stripped output parses cleanly through the strict parser', () {
      // The whole point of stripping: `simcrux --reset simcrux.yaml` must
      // not die with an unknown-flag usage error.
      final parsed = CliArgParser().parse(
        launch_cli.stripLaunchFlags(
          const ['--reset', '--no-restore', 'simcrux.yaml'],
        ),
      );
      expect(parsed.projectPaths, equals(['simcrux.yaml']));
    });

    test('without stripping, the strict parser rejects the launch flags', () {
      // Documents why the strip step exists; if CliArgParser ever learns
      // these flags natively, the strip step can be retired.
      expect(
        () => CliArgParser().parse(const ['--reset']),
        throwsA(isA<CliArgsException>()),
      );
    });
  });

  group('cliHelpText', () {
    test('mentions both launch flags', () {
      final help = launch_cli.cliHelpText();
      expect(help, contains('--no-restore'));
      expect(help, contains('--reset'));
    });
  });
}
