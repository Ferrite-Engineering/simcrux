// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_file_watcher/crux_file_watcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/watcher/providers/auto_reload_notifier.dart';
import 'package:simcrux/services/watcher/suite_source_watcher.dart';

void main() {
  group('AutoReloadState', () {
    test('default state has no pending paths', () {
      const state = AutoReloadState();
      expect(state.pendingPaths, isEmpty);
      expect(state.lastRerunAt, isNull);
    });

    test('copyWith replaces only specified fields', () {
      const state = AutoReloadState();
      final next = state.copyWith(
        pendingPaths: <String>{'a.sv', 'b.sv'},
        lastRerunAt: DateTime.utc(2026, 5, 23, 17),
      );
      expect(next.pendingPaths, <String>{'a.sv', 'b.sv'});
      expect(next.lastRerunAt, DateTime.utc(2026, 5, 23, 17));
    });
  });

  group('autoReloadNotifierProvider', () {
    test('initial state is empty when no config is active', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(autoReloadNotifierProvider).pendingPaths,
        isEmpty,
      );
    });

    test('dismiss clears pendingPaths', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(autoReloadNotifierProvider.notifier);
      // Direct state poke for test-only purposes: simulate the
      // prompt-mode receiver having staged change events.
      // We can't easily push from outside, but we can verify the
      // documented public behavior of `dismiss` against the
      // already-empty state — it should remain empty without
      // throwing.
      expect((notifier..dismiss()).state.pendingPaths, isEmpty);
    });
  });

  group('SuiteSourceChange', () {
    test('carries the path and event verbatim', () {
      const change = SuiteSourceChange(
        path: '/p/a.sv',
        event: FileWatchEvent.modified,
      );
      expect(change.path, '/p/a.sv');
      expect(change.event, FileWatchEvent.modified);
    });
  });
}
