// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/enums/riscv_host_platform.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/domain/models/formal_toolchain_report.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/settings/widgets/settings_formal_tools_section.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/formal/formal_toolchain_probe.dart';

// Settings > Engines > Formal tools: Check formal tools runs the probe from
// the sby path set above it and lists what it found, in words.

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<List<String?>> pump(
    WidgetTester tester, {
    required Map<String, FormalProbeRun> answers,
    AppSettings settings = const AppSettings(),
    RiscvHostPlatform platform = RiscvHostPlatform.macos,
    Locale locale = const Locale('en'),
  }) async {
    final sbyPaths = <String?>[];
    final probe = _RecordingProbe(
      sbyPaths,
      runner: (binary, args) async => answers['$binary ${args.join(' ')}'],
      platform: platform,
    );
    final container = ProviderContainer(
      overrides: [formalToolchainProbeProvider.overrideWithValue(probe)],
    );
    addTearDown(container.dispose);
    await container.read(appSettingsProvider.future);
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
          home: Scaffold(
            body: SingleChildScrollView(
              child: SettingsFormalToolsSection(settings: settings),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return sbyPaths;
  }

  L10N l10nOf(WidgetTester tester) =>
      L10N.of(tester.element(find.byType(Scaffold)));

  testWidgets('the check lists every tool in words, with the Verific fact '
      'and the platform advice', (tester) async {
    await pump(
      tester,
      answers: {
        'sby --version': (exitCode: 0, lines: ['SBY v0.70']),
        'yosys -V': (exitCode: 0, lines: ['Yosys 0.70']),
        'yosys -q -p verific -cfg': (exitCode: 1, lines: ['ERROR']),
      },
    );
    final l10n = l10nOf(tester);
    expect(find.text(l10n.settingsFormalToolsCheck), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('formalToolsCheck')));
    await tester.pumpAndSettle();

    expect(
      find.text(l10n.settingsFormalToolsFoundVersion('sby', 'SBY v0.70')),
      findsOneWidget,
    );
    expect(
      find.text(
        l10n.settingsFormalToolsYosysWithoutVerific('yosys', 'Yosys 0.70'),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.settingsFormalToolsMissing('eqy')), findsOneWidget);
    expect(find.text(l10n.settingsFormalToolsMissing('z3')), findsOneWidget);
    expect(find.text(l10n.settingsFormalToolsGuidanceMacos), findsOneWidget);
  });

  testWidgets('the probe starts from the sby path set above it', (
    tester,
  ) async {
    final paths = await pump(
      tester,
      answers: const {},
      settings: const AppSettings(
        simulatorBinaryOverrides: {'sby': '/opt/oss-cad-suite/bin/sby'},
      ),
    );
    await tester.tap(find.byKey(const ValueKey('formalToolsCheck')));
    await tester.pumpAndSettle();
    expect(paths, ['/opt/oss-cad-suite/bin/sby']);
  });

  testWidgets('with every tool found there is no advice', (tester) async {
    await pump(
      tester,
      answers: _everyToolAnswers(),
      platform: RiscvHostPlatform.linux,
    );
    await tester.tap(find.byKey(const ValueKey('formalToolsCheck')));
    await tester.pumpAndSettle();
    final l10n = l10nOf(tester);
    expect(find.text(l10n.settingsFormalToolsGuidanceLinux), findsNothing);
    expect(find.text(l10n.settingsFormalToolsMissing('sby')), findsNothing);
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: the report renders without '
        'overflow', (tester) async {
      await pump(
        tester,
        answers: const {},
        platform: RiscvHostPlatform.windows,
        locale: locale,
      );
      await tester.tap(find.byKey(const ValueKey('formalToolsCheck')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final l10n = l10nOf(tester);
      expect(
        find.text(l10n.settingsFormalToolsGuidanceWindows),
        findsOneWidget,
      );
    });
  }
}

Map<String, FormalProbeRun> _everyToolAnswers() => {
  'sby --version': (exitCode: 0, lines: ['SBY v0.70']),
  'eqy --version': (exitCode: 0, lines: ['EQY v0.70']),
  'yosys -V': (exitCode: 0, lines: ['Yosys 0.70']),
  'yosys -q -p verific -cfg': (exitCode: 1, lines: ['ERROR']),
  'yosys -q -m slang -p help read_slang': (exitCode: 0, lines: <String>[]),
  'yices-smt2 --version': (exitCode: 0, lines: ['Yices 2.7.0']),
  'boolector --version': (exitCode: 0, lines: ['3.2.4']),
  'bitwuzla --version': (exitCode: 0, lines: ['0.9.1']),
  'z3 --version': (exitCode: 0, lines: ['Z3 version 4.15.5']),
  'yosys-abc -q version': (exitCode: 0, lines: ['ABC 1.01']),
  'rIC3 --version': (exitCode: 0, lines: ['rIC3 1.5.2']),
};

class _RecordingProbe extends FormalToolchainProbe {
  _RecordingProbe(this.sbyPaths, {super.runner, super.platform});

  final List<String?> sbyPaths;

  @override
  Future<FormalToolchainReport> probe({String? sbyPath, String? eqyPath}) {
    sbyPaths.add(sbyPath);
    return super.probe(sbyPath: sbyPath, eqyPath: eqyPath);
  }
}
