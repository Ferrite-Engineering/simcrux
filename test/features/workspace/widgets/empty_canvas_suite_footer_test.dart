// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/simcrux_url_launcher.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/services/simcrux_workspace_codec.dart';
import 'package:simcrux/features/workspace/widgets/empty_canvas_content.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

class _FakeSettingsNotifier extends AppSettingsNotifier {
  _FakeSettingsNotifier(this._settings);
  final AppSettings _settings;
  static AppSettingsNotifier Function() factory(AppSettings settings) =>
      () => _FakeSettingsNotifier(settings);
  @override
  Future<AppSettings> build() async => _settings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late crux.WorkspaceService<SimcruxTabPayload> workspaceService;
  final opened = <Uri>[];

  setUp(() async {
    opened.clear();
    simcruxLaunchUrl = (uri) async {
      opened.add(uri);
      return true;
    };
    tempDir = await Directory.systemTemp.createTemp('simcrux-ws-suite-');
    workspaceService = crux.WorkspaceService<SimcruxTabPayload>(
      codec: const SimcruxWorkspaceCodec(),
      directoryFactory: () async => tempDir,
    );
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> pump(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
  }) async {
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsProvider.overrideWith(
            _FakeSettingsNotifier.factory(const AppSettings()),
          ),
          simcruxWorkspaceServiceProvider.overrideWithValue(workspaceService),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: const [
            L10N.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10N.supportedLocales,
          home: const Scaffold(body: EmptyCanvasContent()),
        ),
      ),
    );
    // The header's GlowingAppIcon runs perpetual AnimationControllers
    // (.repeat), so pumpAndSettle never completes. Advance a bounded number
    // of frames instead, as this screen's other test documents.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('the start screen carries the suite-membership line', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(crux.CruxSuiteFooter.rowKey), findsOneWidget);
  });

  testWidgets('following the line opens this product’s landing path', (
    tester,
  ) async {
    await pump(tester);
    // The peers block above it pushes the line below the fold on this
    // surface, and a tap outside the viewport silently does nothing.
    await tester.ensureVisible(find.byKey(crux.CruxSuiteFooter.rowKey));
    await tester.pump();
    await tester.tap(find.byKey(crux.CruxSuiteFooter.rowKey));
    await tester.pump();

    // Per-product path, not the shared `/products` page: the site's page-view
    // beacon records the path and drops the query string, so this segment is
    // the only thing that attributes the visit to SimCrux.
    expect(opened, [Uri.parse('https://edacrux.app/from/simcrux')]);
  });

  group('More from EDACrux', () {
    testWidgets('offers the other three, and never SimCrux itself', (
      tester,
    ) async {
      await pump(tester);
      for (final peer in crux.CruxSuiteProduct.simCrux.peers) {
        expect(
          find.byKey(crux.CruxSuitePeers.rowKeyFor(peer)),
          findsOneWidget,
          reason: '${peer.displayName} row missing',
        );
      }
      expect(
        find.byKey(
          crux.CruxSuitePeers.rowKeyFor(crux.CruxSuiteProduct.simCrux),
        ),
        findsNothing,
      );
    });

    testWidgets('a row lands on that product\u2019s card', (tester) async {
      await pump(tester);
      final row = find.byKey(
        crux.CruxSuitePeers.rowKeyFor(crux.CruxSuiteProduct.netCrux),
      );
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();

      // Same attributable path as the footer, plus a fragment the site's
      // beacon drops before sending — so the reader lands on NetCrux's card
      // and the visit is still recorded against SimCrux.
      expect(opened, [Uri.parse('https://edacrux.app/from/simcrux#netcrux')]);
    });

    testWidgets('every locale names all three products', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await pump(tester, locale: locale);
        expect(tester.takeException(), isNull, reason: 'locale $locale');
        for (final peer in crux.CruxSuiteProduct.simCrux.peers) {
          // Product names are never translated.
          expect(
            find.text(peer.displayName),
            findsOneWidget,
            reason: '$locale dropped ${peer.displayName}',
          );
        }
      }
    });
  });

  testWidgets('every locale keeps the linked domain verbatim', (tester) async {
    for (final locale in const [
      Locale('en'),
      Locale('zh', 'CN'),
      Locale('zh'),
      Locale('ja'),
      Locale('ko'),
    ]) {
      await pump(tester, locale: locale);
      expect(tester.takeException(), isNull, reason: 'locale $locale');

      await tester.ensureVisible(find.byKey(crux.CruxSuiteFooter.rowKey));
      await tester.pump();
      final rendered = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(crux.CruxSuiteFooter.rowKey),
              matching: find.byType(Text),
            ),
          )
          .textSpan!
          .toPlainText();
      // The widget splits the sentence around this literal to underline it. A
      // translation that paraphrased the domain would render a line with
      // nothing to click, which is not a visible failure.
      expect(
        rendered,
        contains(crux.CruxSuiteFooter.defaultLinkText),
        reason: 'locale $locale dropped the linked domain',
      );
      expect(rendered, contains('EDACrux'), reason: 'locale $locale');
    }
  });
}
