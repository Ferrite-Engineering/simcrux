// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Public entry point for the rebuild-from-`results.ndjson` recovery.
///
/// Re-exports the platform-appropriate implementation, on the same pattern as
/// `sql_trend_store.dart` and for the same reason: the io implementation reads
/// files through `dart:io`, and `flutter build web` compiles `lib/main.dart`
/// — App Diagnostics dialog included — for the web.
///
/// - `trend_store_rebuild_io.dart` — desktop / mobile / VM. Reads the
///   streaming archives and replays them through `recordTrendPoints`.
/// - `trend_store_rebuild_web.dart` — Flutter Web. There is no local archive
///   and no local database; the rebuilder reports every archive as unreadable
///   rather than pretending to have recovered anything.
library;

export 'trend_store_rebuild_io.dart'
    if (dart.library.js_interop) 'trend_store_rebuild_web.dart';
