// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/enums/riscv_toolchain_component.dart';
import 'package:simcrux/domain/models/riscv_toolchain_report.dart';
import 'package:simcrux/features/diagnostics/widgets/riscv_toolchain_report_view.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

// The one RISC-V surface a widget renders, and therefore the one covered
// by the five-locale ARB sweep. Config-loader diagnostics and
// `SimulatorNotAvailableException.remediation` are unlocalized English with
// no localization channel and are deliberately out of scope.
//
// Toolchain guidance is GRADED behaviour, not polish, so the sweep is two
// dimensional: five locales × three platforms × four components, all
// rendered from one CI runner. The Windows copy — the one carrying the
// WSL2 answer, and the one least likely to be exercised by hand — gets the
// same coverage as the others.

const _locales = <Locale>[
  Locale('en'),
  Locale('zh', 'CN'),
  Locale('zh'),
  Locale('ja'),
  Locale('ko'),
];

RiscvToolchainReport _reportWith({required bool complete}) =>
    RiscvToolchainReport(
      components: <RiscvComponentReport>[
        for (final component in RiscvToolchainComponent.values)
          RiscvComponentReport(
            component: component,
            binary: 'some-binary',
            found: complete,
            version: complete ? '1.2.3' : null,
            remediation: complete ? null : 'English log-facing guidance.',
          ),
      ],
    );

Widget _host(
  Widget child, {
  required Locale locale,
  double width = 560,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const [
    L10N.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: L10N.supportedLocales,
  home: Scaffold(
    body: SizedBox(
      width: width,
      child: SingleChildScrollView(child: child),
    ),
  ),
);

void main() {
  group('locale × platform sweep', () {
    for (final locale in _locales) {
      for (final platform in RiscvHostPlatform.values) {
        testWidgets(
          'renders without overflow — ${locale.toLanguageTag()} / '
          '${platform.wireName}',
          (tester) async {
            await tester.pumpWidget(
              _host(
                RiscvToolchainReportView(
                  report: _reportWith(complete: false),
                  platform: platform,
                ),
                locale: locale,
              ),
            );
            expect(tester.takeException(), isNull);
            // Every component's guidance is on screen, not silently
            // truncated to a bare "not found".
            final texts = tester
                .widgetList<Text>(find.byType(Text))
                .map((t) => t.data ?? '')
                .join('\n');
            for (final component in RiscvToolchainComponent.values) {
              expect(
                texts,
                contains(
                  RiscvToolchainReportView.guidance(
                    L10N.of(
                      tester.element(find.byType(RiscvToolchainReportView)),
                    ),
                    component,
                    platform,
                  ),
                ),
                reason: '${component.wireName} guidance missing',
              );
            }
          },
        );
      }
    }

    testWidgets('renders at a narrow width without overflowing', (
      tester,
    ) async {
      // The CJK labels run long; the header row is a Wrap for exactly this
      // reason.
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: _reportWith(complete: false),
            platform: RiscvHostPlatform.windows,
          ),
          locale: const Locale('ja'),
          width: 320,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('content', () {
    testWidgets('a complete toolchain says so and shows versions', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: _reportWith(complete: true),
            platform: RiscvHostPlatform.linux,
          ),
          locale: const Locale('en'),
        ),
      );
      expect(find.text('Every component was found.'), findsOneWidget);
      expect(find.text('1.2.3'), findsNWidgets(4));
      // No guidance is rendered when nothing is missing.
      expect(find.textContaining('was not found'), findsNothing);
    });

    testWidgets('an incomplete toolchain names what is missing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: _reportWith(complete: false),
            platform: RiscvHostPlatform.linux,
          ),
          locale: const Locale('en'),
        ),
      );
      expect(find.textContaining('Not found:'), findsOneWidget);
      expect(find.textContaining('RISC-V GNU cross-compiler'), findsWidgets);
    });

    testWidgets('the no-bundling posture is stated on the panel', (
      tester,
    ) async {
      // We detect and guide; we never bundle and never auto-install. Saying so where the user is looking at a
      // missing dependency is the point.
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: _reportWith(complete: false),
            platform: RiscvHostPlatform.macos,
          ),
          locale: const Locale('en'),
        ),
      );
      expect(
        find.textContaining('never bundles them'),
        findsOneWidget,
      );
    });

    testWidgets('an empty report renders the demo-mode note instead', (
      tester,
    ) async {
      // Demo mode probes nothing at all — deliberately skipped, not
      // probed-and-tolerated.
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: RiscvToolchainReport(
              components: const <RiscvComponentReport>[],
            ),
            platform: RiscvHostPlatform.linux,
          ),
          locale: const Locale('en'),
        ),
      );
      expect(find.textContaining('Demo mode'), findsOneWidget);
      expect(find.textContaining('none is probed'), findsOneWidget);
    });

    testWidgets('optional components are marked optional', (tester) async {
      await tester.pumpWidget(
        _host(
          RiscvToolchainReportView(
            report: _reportWith(complete: false),
            platform: RiscvHostPlatform.linux,
          ),
          locale: const Locale('en'),
        ),
      );
      expect(find.textContaining('riscof_passthrough'), findsWidgets);
      expect(find.textContaining('riscv-formal driver'), findsWidgets);
    });
  });

  group('the localized guidance matrix is complete', () {
    testWidgets('every component × platform resolves in every locale', (
      tester,
    ) async {
      for (final locale in _locales) {
        await tester.pumpWidget(
          _host(
            RiscvToolchainReportView(
              report: _reportWith(complete: false),
              platform: RiscvHostPlatform.linux,
            ),
            locale: locale,
          ),
        );
        final l10n = L10N.of(
          tester.element(find.byType(RiscvToolchainReportView)),
        );
        for (final platform in RiscvHostPlatform.values) {
          for (final component in RiscvToolchainComponent.values) {
            final guidance = RiscvToolchainReportView.guidance(
              l10n,
              component,
              platform,
            );
            expect(
              guidance.trim(),
              isNotEmpty,
              reason:
                  '${locale.toLanguageTag()} / ${platform.wireName} / '
                  '${component.wireName}',
            );
            expect(guidance, isNot(contains('...')));
          }
          for (final component in RiscvToolchainComponent.values) {
            expect(
              RiscvToolchainReportView.componentLabel(l10n, component).trim(),
              isNotEmpty,
            );
          }
        }
      }
    });

    testWidgets('the Windows reference-model copy says WSL2 in every locale', (
      tester,
    ) async {
      // "WSL2" is a product name and is not translated, so it is a stable
      // assertion across all five — and it is the single most important
      // sentence in the matrix, because the alternative is spawning a
      // command that cannot work.
      for (final locale in _locales) {
        await tester.pumpWidget(
          _host(
            RiscvToolchainReportView(
              report: _reportWith(complete: false),
              platform: RiscvHostPlatform.windows,
            ),
            locale: locale,
          ),
        );
        final l10n = L10N.of(
          tester.element(find.byType(RiscvToolchainReportView)),
        );
        expect(
          RiscvToolchainReportView.guidance(
            l10n,
            RiscvToolchainComponent.referenceModel,
            RiscvHostPlatform.windows,
          ),
          contains('WSL2'),
          reason: locale.toLanguageTag(),
        );
      }
    });
  });
}
