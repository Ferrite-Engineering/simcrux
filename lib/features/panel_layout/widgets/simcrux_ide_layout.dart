// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/panel_layout_state.dart';
import 'package:simcrux/features/panel_layout/providers/panel_layout_provider.dart';
import 'package:simcrux/features/workspace/widgets/simcrux_docks.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// Signature for a pane content builder. Mirrors the `IdePaneBuilder`
/// shape from the `crux_ide_layout` package but lets callers ignore the
/// animation progress when their content does not animate.
typedef PaneContentBuilder = Widget Function(BuildContext context);

/// SimCrux's four-pane IDE-layout host.
///
/// A thin adapter over the cross-suite [CruxIdeLayout] (from
/// `crux_ide_layout`):
///
/// - **Left:** test/run browser (signal-tree analogue)
/// - **Center:** run-results dashboard
/// - **Right:** run-details inspector
/// - **Bottom:** log-stream panel
///
/// SimCrux is the suite's **fraction-sizing** case: it projects the
/// [panelLayoutProvider]'s `double` fractions onto the shared widget via
/// [_SimcruxIdePanelLayout] (returning `PaneSize.fraction(...)`), validating
/// the shared widget's unit-agnostic sizing path. `CruxIdeLayout` owns the
/// `IdeController`, the resizer theme, and the visibility/size sync that each
/// app previously hand-rolled.
///
/// Visibility (drag-to-collapse / toggle) is persisted back through the
/// notifier; SimCrux does **not** persist drag-resize sizes, so the sink's
/// size setters are no-ops (see [_SimcruxIdePanelLayoutSink]). Callers can
/// inject pane content via the optional builder parameters; defaults render
/// labeled, localized placeholders.
class SimcruxIdeLayout extends ConsumerWidget {
  /// Creates a [SimcruxIdeLayout].
  ///
  /// Callers can inject pane content via the optional builder
  /// parameters; defaults render labeled placeholders so the layout
  /// renders meaningfully before the real widgets land.
  const SimcruxIdeLayout({
    super.key,
    this.testBrowserBuilder,
    this.runResultsBuilder,
    this.runDetailsBuilder,
    this.logPanelBuilder,
  });

  /// Builds the body of the left test/run browser pane.
  final PaneContentBuilder? testBrowserBuilder;

  /// Builds the body of the center run-results pane.
  final PaneContentBuilder? runResultsBuilder;

  /// Builds the body of the right inspector / run-details pane.
  final PaneContentBuilder? runDetailsBuilder;

  /// Builds the body of the bottom log-stream pane.
  final PaneContentBuilder? logPanelBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(panelLayoutProvider);
    final notifier = ref.read(panelLayoutProvider.notifier);
    final l10n = L10N.of(context);
    // Collapsed regions leave a slim restore bar along their edge
    // (JetBrains tool-window model — the suite panel-reopen canon).
    return SimcruxDockRestoreBars(
      child: CruxIdeLayout(
        layout: _SimcruxIdePanelLayout(state),
        sink: _SimcruxIdePanelLayoutSink(notifier),
        leftMinSize: PaneSize.pixel(160),
        rightMinSize: PaneSize.pixel(200),
        bottomMinSize: PaneSize.pixel(80),
        // Without a floor for the centre, the log pane's divider could be
        // dragged all the way to the top of the window: the dashboard kept
        // being handed less height than its own chrome needs and reported
        // the shortfall as a striped overflow banner instead of the drag
        // simply stopping. 200 px keeps the results table's header plus a
        // few rows on screen — the point past which dragging further tells
        // the user nothing.
        centerMinSize: PaneSize.pixel(200),
        leftBuilder: (ctx, _) =>
            testBrowserBuilder?.call(ctx) ??
            _placeholder(ctx, l10n.panelTestBrowserPlaceholder),
        centerBuilder: (ctx, _) =>
            runResultsBuilder?.call(ctx) ??
            _placeholder(ctx, l10n.panelRunResultsPlaceholder),
        rightBuilder: (ctx, _) =>
            runDetailsBuilder?.call(ctx) ??
            _placeholder(ctx, l10n.panelRunDetailsPlaceholder),
        bottomBuilder: (ctx, _) =>
            logPanelBuilder?.call(ctx) ??
            _placeholder(ctx, l10n.panelLogStreamPlaceholder),
      ),
    );
  }

  Widget _placeholder(BuildContext context, String label) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.all(12),
      alignment: Alignment.topLeft,
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Read-side adapter: SimCrux's [PanelLayoutState] → [IdePanelLayout]
/// (test browser→left, run details→right, log panel→bottom; fraction sizes).
class _SimcruxIdePanelLayout implements IdePanelLayout {
  const _SimcruxIdePanelLayout(this._state);

  final PanelLayoutState _state;

  @override
  bool get leftVisible => _state.testBrowserVisible;

  @override
  PaneSize? get leftSize => PaneSize.fraction(_state.testBrowserFraction);

  @override
  bool get rightVisible => _state.runDetailsVisible;

  @override
  PaneSize? get rightSize => PaneSize.fraction(_state.runDetailsFraction);

  @override
  bool get bottomVisible => _state.logPanelVisible;

  @override
  PaneSize? get bottomSize => PaneSize.fraction(_state.logPanelFraction);
}

/// Write-side adapter: drag-to-collapse → the SimCrux [PanelLayoutNotifier].
///
/// Only visibility is persisted; the size setters are no-ops because SimCrux
/// does not persist drag-resize, only visibility — preserving the exact
/// pre-migration behavior.
class _SimcruxIdePanelLayoutSink implements IdePanelLayoutSink {
  const _SimcruxIdePanelLayoutSink(this._notifier);

  final PanelLayoutNotifier _notifier;

  @override
  void setLeftVisible({required bool visible}) =>
      unawaited(_notifier.setTestBrowserVisible(visible: visible));

  @override
  void setRightVisible({required bool visible}) =>
      unawaited(_notifier.setRunDetailsVisible(visible: visible));

  @override
  void setBottomVisible({required bool visible}) =>
      unawaited(_notifier.setLogPanelVisible(visible: visible));

  @override
  void setLeftSize(double pixels) {
    // SimCrux does not persist drag-resize; visibility only.
  }

  @override
  void setRightSize(double pixels) {
    // SimCrux does not persist drag-resize; visibility only.
  }

  @override
  void setBottomSize(double pixels) {
    // SimCrux does not persist drag-resize; visibility only.
  }
}
