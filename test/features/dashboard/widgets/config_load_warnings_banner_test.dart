// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/config_loader_error.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/config_load_warnings_provider.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/config_load_warnings_banner.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/config/config_loader.dart';

/// A config the real loader produced with the post-beta Open Core gate
/// closed: [sweeps] `seeds:` sweeps that each ran once, so that many
/// advisories.
Future<RegressionConfig> _gatedConfig({int sweeps = 1}) => ConfigLoader(
  // Pinned, not defaulted: this tests post-beta behaviour on purpose.
  // ignore: avoid_redundant_argument_values
  betaPeriod: false,
  readFile: (_) async =>
      '''
version: "1"
suites:
  unit:
    simulator: icarus
    tests:
${[for (var i = 0; i < sweeps; i++) '      - name: sweep$i\n        top: tb\n        seeds: [1, 2, 3]'].join('\n')}
''',
).load('/p/simcrux.yaml');

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required RegressionConfig? config,
  bool show = true,
  Locale locale = const Locale('en'),
}) async {
  final container = ProviderContainer(
    overrides: [showConfigLoadWarningsProvider.overrideWithValue(show)],
  );
  addTearDown(container.dispose);
  container.read(activeConfigProvider.notifier).replace(config);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(body: ConfigLoadWarningsBanner()),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  late RegressionConfig gated;

  setUpAll(() async {
    gated = await _gatedConfig();
    expect(gated.loadWarnings, hasLength(1));
  });

  testWidgets('shows the heading and each advisory with its location', (
    tester,
  ) async {
    await _pump(tester, config: gated);
    final l10n = L10N.of(tester.element(find.byType(ConfigLoadWarningsBanner)));
    expect(find.text(l10n.configLoadWarningsTitle(1)), findsOneWidget);
    expect(find.text(gated.loadWarnings.single.format()), findsOneWidget);
    expect(find.textContaining('requires SimCrux Pro'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('announces the heading when a project loads with warnings', (
    tester,
  ) async {
    final recorder = AnnouncementRecorder.attach(tester);
    await _pump(tester, config: gated);
    await tester.pump();
    final l10n = L10N.of(tester.element(find.byType(ConfigLoadWarningsBanner)));
    expect(recorder.messages, [l10n.configLoadWarningsTitle(1)]);
  });

  testWidgets('Dismiss hides it until a load brings different advisories', (
    tester,
  ) async {
    final container = await _pump(tester, config: gated);
    final l10n = L10N.of(tester.element(find.byType(ConfigLoadWarningsBanner)));
    await tester.tap(find.text(l10n.configLoadWarningsDismiss));
    await tester.pump();
    expect(find.text(l10n.configLoadWarningsTitle(1)), findsNothing);

    final twoSweeps = await tester.runAsync(() => _gatedConfig(sweeps: 2));
    container.read(activeConfigProvider.notifier).replace(twoSweeps);
    await tester.pump();
    expect(find.text(l10n.configLoadWarningsTitle(2)), findsOneWidget);
  });

  testWidgets('renders nothing when the seam hides warnings', (tester) async {
    await _pump(tester, config: gated, show: false);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('renders nothing for a clean project', (tester) async {
    final clean = gated.copyWith(loadWarnings: const <ConfigLoaderError>[]);
    await _pump(tester, config: clean);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('locale sweep: en / zh_CN / zh / ja / ko', (tester) async {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      await _pump(tester, config: gated, locale: locale);
      expect(find.byType(TextButton), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale');
    }
  });
}
