// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/widgets/simcrux_feature_tier_badge.dart';

Widget _harness(Widget child, {Locale locale = const Locale('en')}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: L10N.localizationsDelegates,
    supportedLocales: L10N.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  group('SimCruxFeatureTierBadge', () {
    testWidgets('open-core tier renders nothing (zero-size SizedBox)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(
          const SimCruxFeatureTierBadge(requiredTier: LicenseTier.openCore),
        ),
      );
      expect(find.text('PRO'), findsNothing);
      expect(find.text('ENT'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('Pro tier renders the PRO chip', (tester) async {
      await tester.pumpWidget(
        _harness(const SimCruxFeatureTierBadge(requiredTier: LicenseTier.pro)),
      );
      expect(find.text('PRO'), findsOneWidget);
      expect(find.text('ENT'), findsNothing);
    });

    testWidgets('Enterprise tier renders the ENT chip', (tester) async {
      await tester.pumpWidget(
        _harness(
          const SimCruxFeatureTierBadge(requiredTier: LicenseTier.enterprise),
        ),
      );
      expect(find.text('ENT'), findsOneWidget);
      expect(find.text('PRO'), findsNothing);
    });

    testWidgets('EDU tier renders nothing (no feature is gate-labeled as EDU; '
        'EDU is a license edition surfaced by EditionBadge instead)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(const SimCruxFeatureTierBadge(requiredTier: LicenseTier.edu)),
      );
      expect(find.text('EDU'), findsNothing);
      expect(find.text('PRO'), findsNothing);
      expect(find.text('ENT'), findsNothing);
      expect(find.byType(SizedBox), findsWidgets);
    });

    testWidgets('locale sweep — renders without exceptions in en/zh_CN/ja/ko', (
      tester,
    ) async {
      const locales = <Locale>[
        Locale('en'),
        Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
        Locale('ja'),
        Locale('ko'),
      ];
      for (final locale in locales) {
        await tester.pumpWidget(
          _harness(
            const SimCruxFeatureTierBadge(requiredTier: LicenseTier.pro),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason:
              'SimCruxFeatureTierBadge raised in locale ${locale.toLanguageTag()}',
        );
      }
    });
  });
}
