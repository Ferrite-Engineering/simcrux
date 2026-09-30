// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:simcrux/web/web_results_document.dart';
import 'package:simcrux/web/web_results_loader.dart';

/// Default web implementation of [WebResultsLoader].
///
/// Resolves the results URL as follows:
///
/// 1. If [resultsUrl] is provided (typically from the `?results=…`
///    query parameter), fetch that URL directly.
/// 2. Otherwise try `./simcrux-results.json` next to the served
///    `index.html`.
/// 3. On 404 / decode failure for the consolidated document, fall
///    back to `./results.ndjson` (the streaming variant).
class WebFetchResultsLoader extends WebResultsLoader {
  /// Const constructor.
  const WebFetchResultsLoader();

  @override
  Future<WebResultsDocument> load({String? resultsUrl}) async {
    if (resultsUrl != null) {
      final body = await _fetchText(resultsUrl);
      return WebResultsDocument.decode(body);
    }
    try {
      final body = await _fetchText('simcrux-results.json');
      return WebResultsDocument.decodeConsolidated(body);
    } on FormatException {
      // Fall through to NDJSON fallback below.
    } on _FetchException catch (e) {
      if (e.status != 404) rethrow;
    }
    final ndjson = await _fetchText('results.ndjson');
    return WebResultsDocument.decodeNdjson(ndjson);
  }

  static Future<String> _fetchText(String url) async {
    final response = await _fetch(url.toJS).toDart;
    final ok = response.getProperty<JSBoolean>('ok'.toJS).toDart;
    final status = response.getProperty<JSNumber>('status'.toJS).toDartInt;
    if (!ok) {
      throw _FetchException(url: url, status: status);
    }
    final textPromise = response.callMethod<JSPromise>('text'.toJS);
    final text = await textPromise.toDart;
    return (text! as JSString).toDart;
  }
}

@JS('fetch')
external JSPromise<JSObject> _fetch(JSString url);

class _FetchException implements Exception {
  _FetchException({required this.url, required this.status});

  final String url;
  final int status;

  @override
  String toString() => 'Fetch $url failed: HTTP $status';
}
