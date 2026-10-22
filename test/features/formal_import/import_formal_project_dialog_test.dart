// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simcrux/domain/models/sby_script.dart';
import 'package:simcrux/features/formal_import/import_formal_project_flow.dart';
import 'package:simcrux/features/formal_import/widgets/import_formal_project_dialog.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

import '../../support/recording_telemetry_service.dart';

// File > Import Formal Project…: a workflow dialog on the Crux Desktop
// components. The pickers and the reader are injected, so nothing here opens
// a platform chooser.

const String _job = '''
[tasks]
prove
prove_bug prove
cover

[options]
prove: mode prove
cover: mode cover

[engines]
smtbmc

[script]
read -formal top.sv
prep -top top
''';

Widget _app(Widget Function(BuildContext) opener) => MaterialApp(
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
  home: Scaffold(body: Builder(builder: opener)),
);

void main() {
  late List<ImportFormalProjectRequest> requests;
  String? failure;

  setUp(() {
    requests = <ImportFormalProjectRequest>[];
    failure = null;
  });

  Future<void> open(
    WidgetTester tester, {
    Locale? locale,
    String jobFile = '/designs/hs/top.sby',
    List<String>? read,
  }) async {
    await tester.pumpWidget(
      _app(
        (context) => Center(
          child: ElevatedButton(
            key: const Key('open'),
            onPressed: () => showImportFormalProjectDialog(
              context,
              onImport: (request) async {
                requests.add(request);
                return failure;
              },
              pickJobFile: () async => jobFile,
              pickProjectFile: (suggested) async => '/designs/hs/project.yaml',
              readJobFile: (path) {
                read?.add(path);
                return SbyScript.parse(_job);
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
  }

  L10N l10nOf(WidgetTester tester) => L10N.of(
    tester.element(find.byKey(const ValueKey('importFormalProjectDialog'))),
  );

  testWidgets('Import stays disabled until a job file is chosen', (
    tester,
  ) async {
    await open(tester);
    final import = tester.widget<FilledButton>(
      find.descendant(
        of: find.byKey(const ValueKey('importFormalImport')),
        matching: find.byType(FilledButton),
      ),
    );
    expect(import.onPressed, isNull);
    expect(find.text(l10nOf(tester).importFormalJobFileNone), findsOneWidget);
  });

  testWidgets('choosing a job file lists its tasks, all ticked, and suggests '
      'simcrux.yaml beside it; Import with every task asks for all', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    for (final task in ['prove', 'prove_bug', 'cover']) {
      expect(find.byKey(ValueKey('importFormalTask-$task')), findsOneWidget);
    }
    expect(find.text('/designs/hs/simcrux.yaml'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('importFormalImport')));
    await tester.pumpAndSettle();
    expect(requests.single.sbyPath, '/designs/hs/top.sby');
    expect(requests.single.tasks, isEmpty, reason: 'every task');
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsNothing,
    );
  });

  // These run on every host, so a Windows-only separator bug cannot hide
  // behind the weekly Windows CI.
  group('suggestedProjectPath', () {
    test('a POSIX path stays POSIX on any host', () {
      expect(
        suggestedProjectPath('/designs/hs/top.sby'),
        '/designs/hs/simcrux.yaml',
      );
    });

    test('a POSIX path may hold a backslash in a directory name', () {
      expect(
        suggestedProjectPath(r'/work/a\b/top.sby'),
        r'/work/a\b/simcrux.yaml',
      );
    });

    test('a Windows path stays Windows on any host', () {
      expect(
        suggestedProjectPath(r'C:\designs\hs\top.sby'),
        r'C:\designs\hs\simcrux.yaml',
      );
    });

    test('a Windows path with forward slashes is written with backslashes', () {
      expect(
        suggestedProjectPath('C:/designs/hs/top.sby'),
        r'C:\designs\hs\simcrux.yaml',
      );
    });

    test('a UNC path stays UNC', () {
      expect(
        suggestedProjectPath(r'\\server\share\hs\top.sby'),
        r'\\server\share\hs\simcrux.yaml',
      );
    });

    test('a file at the root of a drive', () {
      expect(suggestedProjectPath(r'C:\top.sby'), r'C:\simcrux.yaml');
    });
  });

  testWidgets('a Windows job file suggests a project file with one separator '
      'style', (tester) async {
    await open(tester, jobFile: r'C:\designs\hs\top.sby');
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    expect(find.text(r'C:\designs\hs\top.sby'), findsOneWidget);
    expect(find.text(r'C:\designs\hs\simcrux.yaml'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('importFormalImport')));
    await tester.pumpAndSettle();
    expect(requests.single.outputPath, r'C:\designs\hs\simcrux.yaml');
  });

  testWidgets('unticking a task imports the subset, to the chosen file', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prove_bug'));
    await tester.tap(
      find.byKey(const ValueKey('importFormalChooseProjectFile')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importFormalImport')));
    await tester.pumpAndSettle();
    expect(requests.single.tasks, ['prove', 'cover']);
    expect(requests.single.outputPath, '/designs/hs/project.yaml');
  });

  testWidgets('an .eqy file is one test: no tasks, the EQY note, Import asks '
      'for the file', (tester) async {
    final read = <String>[];
    await open(tester, jobFile: '/designs/alu/alu_pass.eqy', read: read);
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    final l10n = l10nOf(tester);
    expect(read, isEmpty, reason: 'an .eqy file is not read as a .sby');
    expect(find.text(l10n.importFormalEqyHeading), findsOneWidget);
    expect(find.text(l10n.importFormalEqyOneTest), findsOneWidget);
    expect(find.text(l10n.importFormalTasksHeading), findsNothing);
    await tester.tap(find.byKey(const ValueKey('importFormalImport')));
    await tester.pumpAndSettle();
    expect(requests.single.sbyPath, '/designs/alu/alu_pass.eqy');
    expect(requests.single.isEqy, isTrue);
    expect(requests.single.tasks, isEmpty);
  });

  testWidgets('a failed import stays open and says why', (tester) async {
    failure = 'Import failed: no job file';
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importFormalImport')));
    await tester.pumpAndSettle();
    expect(find.text('Import failed: no job file'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsOneWidget,
    );
  });

  testWidgets('Escape on a clean form closes it; on a dirty one it asks '
      'first', (tester) async {
    await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirmDialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirmDialogCancel')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsOneWidget,
      reason: 'Keep editing returns to the form',
    );
    await tester.tap(find.byKey(const ValueKey('importFormalCancel')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirmDialogConfirm')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsNothing,
    );
    expect(requests, isEmpty);
  });

  testWidgets('a second open while one is up is swallowed by the guard', (
    tester,
  ) async {
    await open(tester);
    final context = tester.element(find.byType(Scaffold));
    // The menu item, pressed again with the dialog up.
    final second = showImportFormalProjectDialog(
      context,
      onImport: (_) async => null,
      pickJobFile: () async => null,
      pickProjectFile: (_) async => null,
      readJobFile: (_) => const SbyScript(),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('importFormalProjectDialog')),
      findsOneWidget,
    );
    await second;
  });

  for (final locale in const [
    Locale('zh', 'CN'),
    Locale('zh'),
    Locale('ja'),
    Locale('ko'),
  ]) {
    testWidgets('${locale.toLanguageTag()}: the dialog renders without '
        'overflow', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(tester, locale: locale);
      await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  group('the flow', () {
    late Directory tmp;
    late RecordingTelemetryService telemetry;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tmp = Directory.systemTemp.createTempSync('import_formal_flow_');
      telemetry = RecordingTelemetryService();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    testWidgets('an import writes the file, records project.opened(formal) '
        'and formal.import.completed, and opens a tab', (tester) async {
      final sby = File(p.join(tmp.path, 'top.sby'))..writeAsStringSync(_job);
      final out = p.join(tmp.path, 'simcrux.yaml');
      final written = <String, String>{};
      final container = ProviderContainer(
        overrides: [telemetryServiceProvider.overrideWithValue(telemetry)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            (context) => ElevatedButton(
              key: const Key('open'),
              onPressed: () => runImportFormalProject(
                context,
                container,
                write: (path, contents) async => written[path] = contents,
                pickJobFile: () async => sby.path,
                pickProjectFile: (_) async => out,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('importFormalImport')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(written.keys, [out]);
      expect(written[out], contains('task: prove_bug'));
      expect(
        telemetry.named('project.opened').single.properties,
        <String, Object?>{'source': 'formal'},
      );
      expect(
        telemetry.named('formal.import.completed').single.properties,
        <String, Object?>{'kind': 'sby', 'tasks': 3},
      );
      final tabs = container.read(workspaceProvider).value?.tabs ?? const [];
      expect(tabs.map((t) => t.payload.configPath), contains(out));
    });

    testWidgets('an .eqy import writes one eqy test and records kind eqy', (
      tester,
    ) async {
      final eqy = File(p.join(tmp.path, 'alu.eqy'))
        ..writeAsStringSync(
          '[gold]\nread_verilog alu.v\n[gate]\nread_verilog gate.v\n'
          '[strategy sby]\nuse sby\n',
        );
      final out = p.join(tmp.path, 'simcrux.yaml');
      final written = <String, String>{};
      final container = ProviderContainer(
        overrides: [telemetryServiceProvider.overrideWithValue(telemetry)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: _app(
            (context) => ElevatedButton(
              key: const Key('open'),
              onPressed: () => runImportFormalProject(
                context,
                container,
                write: (path, contents) async => written[path] = contents,
                pickJobFile: () async => eqy.path,
                pickProjectFile: (_) async => out,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('importFormalChooseJobFile')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('importFormalImport')));
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pumpAndSettle();

      expect(written[out], contains('simulator: eqy'));
      expect(written[out], contains('eqy_file: alu.eqy'));
      expect(
        telemetry.named('formal.import.completed').single.properties,
        <String, Object?>{'kind': 'eqy', 'tasks': 1},
      );
    });
  });
}
