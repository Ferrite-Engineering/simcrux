// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

@TestOn('vm')
library;

import 'dart:io';

import 'package:crux_flow/crux_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/domain/models/flow_config.dart';
import 'package:simcrux/features/flow/flow_actions.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/flow/flow_run_importer.dart';
import 'package:simcrux/services/flow/librelane_path_check.dart';

/// Run Flow Entry and Run Regression refuse a LibreLane entry LibreLane
/// cannot run from before anything is submitted, in a toast in the app's
/// locale that names the path and what to do.
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('ll_toast_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  FlowEntry entryUnder(String parent) {
    final root = p.join(tmp.resolveSymbolicLinksSync(), parent, 'proj');
    Directory(p.join(root, 'librelane')).createSync(recursive: true);
    File(
      p.join(root, 'librelane', 'config.yaml'),
    ).writeAsStringSync('DESIGN_NAME: c\n');
    return FlowEntry(
      name: parent.replaceAll(' ', '_'),
      kind: FlowKind.librelane,
      config: p.join(root, 'librelane', 'config.yaml'),
      projectRoot: root,
    );
  }

  Future<BuildContext> pump(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    return tester.element(find.byType(Scaffold));
  }

  for (final locale in L10N.supportedLocales) {
    testWidgets('a path with a space is refused in a $locale toast that '
        'names it; a path without one is not', (tester) async {
      final ctx = await pump(tester, locale);
      final spaced = const FlowRunImporter().specFor(
        entryUnder('Getting Started'),
      );
      final plain = const FlowRunImporter().specFor(entryUnder('plain'));

      final refused = FlowActions.refuseUnsupportedPaths(ctx, [
        spaced,
        plain,
      ]);
      await tester.pumpAndSettle();

      expect(refused, {spaced.id});
      final refusal = LibreLanePathCheck.forEntry(spaced.flow!)!;
      final text = L10N.of(ctx).flowLibreLanePathSpace(refusal.path);
      expect(find.text(text), findsOneWidget);
      expect(text, contains(refusal.path));
    });
  }

  testWidgets('nothing refused, nothing said', (tester) async {
    final ctx = await pump(tester, const Locale('en'));
    final plain = const FlowRunImporter().specFor(entryUnder('plain'));
    expect(FlowActions.refuseUnsupportedPaths(ctx, [plain]), isEmpty);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
