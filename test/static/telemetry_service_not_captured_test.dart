// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `telemetryServiceProvider` must be read at the moment an event is recorded,
/// never captured into a long-lived field.
///
/// It is not a constant for the life of a session, and the way it changes is
/// the trap. `TelemetryConsentStore` publishes `unset` synchronously and reads
/// the persisted value back asynchronously, so on a cold start the gate has not
/// seen the user's stored answer yet and `telemetryServiceProvider` resolves
/// the no-op for the first few frames. Every long-lived notifier here builds
/// inside that window. A field assigned there records the **first frame's**
/// verdict for the whole session: an installation that had consented reports
/// nothing, and consenting again changes nothing, because the field is never
/// re-read.
///
/// That was live in this repo and invisible to every test, because the gating
/// tests seed consent synchronously and so never open the window. It surfaced
/// on a device the moment the gate started waiting for the store to settle —
/// the TELEMETRY_DEV builds went from reporting to reporting nothing.
///
/// The cost of not caching is a map lookup per event, against a `record` that
/// is an empty method on the no-op path. The cost of caching is every counter
/// the session would have reported.
///
/// A **local** `final telemetry = ref.read(...)` inside a function is fine and
/// is not flagged: it lives for one call, so it cannot go stale.
final RegExp _capturedField = RegExp(
  r'^\s*_\w+\s*=\s*(?:ref|_ref|container)\.read\(\s*'
  r'(?:\w+\.)?telemetryServiceProvider\s*\)',
  multiLine: true,
);

void main() {
  test('no lib/ file assigns telemetryServiceProvider into a field', () {
    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      for (final match in _capturedField.allMatches(source)) {
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offenders.add('${entity.path}:$line — ${match.group(0)!.trim()}');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Read telemetryServiceProvider where the event is recorded, not '
          'into a field. On a cold start the consent store has not settled '
          'and the provider resolves the no-op; a captured reference keeps '
          'that answer for the whole session.\n${offenders.join('\n')}',
    );
  });

  test('the scanner would actually catch it', () {
    // A guard whose pattern silently stopped matching reports success forever.
    // These are the exact shapes that were in the four repos.
    expect(
      _capturedField.hasMatch(
        '    _telemetry = ref.read(telemetryServiceProvider);',
      ),
      isTrue,
    );
    expect(
      _capturedField.hasMatch(
        '    _telemetry = ref.read(crux_telemetry.telemetryServiceProvider);',
      ),
      isTrue,
    );
    // And the two correct shapes are not flagged: the read at the record site,
    // and a local that lives for one call.
    expect(
      _capturedField.hasMatch(
        '    ref.read(telemetryServiceProvider).record(event);',
      ),
      isFalse,
    );
    expect(
      _capturedField.hasMatch(
        '  final telemetry = ref.read(telemetryServiceProvider);',
      ),
      isFalse,
    );
  });
}
