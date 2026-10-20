// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a screen reader user hears in Settings > CXP Cross-Probe, asserted.
//
// The section is the suite's shared one, bound to SimCrux. The transcript under
// `goldens/` is what the focus walk records, in text and independent of the
// renderer; a change in what is announced shows up as a diff there. Rewrite it
// with `flutter test --update-goldens test/accessibility/cxp_settings_focus_walk_test.dart`
// and read the diff before committing it.

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart' show CruxDesktopTokens;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/features/settings/widgets/settings_remote_control_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../support/cxp_test_overrides.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets(
    'the CXP settings are one named Tab stop per control, in order',
    (tester) async {
      final handle = tester.ensureSemantics();
      tester.view
        ..physicalSize = const Size(1600, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: simcruxCxpTestOverrides(running: true),
          child: MaterialApp(
            theme: ThemeData(
              extensions: const <ThemeExtension<dynamic>>[CruxDesktopTokens()],
            ),
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: SettingsRemoteControlSection(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'Settings > CXP Cross-Probe');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/settings_cxp.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
