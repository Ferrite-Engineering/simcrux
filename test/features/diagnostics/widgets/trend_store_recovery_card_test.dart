// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/domain/models/trend_store_corruption_notice.dart';
import 'package:simcrux/features/diagnostics/widgets/trend_store_recovery_card.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/trend_store/trend_store_corruption_provider.dart';

/// The card is the ONLY place a quarantine becomes visible. `renameAside`
/// opens a fresh, empty database over the damaged one, so without this surface
/// a user whose year of history was moved aside sees a working product with an
/// empty chart — indistinguishable from a project that has never been run.
///
/// These tests hold the two things that must be true of it: it says where the
/// bytes went (both when the rename worked and when it did not), and it never
/// claims more than it can deliver.
void main() {
  TrendStoreCorruptionNotice notice({
    String? quarantinedPath = '/db/trends.db.corrupt-20260820T101500Z',
    String? backupPath,
  }) => TrendStoreCorruptionNotice(
    path: '/db/trends.db',
    quarantinedPath: quarantinedPath,
    backupPath: backupPath,
    occurredAt: DateTime.utc(2026, 8, 20, 10, 15),
    causeDescription: 'DatabaseException(file is not a database)',
  );

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    TrendStoreCorruptionNotice? pending,
    Locale locale = const Locale('en'),
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (pending != null) {
      container.read(trendStoreCorruptionProvider.notifier).report(pending);
    }
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
          home: const Scaffold(
            body: SingleChildScrollView(child: TrendStoreRecoveryCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('renders nothing when the store opened cleanly', (tester) async {
    await pump(tester);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('names the quarantined file and offers the rebuild', (
    tester,
  ) async {
    await pump(tester, pending: notice());
    final l10n = L10N.of(tester.element(find.byType(TrendStoreRecoveryCard)));

    expect(find.text(l10n.diagnosticsTrendRecoveryTitle), findsOneWidget);
    expect(
      find.text(
        l10n.diagnosticsTrendRecoveryQuarantined(
          '/db/trends.db',
          '/db/trends.db.corrupt-20260820T101500Z',
        ),
      ),
      findsOneWidget,
      reason: 'the user must be told where their bytes went',
    );
    // The honesty clause: what a rebuild will and will not bring back.
    expect(
      find.text(l10n.diagnosticsTrendRecoveryRebuildExplainer),
      findsOneWidget,
    );
    expect(
      find.text(l10n.diagnosticsTrendRecoveryRebuildAction),
      findsOneWidget,
    );
  });

  testWidgets('says so when the rename itself failed', (tester) async {
    await pump(tester, pending: notice(quarantinedPath: null));
    final l10n = L10N.of(tester.element(find.byType(TrendStoreRecoveryCard)));

    expect(
      find.text(l10n.diagnosticsTrendRecoveryUnmoved('/db/trends.db')),
      findsOneWidget,
    );
    expect(
      find.text(
        l10n.diagnosticsTrendRecoveryQuarantined('/db/trends.db', ''),
      ),
      findsNothing,
    );
  });

  testWidgets('names the pre-upgrade backup only when one exists', (
    tester,
  ) async {
    await pump(tester);
    await pump(
      tester,
      pending: notice(backupPath: '/db/trends.db.pre-v3-20260819T090000Z.bak'),
    );
    final l10n = L10N.of(tester.element(find.byType(TrendStoreRecoveryCard)));

    expect(
      find.text(
        l10n.diagnosticsTrendRecoveryBackup(
          '/db/trends.db.pre-v3-20260819T090000Z.bak',
        ),
      ),
      findsOneWidget,
      reason:
          'a complete database next to the damaged one is the better offer '
          'and must be named, not left for the user to find',
    );
  });

  testWidgets('no backup line when there is no backup', (tester) async {
    await pump(tester, pending: notice());
    expect(find.textContaining('.bak'), findsNothing);
  });

  testWidgets('dismissing clears the notice', (tester) async {
    final container = await pump(tester, pending: notice());
    final l10n = L10N.of(tester.element(find.byType(TrendStoreRecoveryCard)));

    await tester.tap(find.text(l10n.diagnosticsTrendRecoveryDismiss));
    await tester.pumpAndSettle();

    expect(container.read(trendStoreCorruptionProvider), isNull);
    expect(find.text(l10n.diagnosticsTrendRecoveryTitle), findsNothing);
  });

  // Locale sweep — the card is a text-heavy error surface, so an overflow or
  // a missing translation here lands in front of a user already having a bad
  // day.
  for (final locale in L10N.supportedLocales) {
    testWidgets('renders in $locale without overflow', (tester) async {
      await pump(
        tester,
        pending: notice(
          backupPath: '/db/trends.db.pre-v3-20260819T090000Z.bak',
        ),
        locale: locale,
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(TrendStoreRecoveryCard), findsOneWidget);
    });
  }
}
