// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/interfaces/trend_store.dart';
import 'package:simcrux/domain/models/trend_schema_info.dart';
import 'package:simcrux/domain/models/trend_store_corruption_notice.dart';

/// No-op web fallback for [SqlTrendStore].
///
/// Web dashboards are backed by the in-memory store only —
/// the regression-runner role lives on desktop, and the web role
/// (read-only static export, hosted dashboard) consumes a pre-built
/// JSON bundle rather than a live SQLite database.
///
/// This stub satisfies the conditional export so widgets that read
/// the trend store unconditionally still compile for the web build.
/// Every entry point either succeeds with empty data or throws an
/// [UnsupportedError] for paths that don't have a meaningful no-op.
class SqlTrendStore extends TrendStore {
  /// Private constructor — callers go through [open].
  SqlTrendStore._();

  /// Always false on web: there is no database to skew, migrate or back up,
  /// so no open here can fail permanently. API parity with the io half — see
  /// its doc comment for what this is for.
  static bool isPermanentOpenFault(Object error) => false;

  /// Returns a no-op store on web. The `path` argument is accepted
  /// for source-level parity with the io implementation but ignored.
  ///
  /// [onCorruption] is likewise accepted and never called: there is no file
  /// here to be damaged. The parameter takes the web-safe
  /// [TrendStoreCorruptionNotice] rather than `crux_sqlite`'s exception
  /// precisely so this stub can declare the same signature — the package
  /// reaches `dart:io` through `sqflite_common_ffi` and cannot be named here.
  static Future<SqlTrendStore> open({
    String? path,
    bool reconcile = true,
    void Function(TrendStoreCorruptionNotice notice)? onCorruption,
  }) async {
    return SqlTrendStore._();
  }

  /// No-op: the underlying database does not exist on web.
  Future<void> close() async {}

  /// API parity with the io implementation. There is no file on web, so this
  /// answers the sqflite in-memory sentinel rather than a path that does not
  /// exist.
  String get path => ':memory:';

  /// Always true so the caller's `isOpen` guard short-circuits.
  bool get isOpen => true;

  @override
  Future<void> recordTrendPoint(TrendPoint point) async {
    // Silently dropped on web — see class docs.
  }

  /// API parity with the io implementation; no-op on web.
  Future<void> recordRun({
    required String runId,
    required DateTime startedAt,
    DateTime? finishedAt,
    String configHash = '',
    String triggerKind = 'manual',
    int totalTests = 0,
    int passed = 0,
    int failed = 0,
    int errored = 0,
    int timedOut = 0,
    int skipped = 0,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {}

  @override
  Stream<TrendPoint> recentTrend(String testId, {int limit = 10}) async* {
    // Web: no historical data; the in-memory store covers the
    // active session.
  }

  @override
  Stream<TrendDelta> recentDeltas({int limit = 10}) async* {
    // Web: same as recentTrend — empty stream.
  }

  @override
  Future<Map<String, List<TrendPoint>>> recentTrendsFor(
    Iterable<String> testIds, {
    int limit = 10,
  }) async => const <String, List<TrendPoint>>{};

  @override
  Future<List<String>> distinctTestIds({int runWindow = 10}) async =>
      const <String>[];

  /// Always 0 on web.
  Future<int> resultRowCount() async => 0;

  /// Always 0 on web.
  Future<int> runRowCount() async => 0;

  /// Always 0 on web.
  Future<int> schemaVersion() async => 0;

  /// Always [TrendSchemaInfo.absent] on web — there is no database to have
  /// recorded anything, which is exactly what "absent" means. API parity with
  /// the io implementation so the diagnostics provider compiles on both.
  ///
  /// The mapping from `crux_sqlite`'s `CruxSchemaHistory` lives on the io side
  /// only: that package reaches `dart:io` through `sqflite_common_ffi`, and it
  /// must not enter the web tree.
  @override
  Future<TrendSchemaInfo> schemaInfo({int ledgerLimit = 5}) async =>
      TrendSchemaInfo.absent;
}
