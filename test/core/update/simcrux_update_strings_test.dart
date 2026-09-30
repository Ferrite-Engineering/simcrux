// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/update/simcrux_update_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The four shipped locales. `zh` mirrors `zh_CN` byte-for-byte (guarded by
/// `test/static/l10n_house_style_guard_test.dart`), so sweeping `zh_CN` covers
/// both.
const _locales = [
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('ja'),
  Locale('ko'),
];

void main() {
  group('SimcruxUpdateStrings', () {
    test('every getter resolves in every shipped locale', () async {
      for (final locale in _locales) {
        final l10n = await L10N.delegate.load(locale);
        final strings = SimcruxUpdateStrings(l10n);

        final values = <String, String>{
          'bannerMessage': strings.bannerMessage('1.2.3'),
          'viewChangesAction': strings.viewChangesAction,
          'updateNowAction': strings.updateNowAction,
          'dismissLabel': strings.dismissLabel,
          'checkInProgress': strings.checkInProgress,
          'checkUpToDate': strings.checkUpToDate('1.2.3'),
          'checkFailed': strings.checkFailed,
        };

        for (final entry in values.entries) {
          expect(
            entry.value.trim(),
            isNotEmpty,
            reason: '${entry.key} is empty in $locale',
          );
        }
      }
    });

    test('the version is interpolated, not dropped', () async {
      for (final locale in _locales) {
        final strings = SimcruxUpdateStrings(await L10N.delegate.load(locale));
        expect(
          strings.bannerMessage('9.9.9'),
          contains('9.9.9'),
          reason: 'bannerMessage must name the version in $locale',
        );
        expect(
          strings.checkUpToDate('9.9.9'),
          contains('9.9.9'),
          reason: 'checkUpToDate must name the version in $locale',
        );
      }
    });

    test('the English banner names the product', () async {
      final strings = SimcruxUpdateStrings(
        await L10N.delegate.load(const Locale('en')),
      );
      // The product name belongs to the product's own ARB entry — the package
      // interface only passes the version.
      expect(strings.bannerMessage('1.0.0'), contains('SimCrux'));
    });

    test(
      'translations are distinct from English (not untranslated copies)',
      () async {
        final en = SimcruxUpdateStrings(
          await L10N.delegate.load(const Locale('en')),
        );
        for (final locale in _locales.skip(1)) {
          final other = SimcruxUpdateStrings(await L10N.delegate.load(locale));
          expect(
            other.updateNowAction,
            isNot(en.updateNowAction),
            reason: 'updateNowAction looks untranslated in $locale',
          );
        }
      },
    );
  });
}
