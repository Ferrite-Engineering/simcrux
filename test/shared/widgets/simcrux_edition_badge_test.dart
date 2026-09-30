// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/shared/widgets/simcrux_edition_badge.dart';

Widget _harness(
  Widget child, {
  required LicenseTier tier,
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [licenseTierProvider.overrideWithValue(tier)],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: L10N.localizationsDelegates,
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  group('SimCruxEditionBadge', () {
    // Renders NOTHING at open core, and that is the property that lets this be
    // mounted unconditionally in shared chrome. If it ever breaks, every
    // open-core build starts advertising an edition it does not have.
    testWidgets('renders nothing at Open Core', (tester) async {
      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.openCore),
      );
      expect(find.text('EDU'), findsNothing);
      expect(find.text('PRO'), findsNothing);
      expect(find.text('ENT'), findsNothing);
    });

    // These three replace assertions that this badge renders NOTHING at pro and
    // enterprise. That was correct for the EDU-only badge it grew out of, and
    // it is the exact behaviour the generalization exists to remove: a paying
    // customer saw nothing anywhere stating what they were running.
    testWidgets('renders EDU for an Educational licence', (tester) async {
      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.edu),
      );
      expect(find.text('EDU'), findsOneWidget);
    });

    testWidgets('renders PRO for a Pro licence', (tester) async {
      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.pro),
      );
      expect(find.text('PRO'), findsOneWidget);
    });

    testWidgets('renders ENT for an Enterprise licence', (tester) async {
      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.enterprise),
      );
      expect(find.text('ENT'), findsOneWidget);
    });

    testWidgets('follows the provider with no call-site involvement', (
      tester,
    ) async {
      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.pro),
      );
      expect(find.text('PRO'), findsOneWidget);

      await tester.pumpWidget(
        _harness(const SimCruxEditionBadge(), tier: LicenseTier.enterprise),
      );
      expect(find.text('ENT'), findsOneWidget);
      expect(find.text('PRO'), findsNothing);
    });

    testWidgets('locale sweep — renders without exceptions in en/zh_CN/ja/ko', (
      tester,
    ) async {
      const locales = [
        Locale('en'),
        Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN'),
        Locale('ja'),
        Locale('ko'),
      ];
      for (final locale in locales) {
        for (final tier in [
          LicenseTier.edu,
          LicenseTier.pro,
          LicenseTier.enterprise,
        ]) {
          await tester.pumpWidget(
            _harness(
              const SimCruxEditionBadge(),
              tier: tier,
              locale: locale,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason:
                'SimCruxEditionBadge raised at ${tier.name} in locale '
                '${locale.toLanguageTag()}',
          );
        }
      }
    });
  });
}
