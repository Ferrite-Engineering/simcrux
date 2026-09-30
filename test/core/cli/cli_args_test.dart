// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/cli/cli_args.dart';

void main() {
  group('CliArgs', () {
    test('defaults are conservative', () {
      const args = CliArgs();
      expect(args.projectPath, isNull);
      expect(args.filter, isNull);
      expect(args.maxParallel, isNull);
      expect(args.jsonOutput, isFalse);
      expect(args.ciMode, isFalse);
      expect(args.hasProject, isFalse);
    });

    test('hasProject reflects projectPath presence', () {
      const a = CliArgs();
      const b = CliArgs(projectPaths: ['project/simcrux.yaml']);
      expect(a.hasProject, isFalse);
      expect(b.hasProject, isTrue);
    });

    test('copyWith replaces only the specified fields', () {
      const base = CliArgs(
        projectPaths: ['p.yaml'],
        maxParallel: 4,
      );
      final updated = base.copyWith(filter: 'alu', ciMode: true);
      expect(updated.projectPath, equals('p.yaml'));
      expect(updated.maxParallel, equals(4));
      expect(updated.filter, equals('alu'));
      expect(updated.ciMode, isTrue);
    });

    test('value-based equality + hashCode', () {
      const a = CliArgs(
        projectPaths: ['p.yaml'],
        maxParallel: 4,
        jsonOutput: true,
      );
      const b = CliArgs(
        projectPaths: ['p.yaml'],
        maxParallel: 4,
        jsonOutput: true,
      );
      const c = CliArgs(projectPaths: ['p.yaml']);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });
  });
}
