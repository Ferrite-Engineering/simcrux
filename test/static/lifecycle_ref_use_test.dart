// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

// Structural guardrail against the "Ref used inside a Riverpod
// lifecycle callback" bug class, scanning `lib/`. See
// `lifecycle_ref_scanner.dart` for the detection rules, the empirical
// verification of which hooks are unsafe, and the rationale for what is
// deliberately not flagged.
//
// THE BUG CLASS IN ONE LINE:
// `ref.onDispose(() { ref.read(x)...; sub.cancel(); })` throws on the
// read, and the throw aborts the hook — so `sub.cancel()` never runs.
// The leak is silent and the blast radius is resource cleanup.
//
// WHY UNIT TESTS DON'T CATCH IT:
// Provider tests assert on state, not on teardown. A test has to
// dispose a container while the provider holds live resources AND then
// assert those resources were released — vanishingly rare. The guard is
// therefore static and source-driven.
//
// When this test fails it has almost certainly found a real latent bug.
// The fix is to resolve the value eagerly in `build()` and close over
// it. Add to the allowlist below ONLY with a documented reason.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'lifecycle_ref_scanner.dart';

/// `file:line` entries that are intentionally exempt, with the reason.
/// Keep this list empty if at all possible — a genuine need to touch
/// `ref` at teardown is always better served by capturing the value
/// before registering the hook.
const Map<String, String> allowlist = <String, String>{};

void main() {
  group('lifecycle Ref-use scanner', () {
    test('flags every unsafe shape in the shapes fixture', () {
      final fixture = File('test/static/lifecycle_ref_shapes/shapes.dart');
      expect(
        fixture.existsSync(),
        isTrue,
        reason: 'run this test from the package root (flutter test)',
      );
      final uses = scanSource(fixture.readAsStringSync(), fixture.path);
      final details = uses.map((u) => u.detail).join('\n');

      // Shape 1 — direct `ref.read` in the callback body.
      expect(
        details,
        contains('body uses `ref.read`'),
        reason: 'direct shape not detected',
      );

      // Shape 2 — the motivating bug: a helper called from the hook.
      expect(
        details,
        contains('_releaseActiveRunToken'),
        reason:
            'helper shape not detected; this is the shape of the bug the '
            'scanner exists for',
      );

      // Shape 2b — a two-level helper chain.
      expect(
        details,
        contains('_outer -> _inner'),
        reason: 'transitive helper chain not resolved',
      );

      // Shape 3 — tear-off of a ref-using method.
      expect(
        details,
        contains('onDispose(_teardown)'),
        reason: 'tear-off shape not detected',
      );

      // Shape 4 — every non-dispose lifecycle hook.
      for (final hook in lifecycleHooks) {
        expect(
          uses.map((u) => u.hook),
          contains(hook),
          reason: '$hook not scanned',
        );
      }
    });

    test('leaves the control shapes clean', () {
      final fixture = File('test/static/lifecycle_ref_shapes/shapes.dart');
      final src = fixture.readAsStringSync();
      final uses = scanSource(src, fixture.path);
      final lines = src.split('\n');

      // Every flagged line must sit inside the POSITIVE half of the
      // fixture. Anything flagged past the NEGATIVE banner is a false
      // positive on a legitimate pattern.
      final negativeStart =
          lines.indexWhere((l) => l.contains('=== NEGATIVE')) + 1;
      expect(negativeStart, greaterThan(0));

      final falsePositives = uses.where((u) => u.line >= negativeStart);
      expect(
        falsePositives.map((u) => '${u.line}: ${u.detail}'),
        isEmpty,
        reason:
            'the control shapes are legitimate patterns and must not be '
            'flagged',
      );
    });
  });

  test('no `Ref` is used inside a Riverpod lifecycle callback in lib/', () {
    final libDir = Directory('lib');
    expect(
      libDir.existsSync(),
      isTrue,
      reason: 'run this test from the package root (flutter test)',
    );

    final uses = scanLifecycleRefUse([libDir]).where((u) {
      return !allowlist.containsKey('${u.path}:${u.line}');
    }).toList();

    expect(uses, isEmpty, reason: formatLifecycleRefReport(uses));
  });
}
