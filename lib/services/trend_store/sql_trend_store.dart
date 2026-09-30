// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Public entry point for the SQLite trend store.
///
/// Re-exports the platform-appropriate implementation:
///
/// - `sql_trend_store_io.dart` — desktop / mobile / VM. Backed by
///   `sqflite_common_ffi`. Full read/write surface, persistent
///   storage at the caller-supplied path.
/// - `sql_trend_store_web.dart` — Flutter Web. No-op stub. Web
///   dashboards consume a pre-built JSON bundle rather than a
///   live database.
///
/// Consumers `import 'package:simcrux/services/trend_store/sql_trend_store.dart'`
/// and call `SqlTrendStore.open(path: ...)` regardless of platform;
/// the conditional export below picks the correct file at compile
/// time.
library;

export 'sql_trend_store_io.dart'
    if (dart.library.js_interop) 'sql_trend_store_web.dart';
