// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/web/web_filter.dart';
import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_results_loader.dart';

/// The active [WebResultsLoader]. The web entry point
/// (`lib/main_web.dart`) wires the fetch implementation; tests override it
/// with an in-memory loader.
final Provider<WebResultsLoader> webResultsLoaderProvider =
    Provider<WebResultsLoader>(
      (ref) => throw UnimplementedError(
        'webResultsLoaderProvider must be overridden by the entry-point '
        '(the web build wires WebFetchResultsLoader; tests inject an '
        'in-memory loader).',
      ),
    );

/// Optional `?results=<url>` deep-link parameter the loader should
/// honor. Null means "use the default same-origin location".
final Provider<String?> webResultsUrlProvider = Provider<String?>(
  (ref) => null,
);

/// The loaded [WebResultsDocument]. Async to allow the underlying
/// fetch to fail with a structured error visible in the UI.
final FutureProvider<WebResultsDocument> webResultsProvider =
    FutureProvider<WebResultsDocument>((ref) async {
      final loader = ref.watch(webResultsLoaderProvider);
      final url = ref.watch(webResultsUrlProvider);
      return loader.load(resultsUrl: url);
    });

/// Notifier backing [webOpenedDocumentProvider].
class WebOpenedDocumentNotifier extends Notifier<WebResultsDocument?> {
  @override
  WebResultsDocument? build() => null;

  /// Publishes a document the user opened directly (web file picker),
  /// which the dashboard renders in place of the auto-fetched
  /// [webResultsProvider].
  // ignore: use_setters_to_change_properties
  void set(WebResultsDocument doc) => state = doc;

  /// Drops the user-opened document, falling back to the auto-fetched
  /// results.
  void clear() => state = null;
}

/// A [WebResultsDocument] the user opened via the dashboard's
/// "Open results file…" affordance.
///
/// The web viewer otherwise only loads results from a `?results=<url>`
/// query parameter or an auto-fetched same-origin
/// `simcrux-results.json` / `results.ndjson`. This provider lets a user
/// with a local `.ndjson` / `.json` file load it straight into the UI
/// (via [WebResultsDocument.decode] → `decodeNdjson` /
/// `decodeConsolidated`) with nothing hosted. Null until the user opens
/// a file; when non-null it takes precedence over [webResultsProvider].
final NotifierProvider<WebOpenedDocumentNotifier, WebResultsDocument?>
webOpenedDocumentProvider =
    NotifierProvider<WebOpenedDocumentNotifier, WebResultsDocument?>(
      WebOpenedDocumentNotifier.new,
    );

/// Notifier for the dashboard's active filter state.
class WebFilterNotifier extends Notifier<WebFilter> {
  @override
  WebFilter build() => const WebFilter();

  /// Replaces the entire filter state.
  // ignore: use_setters_to_change_properties
  void set(WebFilter next) => state = next;

  /// Updates the free-text query.
  void setQuery(String query) => state = state.copyWith(query: query);

  /// Toggles a status chip on/off in the filter set.
  void toggleStatus(TestStatus status) {
    final next = {...state.statuses};
    if (next.contains(status)) {
      next.remove(status);
    } else {
      next.add(status);
    }
    state = state.copyWith(statuses: next);
  }

  /// Clears every term.
  void clear() => state = const WebFilter();
}

/// Active filter state on the web dashboard.
final NotifierProvider<WebFilterNotifier, WebFilter> webFilterProvider =
    NotifierProvider<WebFilterNotifier, WebFilter>(WebFilterNotifier.new);

/// Notifier for [webSelectedTestProvider].
class WebSelectedTestNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Replaces the selected test id (null to close the inspector).
  // ignore: use_setters_to_change_properties
  void select(String? testId) => state = testId;
}

/// Currently-selected [WebResultRow.testId], or null when the
/// inspector is closed.
final NotifierProvider<WebSelectedTestNotifier, String?>
webSelectedTestProvider = NotifierProvider<WebSelectedTestNotifier, String?>(
  WebSelectedTestNotifier.new,
);
