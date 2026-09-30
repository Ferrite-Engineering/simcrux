// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/license/simcrux_license_badge_strings.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

Future<L10N> _l10nFor(WidgetTester tester, Locale locale) async {
  late L10N captured;
  await tester.pumpWidget(
    Localizations(
      locale: locale,
      delegates: const [
        ...L10N.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      child: Builder(
        builder: (context) {
          captured = L10N.of(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return captured;
}

void main() {
  group('SimCruxLicenseBadgeStrings', () {
    testWidgets(
      'routes every chip-string getter to the L10N equivalent in en',
      (tester) async {
        final l10n = await _l10nFor(tester, const Locale('en'));
        final strings = SimCruxLicenseBadgeStrings(l10n);

        expect(strings.tierBadgePro, l10n.tierBadgePro);
        expect(strings.tierBadgeProSemantic, l10n.tierBadgeProSemantic);
        expect(strings.tierBadgeEnterprise, l10n.tierBadgeEnterprise);
        expect(
          strings.tierBadgeEnterpriseSemantic,
          l10n.tierBadgeEnterpriseSemantic,
        );
        expect(strings.tierBadgeEdu, l10n.tierBadgeEdu);
        expect(strings.tierBadgeEduSemantic, l10n.tierBadgeEduSemantic);
      },
    );

    testWidgets('returns localized values in zh_CN', (tester) async {
      final l10n = await _l10nFor(
        tester,
        const Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
      );
      final strings = SimCruxLicenseBadgeStrings(l10n);

      // Pin only the routing path (not exact translations — those live in
      // the ARB diffs).
      expect(strings.tierBadgeEdu, l10n.tierBadgeEdu);
      expect(strings.tierBadgeEduSemantic, l10n.tierBadgeEduSemantic);
    });

    testWidgets('returns localized values in ja', (tester) async {
      final l10n = await _l10nFor(tester, const Locale('ja'));
      final strings = SimCruxLicenseBadgeStrings(l10n);

      expect(strings.tierBadgePro, l10n.tierBadgePro);
      expect(strings.tierBadgeProSemantic, l10n.tierBadgeProSemantic);
    });

    testWidgets('returns localized values in ko', (tester) async {
      final l10n = await _l10nFor(tester, const Locale('ko'));
      final strings = SimCruxLicenseBadgeStrings(l10n);

      expect(strings.tierBadgePro, l10n.tierBadgePro);
      expect(
        strings.tierBadgeEnterpriseSemantic,
        l10n.tierBadgeEnterpriseSemantic,
      );
    });
  });
}
