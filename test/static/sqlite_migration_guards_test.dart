// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// The six CI guards — seven scanners, since G5 has two halves — pointed at
// SimCrux open core.
//
// WHAT THIS IS
// A schema change that destroys data is invisible in review — it is one
// line of SQL that reads as a tidy-up — and invisible at run time, because
// the rows are simply not there any more. The user finds out months later,
// when a chart is missing a series, and nothing brings it back. These six
// guards are what makes that change fail a build instead.
//
// G5b is the one that does not read a schema at all. It reads catch shapes:
// no `catch (e)` and no `on Object catch` may wrap a call that reaches an
// open, because a catch-all there cannot tell a corrupt file from a bug in
// our own migration from an ordinary two-build version skew — and only the
// first of those three is a case where the data is gone.
//
// The scanners themselves live in `crux_sqlite`
// (`package:crux_sqlite/crux_sqlite_guards.dart`) and are proved against
// hand-written violating sources in that package's own tests. This file is
// thin on purpose: it points them at SimCrux's migration list, its `lib/`,
// and its checked-in schema manifest, and it carries the data — the
// manifest path, the delete allowlist, the pinned direct opens — that is
// specific to this repo.
//
// WHY IT IS A TEST AND NOT A WORKFLOW
// This repo already runs `flutter test` in CI and already has a
// `test/static/` tradition. A new workflow would be a new billing surface
// and a new `timeout-minutes` for somebody to forget. Riding an existing
// job costs nothing and cannot be skipped.
//
// WHERE THE RULES ARE WRITTEN DOWN
// `crux-shared/packages/crux_sqlite/README.md` ("The migration rules"). Every
// guard's failure message points there. **Deleting or loosening a guard is
// never the fix**: if a rule is wrong, it is wrong in a way that can be
// stated, and the statement belongs in that README before the code that
// enforces it changes.
//
// SIMCRUX'S ONE DATABASE, TWO PATHS
// `trends.db` — regression history, PRECIOUS, unreconstructible from
// anything else on disk. Open core opens it at `<appSupport>/trends.db`;
// the Pro overlay opens the *same schema* at
// `<projectPath>/.simcrux/trends.db` through the same `SqlTrendStore`. One
// migration list, one manifest, two files on a user's disk. SimCrux Pro's
// own `test/static/sqlite_migration_guards_test.dart` runs G3/G4/G5 over
// the Pro `lib/`.

import 'dart:io';

import 'package:crux_sqlite/crux_sqlite.dart';
import 'package:crux_sqlite/crux_sqlite_guards.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/build_info.dart';
import 'package:simcrux/services/trend_store/sql_migrations.dart';

/// Repo root, derived from this file's location so the test is
/// invocation-directory independent, with a walk-up fallback because
/// `Platform.script` points at the test runner under `flutter test`.
String _root() {
  final fromScript = p.normalize(
    p.join(p.dirname(Platform.script.toFilePath()), '..', '..'),
  );
  if (Directory(p.join(fromScript, 'lib')).existsSync()) return fromScript;
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(
          p.join(dir.path, 'lib', 'services', 'trend_store'),
        ).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) fail('could not locate the simcrux repo root');
    dir = parent;
  }
}

/// The store's real runner, built from the list production uses.
CruxMigrationRunner _runner() => CruxMigrationRunner(
  storeName: 'SimCrux trend store',
  migrations: simcruxTrendStoreMigrations,
  identity: CruxAppIdentity(
    product: SimCruxBuildInfo.productName,
    appVersion: SimCruxBuildInfo.productVersion,
  ),
);

/// Every migration list this repo declares, and therefore every store the
/// per-store guards must be pointed at. `cruxAuditMigrationListRegistry`
/// fails if `lib/` grows one that is not here — which is what stops a new
/// database from arriving unguarded.
const Set<String> _registeredMigrationLists = {'simcruxTrendStoreMigrations'};

/// **The delete allowlist: empty, and it should stay that way.**
///
/// SimCrux has one database and its contents are a regression history —
/// unreconstructible from anything else on disk. There is no derivable
/// store here, so there is nothing an entry could legitimately name.
const List<CruxDeleteAllowlistEntry> _deleteAllowlist = [];

/// Files that open the database directly instead of through
/// `CruxSqliteOpenPolicy.open`.
///
/// **Empty, and it should stay that way.** `sql_trend_store_io.dart` was
/// pinned here while `SqlTrendStore.open` assembled the policy's options and
/// called `databaseFactory.openDatabase` itself: conformant options, but
/// without the policy's path absolutisation or its corruption recovery. It
/// now opens through `CruxSqliteOpenPolicy.open`, so the pin is gone.
/// SimCrux now has exactly one open path for both of its `trends.db` files.
///
/// Adding an entry back is not a fix for a failing guard — it is a decision
/// to run a second open path, and it needs the reason written next to it.
final Set<String> _pinnedDirectOpens = <String>{};

/// **The G5b allowlist: empty, and it cannot be otherwise here.**
///
/// A catch-all around an open swallows genuine corruption, a migration bug of
/// ours, and a version skew between two builds, all as one object. An entry
/// could only ever permit that for a store whose contents a fresh run
/// regenerates — it references the store's own `CruxDbRecovery` and is
/// honoured only when that constant is `recreate` — and SimCrux has no such
/// store. `trends.db` is a regression history: the one thing in the app that
/// cannot be rebuilt from anything else on disk.
const List<CruxOpenCatchAllowlistEntry> _openCatchAllowlist = [];

void main() {
  setUpAll(ensureCruxSqliteFfiInitialized);

  late final root = _root();
  late final runner = _runner();
  late final libSources = cruxDartSourcesIn(
    Directory(p.join(root, 'lib')),
    relativeTo: root,
  );
  late final testSources = cruxDartSourcesIn(
    Directory(p.join(root, 'test')),
    relativeTo: root,
  );

  group('SQLite migration guards — SimCrux open core', () {
    test('the scan is not vacuous', () {
      // Without this, every guard below could be green because it found
      // nothing to look at rather than because lib/ is clean.
      expect(libSources, isNotEmpty);
      expect(
        libSources.map((s) => s.path),
        contains(
          p.join('lib', 'services', 'trend_store', 'sql_migrations.dart'),
        ),
      );
      expect(testSources, isNotEmpty);
      expect(runner.latestVersion, greaterThanOrEqualTo(4));
    });

    test('G1 — no shipped migration was edited', () async {
      final manifest = CruxSchemaManifest.readFile(
        p.join(
          root,
          'test',
          'static',
          'sqlite_schema_manifests',
          'simcrux_trend_store.fingerprints',
        ),
        storeName: runner.storeName,
      );
      final report = cruxAuditSchemaFingerprints(
        runner: runner,
        snapshots: await cruxSchemaSnapshotsOf(runner),
        manifest: manifest,
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G2 — every version is additive over the one before it', () async {
      final report = cruxAuditAdditiveOnly(
        runner: runner,
        snapshots: await cruxSchemaSnapshotsOf(runner),
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G3 — no unwaived destructive DDL anywhere in lib/', () {
      final report = cruxAuditDestructiveDdl(
        sources: libSources,
        subject: 'simcrux/lib',
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G4 — nothing deletes a database file', () {
      final report = cruxAuditDatabaseDeletes(
        sources: libSources,
        allowlist: _deleteAllowlist,
        subject: 'simcrux/lib',
      );
      expect(report.isClean, isTrue, reason: report.describe());
      expect(
        report.observations,
        isEmpty,
        reason:
            'SimCrux has no derivable database, so there is no sanctioned '
            'delete site here and there should never be one',
      );
    });

    test('G5 — every open conforms, and there are no bypasses left', () {
      final report = cruxAuditOpenOptions(
        sources: libSources,
        subject: 'simcrux/lib',
        expectedDirectOpenFiles: _pinnedDirectOpens,
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G5b — the open-reaching call sites are the ones we think', () {
      // The vacuity pin for the guard below. G5b derives what "reaches an
      // open" from the sources rather than from a hand-list, so a store
      // written next week is covered without anybody remembering it — but
      // the flip side is that a derivation which quietly stopped finding
      // anything would leave the guard green forever. This is where that
      // shows up: SimCrux has exactly one open path, and it is
      // `SqlTrendStore.open`, which is an open-reaching call because its
      // body goes through `CruxSqliteOpenPolicy.open` and for no other
      // reason.
      expect(cruxOpenReachingEntryPoints(sources: libSources), {
        'SqlTrendStore.open',
      });
    });

    test('G5b — no catch-all wraps a call that reaches an open', () {
      final report = cruxAuditOpenCatchShapes(
        sources: libSources,
        subject: 'simcrux/lib',
        // Empty, and it should stay empty. An entry is honoured only when it
        // references a store whose own `CruxDbRecovery` is `recreate`, and
        // SimCrux has no derivable store: `trends.db` is a regression
        // history that nothing on disk rebuilds. So there is nothing here an
        // entry could legitimately name, and the guard would refuse one that
        // named `trends.db` anyway.
        // ignore: avoid_redundant_argument_values
        allowlist: _openCatchAllowlist,
      );
      expect(report.isClean, isTrue, reason: report.describe());
      expect(
        report.observations,
        isEmpty,
        reason:
            'an observation here means a catch-all at an open is being '
            'tolerated by allowlist, which for a precious store is not '
            'something the guard can be made to accept',
      );
    });

    test('G6 — the trend store has a data-preserving suite', () {
      final report = cruxAuditFixtureSuites(
        testSources: testSources,
        storeMarkers: const {
          'SimCrux trend store': [
            'simcruxTrendStoreMigrations',
            'SqlTrendStore',
          ],
        },
        subject: 'simcrux/test',
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G6 — every version has a fixture', () {
      // `sql_migrations_data_preserving_test.dart` registers its fixtures as
      // a comprehension over 1..latestVersion, so this set mirrors it. That
      // makes the check complete by construction today and live the moment
      // the map is written out per version — which is what happens as soon
      // as two versions need different seed data. The half of G6 doing real
      // work right now is the suite-exists check above.
      final report = cruxAuditFixtureCoverage(
        runner: runner,
        fixtureVersions: {
          for (var v = 1; v <= runner.latestVersion; v++) v,
        },
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });

    test('G6 — no migration list in lib/ is unguarded', () {
      final report = cruxAuditMigrationListRegistry(
        sources: libSources,
        registeredListNames: _registeredMigrationLists,
        subject: 'simcrux/lib',
      );
      expect(report.isClean, isTrue, reason: report.describe());
    });
  });
}
