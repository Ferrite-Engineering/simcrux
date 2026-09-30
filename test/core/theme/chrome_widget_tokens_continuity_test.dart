// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Every built-in preset must paint SimCrux's shared chrome exactly as it
// always has. The status bar, splitter, document tab bar and active toolbar
// glyph chrome tokens reach their shared widgets through `applyChromeTokens`;
// before that they reached nothing, and the widgets painted from the Material
// theme `app.dart` builds: the status bar `surfaceContainerHighest` behind
// `onSurface` at 75 %, the pane resizers `outlineVariant` and `primary` on
// hover, the active document tab `surfaceContainerHighest` under `bodyMedium`
// titles on an unfilled strip, and a toggled toolbar glyph `primary`.
//
// This pumps those widgets under every theme `app.dart` can show for each
// preset (the normal and the high-contrast variant of its brightness), built
// the same way, and asserts exactly those colours. It holds before and after
// the widgets read the tokens, which is the point: an unedited preset must not
// change. Text reaches the engine as 32-bit ARGB, so text colour is compared
// that way. The one change made on purpose, Solarized Dark's status bar text,
// is named where it is checked.

import 'dart:io';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_status_bar/crux_status_bar.dart';
import 'package:crux_theme/crux_theme.dart';
import 'package:crux_toolbar/crux_toolbar.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/core/theme/simcrux_theme.dart';
import 'package:simcrux/core/theme/simcrux_theme_tokens.dart';

class _Layout implements IdePanelLayout {
  @override
  bool get leftVisible => true;
  @override
  bool get rightVisible => false;
  @override
  bool get bottomVisible => false;
  @override
  PaneSize? get leftSize => PaneSize.pixel(200);
  @override
  PaneSize? get rightSize => null;
  @override
  PaneSize? get bottomSize => null;
}

class _Sink implements IdePanelLayoutSink {
  @override
  void setLeftVisible({required bool visible}) {}
  @override
  void setRightVisible({required bool visible}) {}
  @override
  void setBottomVisible({required bool visible}) {}
  @override
  void setLeftSize(double pixels) {}
  @override
  void setRightSize(double pixels) {}
  @override
  void setBottomSize(double pixels) {}
}

class _StringCodec extends WorkspaceCodec<String> {
  const _StringCodec();

  @override
  int get schemaVersion => 1;

  @override
  Map<String, Object?> payloadToJson(String p) => {'v': p};

  @override
  String payloadFromJson(Map<String, Object?> j) => j['v'] as String? ?? '';

  @override
  String displayNameFor(String p) => p;
}

/// The themes `app.dart` hands MaterialApp for [preset], keyed by the
/// variant MaterialApp shows for that preset's brightness.
Map<String, ThemeData> _appThemes(CruxColorTheme preset) {
  final chromeExt = CruxThemeExtension(theme: preset);
  ThemeData build(ThemeData base) => applyChromeTokens(
    base.copyWith(extensions: <ThemeExtension<dynamic>>[chromeExt]),
    chromeExt,
  );
  return preset.brightness == Brightness.light
      ? {
          'light': build(SimcruxTheme.light()),
          'high-contrast light': build(SimcruxTheme.highContrastLight()),
        }
      : {
          'dark': build(SimcruxTheme.dark()),
          'high-contrast dark': build(SimcruxTheme.highContrastDark()),
        };
}

void main() {
  setUpAll(registerSimcruxThemeTokens);

  late Directory tempDir;
  late AsyncNotifierProvider<WorkspaceNotifier<String>, Workspace<String>>
  provider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('simcrux_chrome_');
    final service = WorkspaceService<String>(
      codec: const _StringCodec(),
      directoryFactory: () async => tempDir,
      logger: (_) {},
    );
    provider =
        AsyncNotifierProvider<WorkspaceNotifier<String>, Workspace<String>>(
          () => WorkspaceNotifier<String>(
            service: service,
            autoSaveDebounce: Duration.zero,
          ),
        );
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  for (final preset in builtinPresets().values) {
    for (final variant in _appThemes(preset).entries) {
      testWidgets('${preset.id} (${variant.key}) paints the chrome it always '
          'painted', (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final ws = await container.read(provider.future);
        final notifier = container.read(provider.notifier);
        await notifier.openTab(displayName: 'alpha', payload: 'a');
        await notifier.openTab(displayName: 'beta', payload: 'b');

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: variant.value,
              home: Scaffold(
                body: Column(
                  children: [
                    CruxToolbarButton(
                      key: const ValueKey<String>('toggled'),
                      icon: Icons.sensors,
                      tooltip: 'Cross-probe',
                      onPressed: () {},
                      metrics: CruxToolbarMetrics.desktop,
                      isSelected: true,
                    ),
                    SizedBox(
                      height: 40,
                      child: ViewerTabBar<String>(
                        paneId: ws.activePaneId,
                        provider: provider,
                      ),
                    ),
                    Expanded(
                      child: CruxIdeLayout(
                        layout: _Layout(),
                        sink: _Sink(),
                        leftBuilder: (_, _) => const SizedBox.expand(),
                        centerBuilder: (_, _) => const SizedBox.expand(),
                        rightBuilder: (_, _) => const SizedBox.expand(),
                        bottomBuilder: (_, _) => const SizedBox.expand(),
                      ),
                    ),
                    const CruxStatusBar(
                      segments: [CruxStatusSegment('status')],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final theme = Theme.of(tester.element(find.byType(CruxStatusBar)));
        final scheme = theme.colorScheme;

        // Toolbar: a toggled-on glyph.
        expect(
          tester
              .widget<Icon>(
                find.descendant(
                  of: find.byKey(const ValueKey<String>('toggled')),
                  matching: find.byType(Icon),
                ),
              )
              .color,
          scheme.primary,
        );

        // Document tab bar: no strip fill, the active tab, the titles.
        final strip = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(ViewerTabBar<String>),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect((strip.decoration as BoxDecoration).color, isNull);
        Color? chip(String title) =>
            (tester
                        .widget<Container>(
                          find
                              .ancestor(
                                of: find.text(title),
                                matching: find.byType(Container),
                              )
                              .first,
                        )
                        .decoration!
                    as BoxDecoration)
                .color;
        expect(chip('beta'), scheme.surfaceContainerHighest);
        expect(chip('alpha'), isNull);
        for (final title in ['alpha', 'beta']) {
          expect(
            tester.widget<Text>(find.text(title)).style,
            theme.textTheme.bodyMedium,
          );
        }

        // Pane resizer: the visible bar is the second of the containers
        // under the resizer's mouse region.
        final resizer = find
            .byWidgetPredicate(
              (w) =>
                  w is MouseRegion &&
                  w.cursor == SystemMouseCursors.resizeColumn,
            )
            .first;
        Color? resizerBar() => tester
            .widgetList<Container>(
              find.descendant(of: resizer, matching: find.byType(Container)),
            )
            .elementAt(1)
            .color;
        expect(resizerBar(), scheme.outlineVariant);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(resizer));
        await tester.pump();
        expect(resizerBar(), scheme.primary);

        // Status bar: the surface and the baseline text.
        final bar = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(CruxStatusBar),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(
          (bar.decoration as BoxDecoration).color,
          scheme.surfaceContainerHighest,
        );
        // The one deliberate departure: Solarized Dark's status bar text
        // blended to 3.76:1 against WCAG AA's 4.5:1, so the shared preset now
        // paints its declared opaque #93A1A1 (5.61:1) instead of the 75 %
        // blend. crux_theme's contrast suite is where that ratio is measured.
        expect(
          tester.widget<Text>(find.text('status')).style?.color?.toARGB32(),
          preset.id == 'solarized-dark'
              ? const Color(0xFF93A1A1).toARGB32()
              : scheme.onSurface.withValues(alpha: 0.75).toARGB32(),
        );
      });
    }
  }
}
