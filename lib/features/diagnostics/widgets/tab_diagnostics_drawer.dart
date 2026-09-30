// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/providers/regression_runner.dart';
import 'package:simcrux/features/diagnostics/providers/diagnostics_enabled_provider.dart';
import 'package:simcrux/features/diagnostics/services/diagnostics_report.dart';
import 'package:simcrux/features/workspace/providers/container_managers.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/job_scheduler/job_scheduler_provider.dart';

/// Tab Diagnostics drawer (per-tab) — gives the user a structured
/// view of the active project's config metadata, simulator backend
/// details, and scheduler state.
///
/// Three sections: Config Info, Simulator Backend, Scheduler State.
/// Opened via
/// [TabDiagnosticsDrawer.open] as a right-aligned NON-MODAL
/// [OverlayEntry] (the WaveCrux Tab Diagnostics pattern) from
/// Cmd/Ctrl+Shift+I, the Tools menu, and the command palette. The old
/// Scaffold `endDrawer` wiring was unreachable (nothing called
/// `openEndDrawer`) and a Scaffold drawer's barrier blocks the rest of
/// the chrome; the overlay entry leaves it fully interactive.
class TabDiagnosticsDrawer extends ConsumerWidget {
  /// Creates a [TabDiagnosticsDrawer].
  const TabDiagnosticsDrawer({super.key});

  /// Opens the drawer as a right-aligned non-modal overlay.
  ///
  /// Inserts an [OverlayEntry] into the root [Overlay] rather than a
  /// modal route, so the underlying chrome stays fully interactive —
  /// only the drawer's own Material region absorbs events (WaveCrux's
  /// Tab Diagnostics drawer pattern). Escape closes it; it follows the
  /// active tab and auto-dismisses when the last tab closes or the
  /// diagnostics opt-in flips off.
  ///
  /// Returns when the drawer is closed.
  /// Re-entrancy guarded via the suite-shared [ModalGuard]
  /// (shortcut auto-repeat, or the menu while the drawer is already up,
  /// must not stack a second drawer) — this previously mirrored the guard
  /// with a local `_open` flag.
  static Future<void> open(BuildContext context) {
    return ModalGuard.run('tabDiagnostics', () async {
      // The action-handler path hands over the routerDelegate NAVIGATOR's
      // own context, whose Overlay is a descendant (not an ancestor), so
      // an ancestor-only Overlay.of lookup finds nothing there. Resolve
      // the overlay through the navigator itself in that case.
      final navigator =
          context is StatefulElement && context.state is NavigatorState
          ? context.state as NavigatorState
          : Navigator.maybeOf(context, rootNavigator: true);
      final overlay =
          navigator?.overlay ?? Overlay.of(context, rootOverlay: true);
      final completer = Completer<void>();
      late OverlayEntry entry;
      void close() {
        if (entry.mounted) entry.remove();
        if (!completer.isCompleted) completer.complete();
      }

      entry = OverlayEntry(
        builder: (overlayContext) => _TabDiagnosticsDrawerHost(
          onClose: close,
        ),
      );
      overlay.insert(entry);
      await completer.future;
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final config = ref.watch(activeConfigProvider);
    final runState = ref
        .watch(regressionRunnerProvider)
        .maybeWhen<RegressionRunState?>(
          data: (s) => s,
          orElse: () => null,
        );
    final driverRegistry = ref.watch(simulatorDriverRegistryProvider);

    return Drawer(
      width: 380,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Section(label: l10n.diagnosticsTabConfigInfo, theme: theme),
            if (config == null)
              Text(l10n.diagnosticsTabNoConfigLoaded)
            else ...[
              _Row(
                label: l10n.diagnosticsTabRowPath,
                value: config.projectFilePath,
              ),
              _Row(
                label: l10n.diagnosticsTabRowSchemaVersion,
                value: config.schemaVersion,
              ),
              _Row(
                label: l10n.diagnosticsTabRowSuites,
                value: config.suites.length.toString(),
              ),
              _Row(
                label: l10n.diagnosticsTabRowTests,
                value: config.suites
                    .fold<int>(0, (sum, s) => sum + s.tests.length)
                    .toString(),
              ),
              if (runState != null)
                _Row(
                  label: l10n.diagnosticsTabRowLastRunWallTime,
                  value: _formatDuration(
                    (runState.run.finishedAt ?? DateTime.now().toUtc())
                        .difference(runState.run.startedAt),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            _Section(label: l10n.diagnosticsTabSimulatorBackend, theme: theme),
            for (final id in driverRegistry.simulatorIds)
              _Row(label: id, value: l10n.diagnosticsTabDriverRegistered),
            const SizedBox(height: 16),
            _Section(label: l10n.diagnosticsTabSchedulerState, theme: theme),
            _Row(
              label: l10n.diagnosticsTabRowTotalTests,
              value: runState?.run.testIds.length.toString() ?? '—',
            ),
            _Row(
              label: l10n.diagnosticsTabRowCompleted,
              value: runState?.run.results.length.toString() ?? '—',
            ),
            _Row(
              label: l10n.diagnosticsTabRowFinished,
              value: runState?.isFinished.toString() ?? '—',
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => _copyReport(context, ref),
              icon: const Icon(Icons.content_copy_outlined),
              label: Text(l10n.diagnosticsActionCopyTabReport),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyReport(BuildContext context, WidgetRef ref) async {
    final report = buildTabDiagnosticsReport(ref);
    await Clipboard.setData(ClipboardData(text: report));
    if (!context.mounted) return;
    final l10n = L10N.of(context);
    showCruxInfoSnack(context, l10n.diagnosticsCopiedToClipboard);
  }
}

/// Hosts [TabDiagnosticsDrawer] inside the overlay entry: right-aligned
/// slide-in transition, an Escape-to-close shortcut, active-tab provider
/// scoping, and the auto-dismiss guards (no tabs left / diagnostics
/// opt-in flipped off). Mirrors WaveCrux's `_TabDiagnosticsDrawerHost`.
class _TabDiagnosticsDrawerHost extends ConsumerStatefulWidget {
  const _TabDiagnosticsDrawerHost({required this.onClose});

  /// Removes the overlay entry and completes the open future.
  final VoidCallback onClose;

  @override
  ConsumerState<_TabDiagnosticsDrawerHost> createState() =>
      _TabDiagnosticsDrawerHostState();
}

class _TabDiagnosticsDrawerHostState
    extends ConsumerState<_TabDiagnosticsDrawerHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _offset;
  final FocusScopeNode _scopeNode = FocusScopeNode(
    debugLabel: 'TabDiagnosticsDrawerHost',
  );
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _offset =
        Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        );
    _controller.forward();
    // Take keyboard focus explicitly: an `autofocus` request is ignored
    // when the underlying route's scope already holds focus (an overlay
    // entry is a sibling of the routes, not inside one), which would
    // leave the Escape binding below unreachable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scopeNode.requestFocus();
    });
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _controller.reverse();
    if (!mounted) return;
    widget.onClose();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Follow the ACTIVE tab: the drawer content reads per-tab providers
    // (activeConfigProvider, regressionRunnerProvider, the scheduler), so
    // it must mount inside the active tab's ProviderContainer — reading
    // them from the root scope would render the "no config loaded" empty
    // state with a config open (the scope-leak class).
    final activeTabId = ref.watch(
      workspaceProvider.select((ws) => ws.value?.activeTabId),
    );
    final diagnosticsEnabled = ref.watch(diagnosticsEnabledProvider);

    // Auto-dismiss when the last tab closes or the diagnostics opt-in
    // flips off — the same reactive close WaveCrux's drawer performs.
    // Rendering nothing this frame also guarantees the content is never
    // built against a disposed per-tab container.
    ProviderContainer? container;
    if (activeTabId != null && diagnosticsEnabled) {
      try {
        container = ref
            .read(workspaceContainerManagersProvider)
            .tabs
            .containerFor(activeTabId);
      } on Object {
        container = null; // managers unbound (widget-test host) — close.
      }
    }
    if (container == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_close());
      });
      return const SizedBox.shrink();
    }

    // Escape-to-close binds at this host's level so the key is consumed
    // even when no inner widget has focus.
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              unawaited(_close());
              return null;
            },
          ),
        },
        child: FocusScope(
          node: _scopeNode,
          child: Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SlideTransition(
              position: _offset,
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height,
                child: UncontrolledProviderScope(
                  // Keyed by the tab id so a tab switch fully remounts the
                  // subtree against the new tab's container (the WaveCrux
                  // drawer's remount-on-switch behavior).
                  key: ValueKey('tabScope.diag:$activeTabId'),
                  container: container,
                  child: const TabDiagnosticsDrawer(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.theme});
  final String label;
  final ThemeData theme;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatDuration(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds} ms';
  if (d.inSeconds < 60) return '${d.inSeconds} s';
  return '${d.inMinutes}m ${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}
