// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/help_urls.dart';

void main() {
  const contextual = <String, String>{
    'runningTests': HelpUrls.runningTests,
    'appearanceAndThemes': HelpUrls.appearanceAndThemes,
    'projectsAndSimulators': HelpUrls.projectsAndSimulators,
    'passFailDetection': HelpUrls.passFailDetection,
    'integrations': HelpUrls.integrations,
    'resultsDashboard': HelpUrls.resultsDashboard,
  };

  test('every help link lands on a docs-site page section that exists', () {
    // The help icons open `docs.simcrux.app/<page>#<section>`. A renamed page
    // or heading id would still load the site and silently drop the reader
    // at the top of the wrong place, so each target is resolved against the
    // docs source it is published from.
    final pattern = RegExp(
      r'^https://docs\.simcrux\.app/([a-z0-9-]+)#([a-z0-9-]+)$',
    );
    for (final MapEntry(key: name, value: url) in contextual.entries) {
      final match = pattern.firstMatch(url);
      expect(
        match,
        isNotNull,
        reason: '$name ($url) is not a docs page#section',
      );
      final page = File('docs-site/docs/${match!.group(1)}.md');
      expect(page.existsSync(), isTrue, reason: '$name: ${page.path} missing');
      expect(
        page.readAsStringSync(),
        contains('{#${match.group(2)}}'),
        reason: '$name: ${page.path} has no {#${match.group(2)}} heading',
      );
    }
  });

  test('the documentation home is the docs site', () {
    expect(HelpUrls.docs, 'https://docs.simcrux.app');
  });

  test('privacy and terms open the suite pages, not redirect stubs', () {
    expect(HelpUrls.privacyPolicy, 'https://edacrux.app/privacy');
    expect(HelpUrls.termsOfService, 'https://edacrux.app/terms');
  });
}
