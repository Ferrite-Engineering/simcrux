// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// The root `ProviderContainer` must be mounted, not only its scoped child.
///
/// Riverpod gives every container its own scheduler, and a scheduler only
/// refreshes providers in step with the frame when an
/// `UncontrolledProviderScope` for that container is in the tree. Without
/// one, a root-hosted provider whose dependency changed is refreshed by a
/// zero-length timer instead — and a frame that lands first rebuilds the
/// widgets watching it while the provider is still dirty. The first of them
/// to `watch` it flushes it mid-build, notifying its siblings, and the
/// framework asserts `setState() or markNeedsBuild() called during build`.
///
/// That is what failed the Pro seeded flaky-panel journey: every dashboard
/// row watches the root-hosted flakiness scores, and a finished run both
/// bumped the trend-store tick (root) and rebuilt the rows (tab scope).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/workspace/providers/workspace_containers.dart';

class _Tick extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

// Neither provider is overridden, so both materialize in the ROOT
// container, as the dashboard's flakiness scores do in production.
final _tickProvider = NotifierProvider<_Tick, int>(_Tick.new);
final _derivedProvider = Provider<int>((ref) => ref.watch(_tickProvider) * 10);

class _Row extends ConsumerWidget {
  const _Row({required this.label, required this.generation});

  final String label;
  final int generation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Text('$label ${ref.watch(_derivedProvider)} g$generation');
  }
}

class _Rows extends StatefulWidget {
  const _Rows();

  @override
  State<_Rows> createState() => _RowsState();
}

class _RowsState extends State<_Rows> {
  int generation = 0;

  void rebuildRows() => setState(() => generation++);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Row(label: 'a', generation: generation),
        _Row(label: 'b', generation: generation),
      ],
    );
  }
}

void main() {
  testWidgets(
    'a root provider that changed is refreshed before the rows watching it '
    'rebuild in the same frame',
    (tester) async {
      final root = ProviderContainer();
      final scoped = ProviderContainer(parent: root);
      addTearDown(root.dispose);
      addTearDown(scoped.dispose);

      await tester.pumpWidget(
        WorkspaceContainersScope(
          root: root,
          scoped: scoped,
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: _Rows(),
          ),
        ),
      );
      expect(find.text('a 0 g0'), findsOneWidget);

      // A finished run, in one turn: the root-hosted dependency changes and
      // the rows are rebuilt for an unrelated reason, before any timer runs.
      root.read(_tickProvider.notifier).bump();
      tester.state<_RowsState>(find.byType(_Rows)).rebuildRows();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('a 10 g1'), findsOneWidget);
      expect(find.text('b 10 g1'), findsOneWidget);
    },
  );
}
