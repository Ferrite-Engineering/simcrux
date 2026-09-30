// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the page metadata of the hosted web results viewer.
///
/// `web/index.html` and `web/manifest.json` are what a browser tab, a search
/// result snippet, a link preview and an installed PWA show before any Dart
/// runs. `flutter create` fills them with generator placeholders (a lowercase
/// package name as the title, "A new Flutter project." as the description,
/// Flutter's blue as the theme colour), and a regenerated `web/` directory
/// writes those placeholders back without any build or test noticing. The
/// viewer is linked from the product sites, so the placeholders are the first
/// thing a visitor reads. Hence a static test rather than a review
/// convention.
void main() {
  group('web/index.html', () {
    late String html;

    setUpAll(() {
      final file = File('web/index.html');
      expect(file.existsSync(), isTrue, reason: 'web/index.html is missing.');
      html = file.readAsStringSync();
    });

    test('has a product title, not the package name', () {
      final title = _element(html, 'title');
      expect(title, isNotNull, reason: 'index.html has no <title>.');
      _expectProductText(title!, where: '<title>');
    });

    test('has a product description, not the generator placeholder', () {
      final description = _meta(html, 'name', 'description');
      expect(
        description,
        isNotNull,
        reason: 'index.html has no <meta name="description">.',
      );
      _expectProductText(description!, where: 'meta description');
      expect(
        description,
        contains('SimCrux'),
        reason:
            'The description is the search-result snippet; it should name '
            'the product.',
      );
    });

    test('names the product as the home-screen title', () {
      final title = _meta(html, 'name', 'apple-mobile-web-app-title');
      expect(title, isNotNull);
      _expectProductText(title!, where: 'apple-mobile-web-app-title');
    });

    test('carries no generator placeholder anywhere', () {
      for (final placeholder in _generatorPlaceholders) {
        expect(
          html.contains(placeholder),
          isFalse,
          reason: 'index.html still carries "$placeholder".',
        );
      }
    });
  });

  group('web/manifest.json', () {
    late Map<String, Object?> manifest;

    setUpAll(() {
      final file = File('web/manifest.json');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'web/manifest.json is missing.',
      );
      manifest = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    });

    for (final key in const ['name', 'short_name', 'description']) {
      test('"$key" is product text, not a generator placeholder', () {
        final value = manifest[key];
        expect(value, isA<String>(), reason: 'manifest.json has no "$key".');
        _expectProductText(value! as String, where: 'manifest "$key"');
      });
    }

    for (final key in const ['theme_color', 'background_color']) {
      test('"$key" is not the generator default colour', () {
        expect(
          (manifest[key] as String?)?.toUpperCase(),
          isNot(_generatorThemeColor),
          reason:
              'manifest "$key" is still Flutter\'s template blue; use the '
              'SimCrux palette.',
        );
      });
    }
  });
}

/// Strings `flutter create` writes into `web/` that must not survive into a
/// published page.
const _generatorPlaceholders = ['A new Flutter project.', '#0175C2'];

/// The template's theme and background colour.
const _generatorThemeColor = '#0175C2';

/// Fails when [value] is empty, is the bare lowercase package name the
/// template uses as every title, or is the template's description.
void _expectProductText(String value, {required String where}) {
  final trimmed = value.trim();
  expect(trimmed, isNotEmpty, reason: '$where is empty.');
  expect(
    trimmed,
    isNot('simcrux'),
    reason:
        '$where is the lowercase package name `flutter create` writes; use '
        'the product name, SimCrux.',
  );
  expect(
    trimmed,
    isNot('A new Flutter project.'),
    reason: '$where is the `flutter create` placeholder.',
  );
}

/// The text content of the first `<tag>` element in [html], or `null`.
String? _element(String html, String tag) =>
    RegExp('<$tag[^>]*>([^<]*)</$tag>').firstMatch(html)?.group(1);

/// The `content` of the first `<meta>` whose [attribute] is [value], or
/// `null`. Attribute order varies between editors and templates, so the tag
/// is found first and `content` read from it separately.
String? _meta(String html, String attribute, String value) {
  final tags = RegExp(r'<meta\s[^>]*>').allMatches(html);
  for (final tag in tags) {
    final text = tag.group(0)!;
    if (!RegExp('$attribute="${RegExp.escape(value)}"').hasMatch(text)) {
      continue;
    }
    return RegExp('content="([^"]*)"').firstMatch(text)?.group(1);
  }
  return null;
}
