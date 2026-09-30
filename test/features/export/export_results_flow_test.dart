// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The GUI export path.
//
// Without it the four exporters are reachable only through `--export` and
// `--ci`: `ExporterRegistry` has only CLI consumers, and nine translated
// `export*` ARB keys are referenced by nothing. These tests cover the flow the dialog drives, not the exporters themselves —
// those have their own suites under test/services/export/.

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/export/export_results_flow.dart';
import 'package:simcrux/features/export/widgets/export_format_dialog.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/export/result_exporter.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

import '../../support/recording_telemetry_service.dart';

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore? _store;
  @override
  InMemoryResultStore? build() => _store;
}

InMemoryResultStore _storeWithOneResult() {
  final run = TestRun(
    id: 'run-42',
    startedAt: DateTime.utc(2026, 8, 17),
    testIds: const ['unit/alu'],
  );
  final store = InMemoryResultStore.forRun(run)
    // Resolves synchronously in tests; the future is not needed downstream.
    // ignore: discarded_futures
    ..recordResult(
      TestResult(
        testId: 'unit/alu',
        runId: 'run-42',
        status: TestStatus.pass,
        startedAt: DateTime.utc(2026, 8, 17),
        finishedAt: DateTime.utc(2026, 8, 17, 0, 0, 1),
      ),
    );
  return store;
}

/// Pumps a bare surface holding a button that runs the export flow against
/// [store], and returns the recording telemetry service and the write log.
///
/// The flow reads per-tab providers from the container it is handed, so the
/// test hands it the same container the scope uses — the production caller
/// hands it the active tab's container for the same reason.
Future<
  ({
    List<({String path, String contents})> writes,
    RecordingTelemetryService telemetry,
  })
>
_pumpFlow(
  WidgetTester tester, {
  required InMemoryResultStore? store,
  required Future<String?> Function({
    required String suggestedName,
    required String extension,
  })
  pathPicker,
  ExportFileWriter? fileWriter,
  Locale locale = const Locale('en'),
}) async {
  final writes = <({String path, String contents})>[];
  final telemetry = RecordingTelemetryService();
  final container = ProviderContainer(
    overrides: [
      resultStoreProvider.overrideWith(
        () => _ImmediateResultStoreNotifier(store),
      ),
      telemetryServiceProvider.overrideWithValue(telemetry),
    ],
  );
  addTearDown(container.dispose);

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
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => runExportResultsFlow(
                context: context,
                tabContainer: container,
                pathPicker: pathPicker,
                fileWriter:
                    fileWriter ??
                    (path, contents) async =>
                        writes.add((path: path, contents: contents)),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('go'));
  await tester.pumpAndSettle();
  return (writes: writes, telemetry: telemetry);
}

Future<String?> _picksPath({
  required String suggestedName,
  required String extension,
}) async => '/tmp/$suggestedName';

Future<String?> _cancelsPicker({
  required String suggestedName,
  required String extension,
}) async => null;

void main() {
  testWidgets('with no run recorded it reports exportEmpty and opens nothing', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: null,
      pathPicker: _picksPath,
    );

    final l10n = L10N.of(tester.element(find.text('go')));
    expect(find.text(l10n.exportEmpty), findsOneWidget);
    expect(find.byKey(kExportFormatDialogKey), findsNothing);
    expect(result.writes, isEmpty);
  });

  testWidgets('exports the chosen format and reports the destination', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _picksPath,
    );

    // The dialog opened; take the default (JUnit) and confirm.
    expect(find.byKey(kExportFormatDialogKey), findsOneWidget);
    await tester.tap(find.byKey(kExportFormatDialogExportKey));
    await tester.pumpAndSettle();

    expect(result.writes, hasLength(1));
    final write = result.writes.single;
    expect(write.path, '/tmp/run-42.xml');
    // Encoded by the real JunitExporter through the real registry — a test
    // that asserted only "something was written" would pass with the
    // registry lookup deleted.
    expect(write.contents, contains('<testsuites'));
    // One testcase, split into JUnit's classname/name pair the way the
    // exporter does it — asserting the composite id would pass with the rows
    // list empty, since the id only appears in the header attributes.
    expect(write.contents, contains('tests="1"'));
    expect(write.contents, contains('classname="unit"'));
    expect(write.contents, contains('name="alu"'));

    final l10n = L10N.of(tester.element(find.text('go')));
    expect(find.text(l10n.exportSuccess('/tmp/run-42.xml')), findsOneWidget);
  });

  testWidgets('the format choice reaches the picker and the exporter', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _picksPath,
    );

    await tester.tap(find.byKey(Key('exportFormat_${ExportFormat.csv.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kExportFormatDialogExportKey));
    await tester.pumpAndSettle();

    // The extension comes from ExportFormat.extension, which is what that
    // field's doc comment says it exists for.
    expect(result.writes.single.path, '/tmp/run-42.csv');
    expect(result.writes.single.contents, isNot(contains('<testsuites')));
  });

  testWidgets('cancelling the save panel writes nothing and records nothing', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _cancelsPicker,
    );

    await tester.tap(find.byKey(kExportFormatDialogExportKey));
    await tester.pumpAndSettle();

    expect(result.writes, isEmpty);
    expect(result.telemetry.named('export.completed'), isEmpty);
  });

  testWidgets('a failed write reports exportFailure and records nothing', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _picksPath,
      fileWriter: (path, contents) async =>
          throw StateError('read-only volume'),
    );

    await tester.tap(find.byKey(kExportFormatDialogExportKey));
    await tester.pumpAndSettle();

    final l10n = L10N.of(tester.element(find.text('go')));
    expect(
      find.textContaining(l10n.exportFailure('').split('{').first.trim()),
      findsOneWidget,
    );
    // After the write, never before: a failed export must not be counted as
    // one. Same rule CiRunner._writeExports follows for the same event.
    expect(result.telemetry.named('export.completed'), isEmpty);
  });

  testWidgets('a successful export records export.completed with the format', (
    tester,
  ) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _picksPath,
    );

    await tester.tap(find.byKey(Key('exportFormat_${ExportFormat.json.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kExportFormatDialogExportKey));
    await tester.pumpAndSettle();

    final events = result.telemetry.named('export.completed');
    expect(events, hasLength(1));
    expect(events.single.properties['format'], ExportFormat.json.id);
    // The destination is user data and must never reach the pipeline.
    expect(
      events.single.properties.values,
      isNot(contains('/tmp/run-42.json')),
    );
  });

  testWidgets('cancelling the format dialog exports nothing', (tester) async {
    final result = await _pumpFlow(
      tester,
      store: _storeWithOneResult(),
      pathPicker: _picksPath,
    );

    final l10n = L10N.of(tester.element(find.text('go')));
    await tester.tap(find.text(l10n.exportActionCancel));
    await tester.pumpAndSettle();

    expect(result.writes, isEmpty);
  });

  testWidgets('the dialog renders in all five locales', (tester) async {
    for (final locale in L10N.supportedLocales) {
      await _pumpFlow(
        tester,
        store: _storeWithOneResult(),
        pathPicker: _picksPath,
        locale: locale,
      );
      expect(
        find.byKey(kExportFormatDialogKey),
        findsOneWidget,
        reason: 'locale=${locale.toLanguageTag()}',
      );
      // Every format label resolves — a missing key renders the raw
      // identifier or throws, and neither shows up in a smoke pump.
      final l10n = L10N.of(tester.element(find.byKey(kExportFormatDialogKey)));
      for (final label in [
        l10n.exportFormatJunit,
        l10n.exportFormatJson,
        l10n.exportFormatCsv,
        l10n.exportFormatHtml,
      ]) {
        expect(
          find.text(label),
          findsOneWidget,
          reason: 'locale=${locale.toLanguageTag()} label=$label',
        );
      }
      expect(
        tester.takeException(),
        isNull,
        reason: 'locale=${locale.toLanguageTag()}',
      );
      // Dismiss before the next iteration: pumpWidget reuses the Navigator
      // element, so a left-open route would survive into the next locale and
      // cover the button this helper taps.
      await tester.tap(find.text(l10n.exportActionCancel));
      await tester.pumpAndSettle();
    }
  });
}
