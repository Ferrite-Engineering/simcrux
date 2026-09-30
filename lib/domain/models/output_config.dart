// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Project-level `output:` block in `simcrux.yaml`.
///
/// Toggles streaming results to disk (NDJSON + summary) so very-large
/// regressions do not accumulate the full result set in memory. The
/// `--ci` driver enables streaming by default; interactive runs opt in
/// via `output: { streaming: true }`.
@immutable
class OutputConfig {
  /// Creates an [OutputConfig].
  const OutputConfig({
    this.streaming = false,
    this.streamingResultsPath,
    this.streamingSummaryPath,
  });

  /// When true, the CI runner (and any caller passing this config to
  /// the scheduler) writes results to disk as they arrive and reads
  /// them back at export time. Default `false` for interactive runs;
  /// the `--ci` mode promotes the effective value to `true`.
  final bool streaming;

  /// Optional explicit path for the NDJSON file. When null the CI
  /// runner falls back to `<project-dir>/results.ndjson`.
  final String? streamingResultsPath;

  /// Optional explicit path for the summary JSON. When null the CI
  /// runner falls back to `<project-dir>/results.summary.json`.
  final String? streamingSummaryPath;

  /// Returns a copy with the given fields replaced.
  OutputConfig copyWith({
    bool? streaming,
    String? streamingResultsPath,
    String? streamingSummaryPath,
  }) {
    return OutputConfig(
      streaming: streaming ?? this.streaming,
      streamingResultsPath: streamingResultsPath ?? this.streamingResultsPath,
      streamingSummaryPath: streamingSummaryPath ?? this.streamingSummaryPath,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OutputConfig &&
        other.streaming == streaming &&
        other.streamingResultsPath == streamingResultsPath &&
        other.streamingSummaryPath == streamingSummaryPath;
  }

  @override
  int get hashCode =>
      Object.hash(streaming, streamingResultsPath, streamingSummaryPath);
}
