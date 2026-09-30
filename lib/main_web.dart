// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/web/web_app.dart';
import 'package:simcrux/web/web_results_loader_web.dart';
import 'package:simcrux/web/web_results_provider.dart';

/// Entry point for the read-only web **dashboard viewer** ([SimcruxWebApp]
/// → `WebDashboardScreen`).
///
/// This is a *separate* entrypoint from the normal app (`lib/main.dart`):
/// the default `flutter run -d chrome` launches `lib/main.dart` and lands
/// on the welcome / empty-canvas surface, **not** the dashboard viewer. To
/// run the viewer, target this file explicitly:
///
/// ```bash
/// flutter run -d chrome -t lib/main_web.dart
/// flutter build web --target lib/main_web.dart
/// ```
///
/// The resulting `build/web/` bundle is what `simcrux export-dashboard
/// out-dir` copies into the output directory alongside the
/// `simcrux-results.json` (or `results.ndjson`) for the run. Results load
/// from `?results=<url>`, an auto-fetched same-origin document, or the
/// viewer's own "Open results file…" picker (see `openWebResultsFile`).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final resultsUrl = _readResultsUrl();
  runApp(
    ProviderScope(
      overrides: <Override>[
        webResultsLoaderProvider.overrideWithValue(
          const WebFetchResultsLoader(),
        ),
        if (resultsUrl != null)
          webResultsUrlProvider.overrideWithValue(resultsUrl),
      ],
      child: const SimcruxWebApp(),
    ),
  );
}

/// Returns the value of the `?results=` query parameter on the host
/// page, or null when none is set. The web build resolves this by
/// parsing the current Flutter web URL via `Uri.base`.
String? _readResultsUrl() {
  final uri = Uri.base;
  final fromQuery = uri.queryParameters['results'];
  if (fromQuery != null && fromQuery.isNotEmpty) return fromQuery;
  // go_router-style hash routes carry their query after the `#`. The
  // Flutter web URL strategy preserves the hash in Uri.base.fragment.
  final fragment = uri.fragment;
  if (fragment.isNotEmpty && fragment.contains('?')) {
    try {
      final fragUri = Uri.parse(fragment);
      final fromFrag = fragUri.queryParameters['results'];
      if (fromFrag != null && fromFrag.isNotEmpty) return fromFrag;
    } on FormatException {
      // Fall through.
    }
  }
  return null;
}
