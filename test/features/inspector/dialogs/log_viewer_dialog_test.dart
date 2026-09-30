// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/models/dashboard_row.dart';
import 'package:simcrux/domain/models/test_result.dart';
import 'package:simcrux/domain/models/test_run.dart';
import 'package:simcrux/features/inspector/dialogs/log_viewer_dialog.dart';
import 'package:simcrux/features/inspector/providers/inspector_log_provider.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/workspace/providers/simcrux_tab_overrides.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/result_store/in_memory_result_store.dart';
import 'package:simcrux/services/result_store/log_buffer_store.dart';
import 'package:simcrux/services/result_store/result_store_provider.dart';

const String _kTestId = 'smoke/pass_basic';

SelectedTest _selection() {
  final result = TestResult(
    runId: 'r1',
    testId: _kTestId,
    status: TestStatus.pass,
    startedAt: DateTime.utc(2026),
    finishedAt: DateTime.utc(2026, 1, 1, 0, 0, 1),
    exitCode: 0,
  );
  return SelectedTest(
    row: DashboardRow(
      result: result,
      suiteName: 'smoke',
      simulatorId: 'icarus',
      testName: 'pass_basic',
    ),
  );
}

Future<void> _pumpDialog(
  WidgetTester tester, {
  List<Override> overrides = const [],
  Locale locale = const Locale('en'),
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: const [
          L10N.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10N.supportedLocales,
        home: Scaffold(body: LogViewerDialog(selection: _selection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

L10N _l10n(WidgetTester tester) =>
    L10N.of(tester.element(find.byType(LogViewerDialog)));

void main() {
  group('LogViewerDialog', () {
    testWidgets('renders the empty state and title when the buffer is empty', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        overrides: [
          fullInspectorLogProvider(
            _kTestId,
          ).overrideWith((_) => const <LogLine>[]),
        ],
      );
      final l10n = _l10n(tester);
      expect(find.text(l10n.logViewerEmpty), findsOneWidget);
      expect(find.text(l10n.logViewerTitle(_kTestId)), findsOneWidget);
      // Copy is disabled with nothing to copy.
      final copyButton = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.copy_outlined),
      );
      expect(copyButton.onPressed, isNull);
      // No matches yet, so both search-step buttons are disabled.
      final prev = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up),
      );
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
      );
      expect(prev.onPressed, isNull);
      expect(next.onPressed, isNull);
    });

    testWidgets(
      'renders buffered lines from a populated LogBuffer and follows appends',
      (tester) async {
        final run = TestRun(
          id: 'r1',
          startedAt: DateTime.utc(2026),
          testIds: const [_kTestId],
        );
        final store = InMemoryResultStore.forRun(run);
        store.logBufferStore.bufferFor(_kTestId)
          ..append(line: 'hello world', fromStderr: false)
          ..append(line: 'TEST PASSED', fromStderr: false);

        await _pumpDialog(
          tester,
          overrides: [
            resultStoreProvider.overrideWith(
              () => _ImmediateResultStoreNotifier(store),
            ),
          ],
        );
        expect(find.text('hello world'), findsOneWidget);
        expect(find.text('TEST PASSED'), findsOneWidget);
        expect(find.text(_l10n(tester).logViewerEmpty), findsNothing);

        // A late append must surface after the 80 ms coalescing window
        // (kLogInvalidationCoalesceWindow) elapses.
        store.logBufferStore
            .bufferFor(_kTestId)
            .append(line: 'late line', fromStderr: false);
        expect(find.text('late line'), findsNothing);
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump();
        expect(find.text('late line'), findsOneWidget);
      },
    );

    testWidgets('search reports the match position and steps through matches', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        overrides: [
          fullInspectorLogProvider(_kTestId).overrideWith(
            (_) => const <LogLine>[
              LogLine(line: 'first error here', fromStderr: false),
              LogLine(line: 'plain line', fromStderr: false),
              LogLine(line: 'second ERROR line', fromStderr: false),
            ],
          ),
        ],
      );
      final l10n = _l10n(tester);
      // The search field is the first TextField in the toolbar; the
      // jump-to-line field is the second.
      await tester.enterText(find.byType(TextField).at(0), 'error');
      await tester.pumpAndSettle();
      expect(find.text(l10n.logViewerMatchPosition(1, 2)), findsOneWidget);

      await tester.tap(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.logViewerMatchPosition(2, 2)), findsOneWidget);

      // Stepping past the last match wraps around to the first.
      await tester.tap(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.logViewerMatchPosition(1, 2)), findsOneWidget);

      await tester.tap(
        find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.logViewerMatchPosition(2, 2)), findsOneWidget);
    });

    testWidgets('colors lines by severity and bolds stderr lines', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        overrides: [
          fullInspectorLogProvider(_kTestId).overrideWith(
            (_) => const <LogLine>[
              LogLine(line: 'ERROR: boom', fromStderr: true),
              LogLine(line: 'WARNING: watch out', fromStderr: false),
              LogLine(line: 'INFO: all good', fromStderr: false),
              LogLine(line: 'plain output', fromStderr: false),
            ],
          ),
        ],
      );
      final theme = Theme.of(tester.element(find.text('ERROR: boom')));

      final errorStyle = tester.widget<Text>(find.text('ERROR: boom')).style!;
      expect(errorStyle.color, theme.colorScheme.error);
      expect(errorStyle.fontWeight, FontWeight.w600);

      final warningStyle = tester
          .widget<Text>(find.text('WARNING: watch out'))
          .style!;
      expect(warningStyle.color, Colors.amber);
      expect(warningStyle.fontWeight, isNot(FontWeight.w600));

      final infoStyle = tester.widget<Text>(find.text('INFO: all good')).style!;
      expect(infoStyle.color, theme.colorScheme.primary);

      final plainStyle = tester.widget<Text>(find.text('plain output')).style!;
      expect(plainStyle.color, theme.textTheme.bodySmall?.color);
      expect(plainStyle.fontWeight, isNot(FontWeight.w600));
    });

    testWidgets('copy button places the full log on the clipboard', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pumpDialog(
        tester,
        overrides: [
          fullInspectorLogProvider(_kTestId).overrideWith(
            (_) => const <LogLine>[
              LogLine(line: 'line one', fromStderr: false),
              LogLine(line: 'line two', fromStderr: true),
            ],
          ),
        ],
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.copy_outlined));
      await tester.pumpAndSettle();

      final setData = calls.where((c) => c.method == 'Clipboard.setData');
      expect(setData, hasLength(1));
      final args = setData.single.arguments as Map<Object?, Object?>;
      expect(args['text'], 'line one\nline two');
    });

    testWidgets('jump-to-line scrolls the list to the requested line', (
      tester,
    ) async {
      await _pumpDialog(
        tester,
        overrides: [
          fullInspectorLogProvider(_kTestId).overrideWith(
            (_) => List<LogLine>.generate(
              200,
              (i) => LogLine(line: 'log line ${i + 1}', fromStderr: false),
            ),
          ),
        ],
      );
      final l10n = _l10n(tester);
      await tester.enterText(find.byType(TextField).at(1), '150');
      await tester.tap(find.text(l10n.logViewerJumpToLineGo));
      await tester.pumpAndSettle();

      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable.first).position;
      // Line 150 sits at (150 - 1) * 18 logical pixels.
      expect(position.pixels, moreOrLessEquals(149 * 18, epsilon: 1));
    });

    testWidgets('show() opens the dialog and Close dismisses it', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            fullInspectorLogProvider(
              _kTestId,
            ).overrideWith((_) => const <LogLine>[]),
          ],
          child: MaterialApp(
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: Scaffold(
              body: Builder(
                builder: (context) => IconButton(
                  icon: const Icon(Icons.open_in_full),
                  onPressed: () => LogViewerDialog.show(context, _selection()),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LogViewerDialog), findsNothing);

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      expect(find.byType(LogViewerDialog), findsOneWidget);

      final l10n = L10N.of(tester.element(find.byType(LogViewerDialog)));
      await tester.tap(find.text(l10n.logViewerClose));
      await tester.pumpAndSettle();
      expect(find.byType(LogViewerDialog), findsNothing);
    });

    testWidgets('locale sweep renders without exceptions', (tester) async {
      for (final locale in const [
        Locale('en'),
        Locale('zh', 'CN'),
        Locale('zh'),
        Locale('ja'),
        Locale('ko'),
      ]) {
        await _pumpDialog(
          tester,
          locale: locale,
          overrides: [
            fullInspectorLogProvider(_kTestId).overrideWith(
              (_) => const <LogLine>[
                LogLine(line: 'ERROR: boom', fromStderr: true),
                LogLine(line: 'plain output', fromStderr: false),
              ],
            ),
          ],
        );
        expect(tester.takeException(), isNull, reason: '$locale');
      }
    });
  });

  // ==========================================================================
  // ROUTE-MOUNTED PER-TAB SCOPE LEAK (crux-shared route_mounted_scope_leak_test)
  // ==========================================================================
  //
  // Every test above pumps the dialog directly under a SINGLE `ProviderScope`,
  // so the dialog reads the very state the test seeded and the defect below is
  // structurally invisible. This group builds the REAL two-container shape: a
  // root container, a per-tab child produced by the same `TabContainerManager`
  // the app uses, the `MaterialApp` (and therefore the Navigator the dialog
  // route is pushed onto) at ROOT, and the launching button inside the tab's
  // `UncontrolledProviderScope`.
  group('LogViewerDialog.show binds the CALLER tab container', () {
    testWidgets("renders the tab's log buffer, not the root's empty one", (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final root = ProviderContainer();
      addTearDown(root.dispose);
      final tabs = crux.TabContainerManager(
        rootContainer: root,
        overridesFactory: simcruxTabOverrides,
      );
      addTearDown(tabs.dispose);
      final tabContainer = tabs.containerFor(crux.TabId.generate());

      // Seed the log buffer in the TAB container only. The root container's
      // `resultStoreProvider` stays null — exactly as in the real app, where
      // a run only ever publishes its store into the tab that started it.
      final store = InMemoryResultStore.forRun(
        TestRun(
          id: 'r1',
          startedAt: DateTime.utc(2026),
          testIds: const [_kTestId],
        ),
      );
      store.logBufferStore.bufferFor(_kTestId)
        ..append(line: 'hello from the tab', fromStderr: false)
        ..append(line: 'TEST PASSED', fromStderr: false);
      tabContainer.read(resultStoreProvider.notifier).publish(store);
      expect(root.read(fullInspectorLogProvider(_kTestId)), isEmpty);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: root,
          child: MaterialApp(
            localizationsDelegates: const [
              L10N.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10N.supportedLocales,
            home: Scaffold(
              body: UncontrolledProviderScope(
                container: tabContainer,
                child: Builder(
                  builder: (context) => TextButton(
                    onPressed: () =>
                        LogViewerDialog.show(context, _selection()),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Mutation-verified: drop the `UncontrolledProviderScope` from
      // `LogViewerDialog.show` and this fails — the viewer renders the
      // "No log output" empty state because the ROOT container has no
      // result store.
      expect(find.text('hello from the tab'), findsOneWidget);
      expect(find.text('TEST PASSED'), findsOneWidget);
      expect(find.text(_l10n(tester).logViewerEmpty), findsNothing);
    });
  });
}

class _ImmediateResultStoreNotifier extends ResultStoreNotifier {
  _ImmediateResultStoreNotifier(this._store);
  final InMemoryResultStore _store;

  @override
  InMemoryResultStore build() => _store;
}
