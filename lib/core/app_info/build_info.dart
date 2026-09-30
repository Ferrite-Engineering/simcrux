// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Compile-time build identifiers for the running SimCrux build.
///
/// **Pure Dart, synchronous, available everywhere** — which is the whole
/// reason it exists rather than everything reading `aboutBuildInfoProvider`.
/// That provider is the richer answer (OS, architecture, Dart SDK) and it is
/// the right one for an About box, but it is `async`, it is Riverpod, and it
/// is built on `PackageInfo.fromPlatform()`, so it is unavailable to three
/// callers that need to name this build: the CXP handshake during bootstrap,
/// anything in `lib/domain/`, and — the one that forced this file into
/// existence — the SQLite trend store, which is opened by `package:crux_sqlite`
/// and stamps the running version into every database it migrates.
/// `crux_sqlite` is pure Dart permanently (both products ship headless Pro
/// CLIs), so a Flutter-shaped version source is not a source it can use.
///
/// **The constants below are checked against `pubspec.yaml` by
/// `test/static/build_info_matches_pubspec_test.dart`.** That test is not
/// ceremony: this file previously carried `0.1.0` for a 0.8.0 build, silently,
/// for several releases, which is precisely the "a constant someone forgets to
/// bump" failure the trend store's derived schema version was designed to
/// avoid. A hand-maintained constant is safe exactly as long as something
/// fails when it rots.
abstract final class SimCruxBuildInfo {
  /// Stable lowercase product identifier, matching the rest of the suite:
  /// `'wavecrux'`, `'netcrux'`, `'lintcrux'`, `'simcrux'`.
  ///
  /// Used on the CXP wire and written to `schema_meta.product`. It is a
  /// machine identifier, not a display name — user-facing product names come
  /// from the ARB files.
  static const String productName = 'simcrux';

  /// Product version (semver, no build number) as it appears in
  /// `pubspec.yaml`.
  static const String productVersion = '1.0.1';
}
