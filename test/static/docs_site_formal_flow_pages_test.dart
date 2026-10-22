// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The Formal and Flow pages of docs-site deploy on merge, ahead of the release
// that ships what they describe. This guard holds the parts a build cannot:
// every page is in the nav, says "from 1.2", carries no em dash, and never
// words a bounded formal result as verified.
//
// MUTATION: add a page named flow-x.md without a nav entry, or write a
// "verified" into formal.md, and this fails.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final docs = Directory('docs-site/docs');
  final pages = <File>[
    File('docs-site/docs/formal.md'),
    ...docs.listSync().whereType<File>().where(
      (f) => f.uri.pathSegments.last.startsWith('flow'),
    ),
  ];
  final nav = File('docs-site/mkdocs.yml').readAsStringSync();

  test('the pages exist', () {
    expect(pages.length, greaterThanOrEqualTo(8));
    for (final page in pages) {
      expect(page.existsSync(), isTrue, reason: page.path);
    }
  });

  test('every page is in the nav and says from 1.2', () {
    for (final page in pages) {
      final name = page.uri.pathSegments.last;
      expect(nav, contains(': $name'), reason: '$name is not in mkdocs nav');
      expect(
        page.readAsStringSync(),
        contains('from 1.2'),
        reason: '$name must say "from 1.2"',
      );
    }
  });

  test('no em dash and no unscoped claims', () {
    for (final page in pages) {
      final text = page.readAsStringSync();
      expect(text, isNot(contains('—')), reason: page.path);
    }
    final formal = File('docs-site/docs/formal.md').readAsStringSync();
    expect(formal.toLowerCase(), isNot(contains('verified')));
    expect(formal, isNot(contains('EDA Crux')));
  });

  test('formal.md includes the generated SVA table', () {
    final formal = File('docs-site/docs/formal.md').readAsStringSync();
    expect(formal, contains('--8<-- "sva-support-table.md"'));
    expect(nav, contains('pymdownx.snippets'));
    expect(
      File('docs-site/generated/sva-support-table.md').existsSync(),
      isTrue,
    );
  });
}
