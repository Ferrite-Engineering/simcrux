// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

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
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/recent_lists.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/features/workspace/widgets/open_config_tab.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';
import 'package:simcrux/services/telemetry/project_opened_event.dart';
import 'package:simcrux/shared/widgets/glowing_app_icon.dart';

/// SimCrux's recent-projects / primary-actions content
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
      // The suite's shared Recent list: a row per project with a remove
      // button, Clear Recent under them, and a file that has gone greyed and
      // marked missing.
      recentFilesSection: CruxRecentListSection(
        list: recentProjects,
        strings: CruxRecentListStrings.of(context, CruxRecentKind.projects),
        icon: Icons.description_outlined,
        onOpen: (path) => _openRecent(ref, path),
      ),
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

  /// Opens a row of the recent-projects list. Returns whether it opened: a
  /// file that has gone opens nothing, and the shared list drops the entry and
  /// says so.
  Future<bool> _openRecent(WidgetRef ref, String path) async {
    // After the existence check: a recents entry pointing at a deleted file
    // opens nothing, and a counter that ticked there would measure the size of
    // the recents list rather than its usefulness.
    if (!cruxRecentEntryExists(path)) return false;
    // Read before the await: opening the tab replaces this welcome screen.
    final telemetry = ref.read(telemetryServiceProvider);
    await ref
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: p.basename(path),
          payload: SimcruxTabPayload(configPath: path),
        );
    telemetry.record(projectOpenedEvent('recent'));
    return true;
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
