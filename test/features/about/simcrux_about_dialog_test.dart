// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_app_info/crux_app_info.dart';
import 'package:crux_license/crux_license.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/features/about/simcrux_about_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

// ── Shared stub data ──────────────────────────────────────────────────────────

const _stubBuildInfo = ApplicationBuildInfo(
  version: '1.2.3',
  buildNumber: '42',
  gitShortSha: 'abc1234',
  os: 'macOS 15.0',
  architecture: 'arm64',
  flutterSdkVersion: '3.29.0',
  dartSdkVersion: '3.7.0',
);

// ── Shared overrides ──────────────────────────────────────────────────────────

List<Override> _baseOverrides({LicenseTier tier = LicenseTier.openCore}) => [
  aboutBuildInfoProvider.overrideWith((_) async => _stubBuildInfo),
  if (tier != LicenseTier.openCore)
    licenseTierProvider.overrideWith((_) => tier),
];

// ── Host that triggers SimcruxAboutDialog.openAdaptive ────────────────────────

/// Renders a single button that opens the About dialog via `openAdaptive`,
/// so the test exercises SimCrux's mapping (title, build info, actions).
Widget _buildApp({
  Locale locale = const Locale('en'),
  LicenseTier tier = LicenseTier.openCore,
}) => ProviderScope(
  overrides: _baseOverrides(tier: tier),
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: L10N.localizationsDelegates,
    supportedLocales: L10N.supportedLocales,
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) => Center(
          child: ElevatedButton(
            onPressed: () => SimcruxAboutDialog.openAdaptive(context, ref),
            child: const Text('open-about'),
          ),
        ),
      ),
    ),
  ),
);

// ── Pump + open helper ────────────────────────────────────────────────────────

/// Opens the dialog and advances enough frames to resolve the awaited build
/// info future and the route push / dialog show.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.tap(find.text('open-about'));
  await tester.pump(); // run handler up to the build-info await
  await tester.pump(); // resolve the build-info future microtask
  await tester.pump(
    const Duration(milliseconds: 300),
  ); // route/dialog transition
}

// ─────────────────────────────────────────────────────────────────────────────

void main() {
  group('locale sweeps', () {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      testWidgets('renders without exception in $locale', (tester) async {
        await tester.pumpWidget(_buildApp(locale: locale));
        await _openDialog(tester);
        expect(tester.takeException(), isNull, reason: '$locale');
      });
    }
  });

  group('content', () {
    testWidgets('shows dialog title', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('About SimCrux'), findsWidgets);
    });

    testWidgets('shows version number from stub build info', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('1.2.3'), findsWidgets);
    });

    testWidgets('shows git SHA from stub build info', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('abc1234'), findsWidgets);
    });

    testWidgets('shows company name in branding banner', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('Ferrite Engineering'), findsWidgets);
    });
  });

  group('edition chip', () {
    testWidgets('no edition chip shown for openCore tier', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);

      // The edition chip only renders for Pro/Enterprise; openCore is hidden.
      expect(find.text('Pro'), findsNothing);
      expect(find.text('Enterprise'), findsNothing);
    });

    testWidgets('EditionBadge shown for edu tier', (tester) async {
      await tester.pumpWidget(_buildApp(tier: LicenseTier.edu));
      await _openDialog(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('EDU'), findsWidgets);
    });
  });

  group('action buttons', () {
    testWidgets('shows the canonical suite action list in order', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      final labels = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(OutlinedButton),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .toList();
      expect(labels, const [
        'Visit Website',
        'Documentation',
        'Submit Issue…',
        'Check for Updates',
        'Privacy Policy',
        'Terms of Service',
        'Copy Version Info',
      ]);
    });

    testWidgets('shows "Visit Website" button', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('Visit Website'), findsOneWidget);
    });

    testWidgets('shows "Copy Version Info" button', (tester) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);
      expect(find.text('Copy Version Info'), findsOneWidget);
    });

    testWidgets('"Copy Version Info" button is enabled once build info loads', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await _openDialog(tester);

      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Copy Version Info'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}
