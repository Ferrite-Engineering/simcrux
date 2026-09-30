// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:simcrux/web/web_results_document.dart';

/// Pluggable adapter that fetches the results document the web
/// dashboard renders.
///
/// The default web implementation lives in
/// `web_results_loader_web.dart` and uses `package:web` to read
/// `simcrux-results.json` or `results.ndjson` from same-origin URLs.
/// Tests inject a fake implementation through the provider's
/// `overrideWith`.
abstract class WebResultsLoader {
  /// Const constructor for subclasses.
  const WebResultsLoader();

  /// Fetches the document. The optional [resultsUrl] mirrors the
  /// `?results=…` query parameter; null means "use the default
  /// same-origin location" (`./simcrux-results.json`, falling back
  /// to `./results.ndjson`).
  Future<WebResultsDocument> load({String? resultsUrl});
}
