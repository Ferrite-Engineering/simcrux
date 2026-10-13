// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Severity of a [ConfigLoaderError] entry.
///
/// The loader collects fatal errors and non-fatal advisories into the same
/// error list, then routes them at the throw site: any [error] entry
/// triggers a [ConfigLoaderException]; [warning] and [info] entries pass
/// through to the caller via the loaded [RegressionConfig.loadWarnings]
/// surface so the dashboard can render them inline without aborting the
/// load.
///
/// **Two non-fatal levels, because one switch used to hide both.** The Pro
/// overlay lets the user turn off the parameterization advisories, and
/// while every advisory was a [warning] that switch also hid the
/// project-tooling one: a project file asked to run a binary, the loader
/// stopped it, and the user saw nothing where they should have seen why
/// their simulator config was ignored. Severity decides what a switch may
/// hide, not the category a message happens to come from.
enum ConfigLoaderErrorSeverity {
  /// A configuration problem severe enough to prevent loading. The
  /// loader throws a [ConfigLoaderException] when at least one error
  /// of this severity is present.
  error,

  /// A capability the loader dropped from the file, and the user needs to
  /// know it did: the project-tooling gate ignoring `simulators.<id>.path`,
  /// a riscv executable path, a simulator option. Shown whether or not the
  /// advisory switch is on, because hiding it leaves a user concluding
  /// their configuration is simply broken.
  warning,

  /// An advisory the user may hide: the parameterization tier-gate telling
  /// them a `seeds:` or `parameters:` sweep ran once because the active
  /// licence does not unlock it. Nothing executes differently for not
  /// reading it, so the Pro overlay's **Parameterization** warnings switch
  /// may turn it off.
  info,
}

/// Structured error surfaced by the YAML config loader.
///
/// Carries the source path and (when the YAML parser preserved them)
/// the 1-based line and column where the error was detected, plus a
/// human-readable message. The dashboard renders these inline in the
/// Welcome screen and the diagnostics report; the CLI prints them to
/// stderr as `path:line:col: message` for editor-clickable diagnostics.
///
/// Construct via the named factories so the error message is
/// consistent across call sites. Plain-message construction
/// ([ConfigLoaderError.generic]) is for cases where the YAML library
/// did not surface a source span (typically when we caught a top-level
/// type error after the initial parse succeeded).
@immutable
class ConfigLoaderError {
  /// Creates a [ConfigLoaderError] with full source-span information.
  const ConfigLoaderError({
    required this.path,
    required this.message,
    this.line,
    this.column,
    this.severity = ConfigLoaderErrorSeverity.error,
  });

  /// Convenience: no source span — the error fired between parse and
  /// the typed config materialization (e.g. a `version:` value of the
  /// wrong type at the document root).
  const ConfigLoaderError.generic({
    required this.path,
    required this.message,
    this.severity = ConfigLoaderErrorSeverity.error,
  }) : line = null,
       column = null;

  /// Absolute path to the `simcrux.yaml` file the error came from.
  final String path;

  /// 1-based line number reported by the YAML parser. Null when the
  /// YAML parser did not preserve a source span for the offending
  /// node.
  final int? line;

  /// 1-based column number reported by the YAML parser. Null in the
  /// same conditions as [line].
  final int? column;

  /// Human-readable explanation. Always English (per ARB rules — the
  /// loader runs before any UI is rendered, so the message is shown
  /// verbatim by the CLI and translated upstream when surfaced in
  /// the UI).
  final String message;

  /// Severity of this entry. Defaults to
  /// [ConfigLoaderErrorSeverity.error] so unannotated factory calls
  /// retain the historical "always fatal" semantics. The project-tooling
  /// gate emits [ConfigLoaderErrorSeverity.warning] entries and the
  /// parameterization tier-gate [ConfigLoaderErrorSeverity.info] ones, so
  /// the loader can surface both as advisories without aborting the load
  /// and the dashboard can tell which a user may hide.
  final ConfigLoaderErrorSeverity severity;

  /// Whether this entry stops the load.
  bool get isFatal => severity == ConfigLoaderErrorSeverity.error;

  /// Pre-formatted `path:line:col: message` string, suitable for
  /// editor-clickable CLI output. Falls back to `path: message` when
  /// the source span is absent.
  String format() {
    final lineCol = (line != null && column != null) ? ':$line:$column' : '';
    return '$path$lineCol: $message';
  }

  @override
  String toString() => 'ConfigLoaderError(${format()})';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ConfigLoaderError &&
        other.path == path &&
        other.line == line &&
        other.column == column &&
        other.message == message &&
        other.severity == severity;
  }

  @override
  int get hashCode => Object.hash(path, line, column, message, severity);
}

/// Thrown by [ConfigLoader.load] when validation fails. Wraps a list
/// of [ConfigLoaderError]s so the caller can surface all problems at
/// once rather than fail-fast on the first one.
class ConfigLoaderException implements Exception {
  /// Creates a [ConfigLoaderException].
  ConfigLoaderException(List<ConfigLoaderError> errors)
    : errors = List<ConfigLoaderError>.unmodifiable(errors);

  /// The validation errors encountered while loading the config.
  /// Always non-empty.
  final List<ConfigLoaderError> errors;

  @override
  String toString() {
    if (errors.length == 1) return 'ConfigLoaderException: ${errors.single}';
    final lines = errors.map((e) => '  - ${e.format()}').join('\n');
    return 'ConfigLoaderException (${errors.length} errors):\n$lines';
  }
}
