// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/issue_reporter/simcrux_issue_reporter_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

const _locales = [
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('ja'),
  Locale('ko'),
];

void main() {
  group('SimcruxIssueReporterStrings', () {
    test('every getter resolves in every shipped locale', () async {
      for (final locale in _locales) {
        final l10n = await L10N.delegate.load(locale);
        final s = SimcruxIssueReporterStrings(l10n);

        final values = <String, String>{
          'dialogTitle': s.dialogTitle,
          'titleFieldLabel': s.titleFieldLabel,
          'titleFieldHint': s.titleFieldHint,
          'privacyNotice': s.privacyNotice,
          'previewHeader': s.previewHeader,
          'categoryAppEnv': s.categoryAppEnv,
          'categoryAppEnvDescription': s.categoryAppEnvDescription,
          'categorySession': s.categorySession,
          'categorySessionDescription': s.categorySessionDescription,
          'categoryLog': s.categoryLog,
          'categoryLogDescription': s.categoryLogDescription,
          'categoryScreenshot': s.categoryScreenshot,
          'categoryScreenshotDescription': s.categoryScreenshotDescription,
          'lockedCategorySemantics': s.lockedCategorySemantics,
          'submitButton': s.submitButton,
          'cancelButton': s.cancelButton,
          'openedToast': s.openedToast,
          'openedToastPrefilled': s.openedToastPrefilled,
          'screenshotSaved': s.screenshotSaved('/tmp/shot.png'),
          'emptyLogPlaceholder': s.emptyLogPlaceholder,
          'emptySessionLogPlaceholder': s.emptySessionLogPlaceholder,
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

    test('screenshotSaved interpolates the path in every locale', () async {
      for (final locale in _locales) {
        final s = SimcruxIssueReporterStrings(
          await L10N.delegate.load(locale),
        );
        expect(s.screenshotSaved('/tmp/simcrux-1.png'), contains('/tmp'));
      }
    });

    test(
      'the privacy notice states the no-paths guarantee in English',
      () async {
        final s = SimcruxIssueReporterStrings(
          await L10N.delegate.load(const Locale('en')),
        );
        expect(s.privacyNotice.toLowerCase(), contains('file paths'));
      },
    );

    test('translations are distinct from English', () async {
      final en = SimcruxIssueReporterStrings(
        await L10N.delegate.load(const Locale('en')),
      );
      for (final locale in _locales.skip(1)) {
        final other = SimcruxIssueReporterStrings(
          await L10N.delegate.load(locale),
        );
        expect(
          other.submitButton,
          isNot(en.submitButton),
          reason: 'submitButton looks untranslated in $locale',
        );
      }
    });
  });
}
