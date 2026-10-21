// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// What a screen reader user hears in File > Import Formal Project…, and that
// opening, filling and closing it never serializes a semantics node the
// desktop bridge would reject.
//
// The transcript under `goldens/` is what the focus walk records, in text and
// independent of the renderer. Rewrite it with
// `flutter test --update-goldens test/accessibility/import_formal_project_focus_walk_test.dart`
// and read the diff before committing it.

import 'package:crux_a11y/crux_a11y_testing.dart';
import 'package:crux_ide_layout/crux_ide_layout.dart' show CruxDesktopTokens;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/features/formal_import/widgets/import_formal_project_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

const String _job = '''
[tasks]
prove
cover
''';

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
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
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open'),
              onPressed: () => showImportFormalProjectDialog(
                context,
                onImport: (_) async => null,
                pickJobFile: () async => '/designs/hs/top.sby',
                pickProjectFile: (_) async => null,
                readJobFile: (_) => SbyScript.parse(_job),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
}

void main() {
  SemanticsOrphanTestBinding.ensureInitialized();

  testWidgets(
    'the dialog is one named Tab stop per control, in order',
    (tester) async {
      final handle = tester.ensureSemantics();
      tester.view
        ..physicalSize = const Size(1400, 1000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
      await tester.pumpAndSettle();

      final walk = await walkFocus(tester);
      expectCleanFocusWalk(walk, context: 'File > Import Formal Project');
      expectFocusWalkGolden(
        walk,
        'test/accessibility/goldens/import_formal_project.txt',
      );
      handle.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('opening, filling and closing it serializes no orphan node', (
    tester,
  ) async {
    SemanticsOrphanGuard.instance.reset();
    final handle = tester.ensureSemantics();
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cover'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDialogConfirm')));
    await tester.pumpAndSettle();
    handle.dispose();
    SemanticsOrphanGuard.instance.check(context: 'Import Formal Project');
    expect(SemanticsOrphanGuard.instance.updates, greaterThan(1));
  });
}
