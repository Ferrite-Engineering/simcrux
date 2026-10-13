// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// The top-level `project_id:`, the identity the shared team database pools
/// runs under. Two machines agree on it because it is in the file both
/// checked out, and CI passes the same string to `push-results --project`.
void main() {
  final loader = ConfigLoader();

  String yaml({String? projectId}) =>
      '''
version: "1"
${projectId == null ? '' : 'project_id: $projectId'}
defaults:
  simulator: icarus
suites:
  s:
    tests:
      - name: t
        top: tb
''';

  test('is read when declared, and null when not', () {
    expect(
      loader.parse(yaml(projectId: 'soc-top.v2'), '/p.yaml').projectId,
      'soc-top.v2',
    );
    expect(loader.parse(yaml(), '/p.yaml').projectId, isNull);
  });

  test('a value outside the pattern fails the load and states the rule', () {
    for (final bad in <String>[
      '"with space"',
      '"a/b"',
      '"${'x' * 65}"',
      '""',
    ]) {
      ConfigLoaderException? caught;
      try {
        loader.parse(yaml(projectId: bad), '/p.yaml');
      } on ConfigLoaderException catch (e) {
        caught = e;
      }
      expect(caught, isNotNull, reason: '$bad must be refused');
      final message = caught!.errors.single.message;
      expect(message, contains('`project_id`'));
      expect(message, contains('push-results --project'));
      expect(caught.errors.single.line, isNotNull);
    }
  });

  test('a numeric id is accepted as text', () {
    expect(loader.parse(yaml(projectId: '2026'), '/p.yaml').projectId, '2026');
  });

  group('ConfigLoader.readProjectId', () {
    test('reads the id without loading the project', () {
      expect(ConfigLoader.readProjectId(yaml(projectId: 'soc')), 'soc');
    });

    test('absent, invalid and unparseable all read as no id', () {
      expect(ConfigLoader.readProjectId(yaml()), isNull);
      expect(ConfigLoader.readProjectId(yaml(projectId: '"a b"')), isNull);
      expect(ConfigLoader.readProjectId('{ not: [yaml'), isNull);
      expect(ConfigLoader.readProjectId('- just\n- a list'), isNull);
    });
  });

  test('the pattern is the one push-results shares', () {
    expect(kProjectIdPattern.hasMatch('soc_top.v2-rc1'), isTrue);
    expect(kProjectIdPattern.hasMatch('soc top'), isFalse);
    expect(kProjectIdPattern.hasMatch(''), isFalse);
  });
}
