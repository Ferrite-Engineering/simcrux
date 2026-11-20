// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_license/crux_license.dart';
import 'package:crux_settings/crux_settings.dart';
import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/widgets/regression_status_bar.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_edu_status_chip.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/plugins/status_bar_trailing_widgets_provider.dart';
import 'package:simcrux/services/settings/simcrux_settings_codec.dart';
import 'package:simcrux/shared/widgets/simcrux_edition_badge.dart';

import '../../../support/edu_license_status.dart';

/// Settings' Appearance section resolves the application-support directory;
/// `flutter test` has no path_provider plugin on every host, so a temp dir
/// stands in.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this._root);

  final Directory _root;

  @override
  Future<String?> getApplicationSupportPath() async => _root.path;

  @override
  Future<String?> getTemporaryPath() async => _root.path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _root.path;

  @override
  Future<String?> getApplicationCachePath() async => _root.path;
}

const Key _extensionMarker = Key('extension-slot');

Future<Widget> _harness(
  Widget child, {
  required CruxLicenseStatus status,
  Locale locale = const Locale('en'),
  List<Widget> extensionSlot = const <Widget>[
    // A visible stand-in for whatever the Pro overlay injects, so the
    // chip's place after the extension slot can be measured.
    SizedBox(key: _extensionMarker, width: 10, height: 10),
  ],
}) async {
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      licenseStatusProvider.overrideWithValue(status),
      // The tier follows the status, as the Pro overlay's override does.
      licenseTierProvider.overrideWithValue(status.tier),
      dashboardTotalsProvider.overrideWith(
        (ref) => const Stream<DashboardTotals>.empty(),
      ),
      statusBarTrailingWidgetsProvider.overrideWithValue(extensionSlot),
      settingsServiceProvider.overrideWithValue(
        SettingsService<AppSettings>(
          const SimcruxSettingsCodec(),
          prefsOverride: prefs,
        ),
      ),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: L10N.localizationsDelegates,
      supportedLocales: L10N.supportedLocales,
      home: Scaffold(
        body: Column(children: <Widget>[const Spacer(), child]),
      ),
    ),
  );
}

const _bar = RegressionStatusBar(configPath: '/work/soc/simcrux.yaml');

void main() {
  late Directory tmpDir;
  late PathProviderPlatform priorPathProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('simcrux_edu_chip_test');
    priorPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FakePathProvider(tmpDir);
  });

  tearDown(() {
    PathProviderPlatform.instance = priorPathProvider;
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('status bar under an educational licence', () {
    testWidgets('shows the EDU chip, the notice and the address', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      expect(find.byType(CruxEduStatusChip), findsOneWidget);
      expect(
        find.text('Non-commercial use · $kTestEduEmail'),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(CruxEduStatusChip),
          matching: find.byType(EditionBadge),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('sits after the extension slot, in the trailing group', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      final bar = tester.widget<CruxStatusBar>(find.byType(CruxStatusBar));
      expect(bar.trailing.last, isA<SimCruxEduStatusChip>());
      expect(
        tester.getTopLeft(find.byType(CruxEduStatusChip)).dx,
        greaterThan(tester.getTopRight(find.byKey(_extensionMarker)).dx),
      );
    });

    testWidgets('uses the status bar text style', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      final context = tester.element(find.byType(CruxEduStatusChip));
      final chip = tester.widget<CruxEduStatusChip>(
        find.byType(CruxEduStatusChip),
      );
      expect(chip.textStyle, CruxStatusBar.resolveTextStyle(context));
    });

    testWidgets('the tooltip names the terms and the end date', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      final tooltip = tester.widget<Tooltip>(
        find.descendant(
          of: find.byType(CruxEduStatusChip),
          matching: find.byType(Tooltip),
        ),
      );
      expect(
        tooltip.message,
        'Educational license for $kTestEduEmail. For non-commercial '
        'teaching, learning and research only. Valid until 2027-08-02.',
      );
    });

    testWidgets('a click opens Settings at the License category', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      await tester.tap(find.byType(CruxEduStatusChip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester
            .widget<CruxSettingsInitialCategory>(
              find.byType(CruxSettingsInitialCategory),
            )
            .id,
        kCruxLicenseCategoryId,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tab reaches it and Enter opens Settings at License', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(_bar, status: testLicenseStatus(LicenseTier.edu)),
      );
      await tester.pump();

      // The chip is the bar's only focusable control in this harness.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester
            .widget<CruxSettingsInitialCategory>(
              find.byType(CruxSettingsInitialCategory),
            )
            .id,
        kCruxLicenseCategoryId,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the empty-canvas bar carries it too', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(
          const Builder(builder: RegressionStatusBar.idle),
          status: testLicenseStatus(LicenseTier.edu),
        ),
      );
      await tester.pump();

      expect(
        find.text('Non-commercial use · $kTestEduEmail'),
        findsOneWidget,
      );
    });
  });

  group('one edition statement in the bar', () {
    // The Pro overlay mounts SimCruxEditionBadge in the extension slot. Under
    // an educational licence the EDU notice carries the only EDU chip.
    testWidgets('EDU: the notice is the only EDU badge', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        await _harness(
          _bar,
          status: testLicenseStatus(LicenseTier.edu),
          extensionSlot: const <Widget>[SimCruxEditionBadge()],
        ),
      );
      await tester.pump();

      expect(find.byType(EditionBadge), findsOneWidget);
      expect(find.text('EDU'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(CruxEduStatusChip),
          matching: find.byType(EditionBadge),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    for (final (tier, label) in const <(LicenseTier, String)>[
      (LicenseTier.pro, 'PRO'),
      (LicenseTier.enterprise, 'ENT'),
    ]) {
      testWidgets('${tier.name}: the edition badge says $label, no notice', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1400, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          await _harness(
            _bar,
            status: testLicenseStatus(tier),
            extensionSlot: const <Widget>[SimCruxEditionBadge()],
          ),
        );
        await tester.pump();

        expect(find.text(label), findsOneWidget);
        expect(find.byType(CruxEduStatusChip), findsNothing);
        expect(find.textContaining('Non-commercial'), findsNothing);
      });
    }
  });

  group('status bar under any other licence', () {
    for (final status in kUnmarkedLicenseStatuses) {
      testWidgets('shows no notice at ${status.tier.name}', (tester) async {
        await tester.pumpWidget(await _harness(_bar, status: status));
        await tester.pump();

        expect(find.byType(CruxEduStatusChip), findsNothing);
        expect(find.textContaining('Non-commercial'), findsNothing);
        // Weightless: the mount leaves no padding behind.
        expect(
          tester.getSize(find.byType(SimCruxEduStatusChip)),
          Size.zero,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('locale sweep', () {
    for (final locale in L10N.supportedLocales) {
      testWidgets('renders without exceptions in ${locale.toLanguageTag()}', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1400, 600));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          await _harness(
            _bar,
            status: testLicenseStatus(LicenseTier.edu),
            locale: locale,
          ),
        );
        await tester.pump();

        final l10n = await L10N.delegate.load(locale);
        expect(
          find.text('${l10n.eduNoticeStatusLabel} · $kTestEduEmail'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  });
}
