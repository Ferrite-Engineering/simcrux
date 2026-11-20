// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/license/simcrux_edu_notice_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

void main() {
  group('SimCruxEduNoticeStrings', () {
    test('English matches the package default word for word', () async {
      // The package's English is the reviewed wording; the ARB copy must not
      // drift from it.
      final strings = SimCruxEduNoticeStrings(
        await L10N.delegate.load(const Locale('en')),
      );
      const reference = CruxEduNoticeStringsEn();

      expect(strings.statusLabel, reference.statusLabel);
      expect(strings.exportMark('SimCrux'), reference.exportMark('SimCrux'));
      for (final email in <String?>['a@b.edu', null]) {
        for (final until in <String?>['2027-08-02', null]) {
          expect(
            strings.statusTooltip(email: email, validUntil: until),
            reference.statusTooltip(email: email, validUntil: until),
            reason: 'email: $email, validUntil: $until',
          );
        }
      }
    });

    for (final locale in L10N.supportedLocales) {
      test('${locale.toLanguageTag()}: every string resolves', () async {
        final strings = SimCruxEduNoticeStrings(
          await L10N.delegate.load(locale),
        );

        expect(strings.statusLabel, isNotEmpty);

        final full = strings.statusTooltip(
          email: 'a@b.edu',
          validUntil: '2027-08-02',
        );
        expect(full, contains('a@b.edu'));
        expect(full, contains('2027-08-02'));

        final bare = strings.statusTooltip();
        expect(bare, isNot(contains('a@b.edu')));
        expect(bare, isNot(contains('2027-08-02')));
        expect(bare, isNot(contains('{')));

        // Exports are English documents, so the mark is English in every
        // locale.
        expect(
          strings.exportMark('SimCrux'),
          const CruxEduNoticeStringsEn().exportMark('SimCrux'),
        );
      });
    }
  });
}
