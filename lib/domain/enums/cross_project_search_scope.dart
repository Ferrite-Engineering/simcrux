// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Scope of a [CrossProjectSearchQuery] — which surfaces inside each
/// open project the worker traverses when matching the query pattern.
///
/// Multiple scopes per query are not supported (use [all] for a
/// blended walk); the enum is a single-select drop-down in the UI so
/// the result list stays semantically coherent.
enum CrossProjectSearchScope {
  /// Match against `TestSpec.id` and `TestResult.testId` values
  /// (i.e. user-facing test names). Cheapest scope — the project's
  /// in-memory test list is the only data the worker needs to walk.
  testNames,

  /// Match against `TestResult.failureMessage` values across each
  /// project's most-recent run. Useful for finding the projects that
  /// hit a specific assertion or backtrace.
  failureMessages,

  /// Match against source file paths under the project root. Walks
  /// the project directory tree with reasonable extension filters
  /// (`.sv`, `.v`, `.vh`, `.svh`, `.py`, `.yaml`, `.tcl`).
  filePaths,

  /// Match across every scope in one pass. Worker emits matches in
  /// scope-priority order: test names first (cheapest), then failure
  /// messages, then file paths.
  all,
}
