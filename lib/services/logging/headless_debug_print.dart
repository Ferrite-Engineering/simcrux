// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io' show stderr;

import 'package:flutter/foundation.dart';

/// Runs [body] with Flutter's [debugPrint] writing to stderr, and puts the
/// previous [debugPrint] back when [body] finishes.
///
/// Flutter presents a framework error through [debugPrint], in a release
/// build as well as a debug one, and the default [debugPrint] ends in
/// `print`: stdout. A headless run's stdout belongs to the script reading
/// it. `--ci --json` prints one JSON document there, and a framework error
/// dumped into the same stream is a pipeline that can no longer parse its
/// own results. On stderr the dump is still in the job log, and stdout
/// carries only what the run meant to say.
///
/// Scoped to the call rather than set for the process, so the GUI keeps the
/// framework's console output and a test that runs a headless branch leaves
/// [debugPrint] as it found it.
Future<T> withDebugPrintOnStderr<T>(Future<T> Function() body) async {
  final previous = debugPrint;
  debugPrint = debugPrintToStderr;
  try {
    return await body();
  } finally {
    debugPrint = previous;
  }
}

/// A [DebugPrintCallback] that writes [message] to stderr, word-wrapped to
/// [wrapWidth] when one is given, as the default callback wraps it.
void debugPrintToStderr(String? message, {int? wrapWidth}) {
  if (message == null) return;
  final lines = wrapWidth == null
      ? message.split('\n')
      : debugWordWrap(message, wrapWidth);
  try {
    lines.forEach(stderr.writeln);
  } on Object {
    // No usable stderr (a closed or unbound handle). There is nowhere left
    // to say it, and stdout is exactly where it must not go.
  }
}
