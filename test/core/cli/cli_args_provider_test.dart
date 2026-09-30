// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_args.dart';
import 'package:simcrux/core/cli/cli_args_provider.dart';

void main() {
  group('cliArgsProvider', () {
    test('defaults to empty CliArgs', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(cliArgsProvider), equals(const CliArgs()));
    });

    test('honours override (used by bootstrap)', () {
      final container = ProviderContainer(
        overrides: [
          cliArgsProvider.overrideWithValue(
            const CliArgs(
              projectPaths: ['/tmp/test/simcrux.yaml'],
              maxParallel: 8,
              ciMode: true,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final args = container.read(cliArgsProvider);
      expect(args.projectPath, equals('/tmp/test/simcrux.yaml'));
      expect(args.maxParallel, equals(8));
      expect(args.ciMode, isTrue);
    });
  });
}
