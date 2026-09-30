// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:crux_project/crux_project.dart' show kCruxProjectExtension;
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_workspace/crux_workspace.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/core/app_info/about_providers.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/core/simcrux_url_launcher.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/widgets/open_config_tab.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';
import 'package:simcrux/shared/widgets/glowing_app_icon.dart';

/// SimCrux's recent-configs / recent-sessions / primary-actions content
/// for [`EmptyCanvasState`].
///
/// Rendered by the `PaneHost.emptyCanvasContent` slot when the
/// workspace has zero tabs. Replaces the legacy Welcome screen with a
/// workspace-aware empty state — opening a config from here adds a tab
/// to the current workspace rather than navigating to a route.
class EmptyCanvasContent extends ConsumerWidget {
  /// Creates an [EmptyCanvasContent] widget.
  const EmptyCanvasContent({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final settingsAsync = ref.watch(appSettingsProvider);
    // The running version, shown as a muted line under the subtitle. On web
    // there is no native menu bar, so this is the only always-visible place a
    // user can read the version without knowing the palette / overflow About
    // entry points. Resolves in milliseconds; renders nothing until then.
    final version = ref.watch(aboutBuildInfoProvider).value?.version;

    return EmptyCanvasState(
      header: const GlowingAppIcon(size: 72),
      title: l10n.emptyCanvasTitle,
      subtitle: l10n.emptyCanvasSubtitle,
      versionLabel: version == null ? null : l10n.emptyCanvasVersion(version),
      recentFilesSection: _RecentConfigsSection(settingsAsync: settingsAsync),
      primaryActions: [
        FilledButton.icon(
          onPressed: () => _openConfig(context, ref),
          icon: const Icon(Icons.folder_open),
          label: Text(l10n.emptyCanvasOpenConfig),
        ),
        OutlinedButton.icon(
          onPressed: () => _openSession(context, ref),
          icon: const Icon(Icons.history_outlined),
          label: Text(l10n.emptyCanvasOpenSession),
        ),
        OutlinedButton.icon(
          onPressed: () => _openWorkspace(context, ref),
          icon: const Icon(Icons.dashboard_outlined),
          label: Text(l10n.emptyCanvasOpenWorkspace),
        ),
      ],
      // What the other three products do for someone who is here, looking at
      // a regression. Above the suite line, which is the quieter version of
      // the same statement.
      peers: CruxSuitePeers(
        heading: l10n.emptyCanvasPeersHeading,
        entries: [
          CruxSuitePeerEntry(
            product: CruxSuiteProduct.waveCrux,
            blurb: l10n.emptyCanvasPeerWaveCrux,
          ),
          CruxSuitePeerEntry(
            product: CruxSuiteProduct.netCrux,
            blurb: l10n.emptyCanvasPeerNetCrux,
          ),
          CruxSuitePeerEntry(
            product: CruxSuiteProduct.lintCrux,
            blurb: l10n.emptyCanvasPeerLintCrux,
          ),
        ],
        onOpenPeer: (peer) => unawaited(
          simcruxLaunchUrl(Uri.parse(HelpUrls.suitePeer(peer.slug))),
        ),
      ),
      footer: CruxSuiteFooter(
        label: l10n.emptyCanvasSuiteFooter,
        onTap: () => unawaited(simcruxLaunchUrl(Uri.parse(HelpUrls.suiteHome))),
      ),
    );
  }

  Future<void> _openConfig(BuildContext context, WidgetRef ref) async {
    final l10n = L10N.of(context);
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        // A `<design>.crux-project` suite design manifest opens the
        // `simulation` config it names.
        allowedExtensions: const ['yaml', 'yml', kCruxProjectExtension],
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showCruxErrorSnack(context, l10n.emptyCanvasOpenFailed('$error'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    await _openConfigAtPath(context, ref, path, source: 'yaml');
  }

  Future<void> _openSession(BuildContext context, WidgetRef ref) async {
    final l10n = L10N.of(context);
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['simcrux-session'],
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showCruxErrorSnack(context, l10n.emptyCanvasOpenFailed('$error'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    // .simcrux-session is the per-tab session export; the underlying
    // config path is carried inside it (SimcruxTabPayload.configPath).
    // The session loader is not wired into the workspace, so the
    // session-open path opens the bare config the session refers to;
    // inspector selection / filters in the session are not applied.
    await _openConfigAtPath(context, ref, path, source: 'session');
  }

  Future<void> _openWorkspace(BuildContext context, WidgetRef ref) async {
    final l10n = L10N.of(context);
    final FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['simcrux-workspace'],
      );
    } on Object catch (error) {
      if (!context.mounted) return;
      showCruxErrorSnack(context, l10n.emptyCanvasOpenFailed('$error'));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    if (!context.mounted) return;
    await ref.read(workspaceProvider.notifier).loadFrom(path);
  }

  /// Opens [path] as a workspace tab and records how the user got here.
  ///
  /// [source] is required rather than defaulted precisely because this helper
  /// is shared by routes with different answers — the Open Config picker and
  /// the Open Session picker. A default would silently attribute one to the
  /// other, which is the failure the `project.opened` counter exists to avoid.
  Future<void> _openConfigAtPath(
    BuildContext context,
    WidgetRef ref,
    String rawPath, {
    required String source,
  }) => openConfigAsTab(
    ref: ref,
    context: context,
    rawPath: rawPath,
    source: source,
  );
}

class _RecentConfigsSection extends ConsumerWidget {
  const _RecentConfigsSection({required this.settingsAsync});

  final AsyncValue<dynamic> settingsAsync;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);

    return settingsAsync.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, _) => Text(
        l10n.emptyCanvasNoRecentConfigs,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
      data: (settings) {
        // Reading recentProjectPaths / recentSessionPaths via the
        // dynamic AsyncValue.data avoids forcing this widget to import
        // AppSettings just to view its two list fields — keeps the
        // widget testable with a minimal fake.
        // ignore: avoid_dynamic_calls
        final recentProjects = (settings.recentProjectPaths as List)
            .cast<String>();
        // Same rationale as the recentProjects line directly above.
        // ignore: avoid_dynamic_calls
        final recentSessions = (settings.recentSessionPaths as List)
            .cast<String>();

        final children = <Widget>[];
        if (recentProjects.isEmpty) {
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                l10n.emptyCanvasNoRecentConfigs,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        } else {
          children
            ..add(
              Text(
                l10n.emptyCanvasRecentConfigsHeading,
                style: theme.textTheme.titleSmall,
              ),
            )
            ..add(const SizedBox(height: 8))
            // Bounded + scrollable so a long recents list can never push
            // the primary Open… actions below the card: the heading and
            // buttons stay fixed and only the list scrolls (visible
            // desktop scrollbar). The cap only bites once the list
            // outgrows it — short lists render exactly as before.
            ..add(
              _BoundedRecentList(
                children: <Widget>[
                  for (final path in recentProjects)
                    _RecentConfigTile(path: path),
                ],
              ),
            );
        }
        if (recentSessions.isNotEmpty) {
          children
            ..add(const SizedBox(height: 16))
            ..add(
              Text(
                l10n.emptyCanvasRecentSessionsHeading,
                style: theme.textTheme.titleSmall,
              ),
            )
            ..add(const SizedBox(height: 8))
            ..add(
              _BoundedRecentList(
                children: <Widget>[
                  for (final path in recentSessions)
                    _RecentSessionTile(path: path),
                ],
              ),
            );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        );
      },
    );
  }
}

/// A recents list whose height is capped at [_maxHeight]; past the cap
/// it scrolls within its own bounds behind an always-visible desktop
/// scrollbar, keeping the welcome card's chrome (headings + primary
/// action buttons) at a length-independent height.
///
/// A fixed cap rather than `Expanded` because the surrounding
/// `EmptyCanvasState` chrome (crux_workspace) lays its sections out
/// inside a `SingleChildScrollView`, where vertical constraints are
/// unbounded and flex sizing is unavailable.
class _BoundedRecentList extends StatefulWidget {
  const _BoundedRecentList({required this.children});

  /// Three full 56-dp `ListTile` rows plus a sliver of the fourth —
  /// the cut row makes the overflow (and the scrollability) visually
  /// obvious, while keeping the fully-populated welcome card (both
  /// lists at their cap) under an 800px-tall viewport.
  static const double _maxHeight = 180;

  final List<Widget> children;

  @override
  State<_BoundedRecentList> createState() => _BoundedRecentListState();
}

class _BoundedRecentListState extends State<_BoundedRecentList> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: _BoundedRecentList._maxHeight,
      ),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: ListView(
          controller: _controller,
          shrinkWrap: true,
          children: widget.children,
        ),
      ),
    );
  }
}

class _RecentConfigTile extends ConsumerWidget {
  const _RecentConfigTile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.description_outlined),
      title: Text(
        path,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => _open(ref),
    );
  }

  Future<void> _open(WidgetRef ref) async {
    // After the existence check: a recents entry pointing at a deleted file
    // opens nothing, and a counter that ticked there would measure the size of
    // the recents list rather than its usefulness.
    if (!File(path).existsSync()) return;
    unawaited(
      ref.read(appSettingsProvider.notifier).addRecentProject(path),
    );
    ref.read(telemetryServiceProvider).record(projectOpenedEvent('recent'));
    await ref
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: p.basename(path),
          payload: SimcruxTabPayload(configPath: path),
        );
  }
}

class _RecentSessionTile extends ConsumerWidget {
  const _RecentSessionTile({required this.path});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.history_outlined),
      title: Text(
        path,
        overflow: TextOverflow.ellipsis,
      ),
      // Tap handler intentionally absent — session restore semantics
      // under multi-tab need a richer hook (extract payload from the
      // .simcrux-session file rather than just opening the bare config).
    );
  }
}
