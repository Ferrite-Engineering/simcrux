// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_project/crux_project.dart' show CruxProjectParser;
import 'package:crux_workspace/crux_workspace.dart' show WorkspaceTab;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/active_tab_container.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';

/// The shared-workspace artifact kind SimCrux **produces**.
///
/// SimCrux is the suite's waveform *producer*: every simulation run that
/// captures a dump upserts a `waveform` record keyed by the design its input
/// (`simcrux.yaml`) directory derives — so a NetCrux → WaveCrux cross-probe
/// that names the same design can resolve and open the VCD even when WaveCrux
/// had nothing open.
const String kCxpWaveformArtifactKind = 'waveform';

/// The shared-workspace artifact kind SimCrux **consumes**.
///
/// SimCrux does not view waveforms; the one design artifact it can open on a
/// peer's behalf is a `source` file. A SimCrux project — a `simcrux.yaml`, or
/// a `<design>.crux-project` naming one — opens as a config tab
/// ([isSimcruxProjectPath]); any other source file opens in the user's
/// editor, through its editor launcher. An inbound `request_open_artifact` /
/// unsatisfiable highlight naming a design resolves this kind.
const String kCxpSourceArtifactKind = 'source';

/// SimCrux's producer short-name stamped into workspace records.
const String kSimcruxWorkspaceProducer = 'simcrux';

/// The directories the user has opened, as CXP §11's containment rule
/// consumes them.
///
/// Three sources, all "the user opened this":
///
/// * the directory of the `simcrux.yaml` every workspace tab points at;
/// * the directory of every entry in the recent-projects list — a config the
///   user opened in this installation, which is what lets a peer's
///   cross-probe land, through the `crux.design_id` fallback, on a design
///   whose tab was closed;
/// * the directories the ACTIVE tab's loaded config names: each test's
///   source files (up to the first glob segment, since a source entry may be
///   a glob) and its include directories, because a design's RTL commonly
///   lives beside, not under, the directory holding `simcrux.yaml`. Only the
///   active tab's config is reachable from root scope, so a background tab
///   contributes its config's directory and not its sources.
///
/// These roots guard every path handed to the editor launcher and the
/// `crux.design_id` fallback. A `request_open_artifact` for a SimCrux
/// project is not rooted: see [kCxpOpenArtifactContainment].
///
/// Read on every containment check rather than snapshotted when the server
/// starts, so a config opened after CXP came up is one the user opened.
Iterable<String> cxpOpenDirectories(Ref ref) {
  final workspace = ref.read(workspaceProvider).value;
  // Through the active tab's container only. `activeConfigProvider` is
  // per-tab, so the root instance is the dormant one, and reading it here
  // would hoist this root provider onto it (the per-tab scope-leak guard
  // catches exactly that). With no tab there is no loaded config to consult;
  // the tab and recent-project directories above still apply.
  final config = activeTabContainerOf(ref)?.read(activeConfigProvider);
  final openedConfigs = <String>[
    for (final tab
        in workspace?.tabs ?? const <WorkspaceTab<SimcruxTabPayload>>[])
      tab.payload.configPath,
    ...?ref.read(appSettingsProvider).value?.recentProjectPaths,
    ?config?.projectFilePath,
  ];
  final roots = <String>{
    for (final file in openedConfigs)
      if (file.isNotEmpty && p.isAbsolute(file)) p.dirname(file),
  };
  if (config != null) {
    for (final suite in config.suites) {
      for (final test in suite.tests) {
        for (final source in test.sources) {
          final directory = _globFreeDirectoryOf(source);
          if (directory != null) roots.add(directory);
        }
        for (final include in test.includeDirs) {
          if (p.isAbsolute(include)) roots.add(p.normalize(include));
        }
      }
    }
  }
  return roots;
}

/// The directory [source] names without any glob: its parent when it is a
/// plain file, and the path up to (not including) the first segment holding
/// a glob metacharacter when it is a pattern. Null for a relative entry.
String? _globFreeDirectoryOf(String source) {
  if (source.isEmpty || !p.isAbsolute(source)) return null;
  final parts = p.split(source);
  final firstGlob = parts.indexWhere(_globSegment.hasMatch);
  if (firstGlob < 0) return p.dirname(source);
  return p.joinAll(parts.take(firstGlob));
}

final RegExp _globSegment = RegExp(r'[*?\[{]');

/// The rooted [CxpPathContainment]: a peer-supplied path must lie inside
/// [cxpOpenDirectories].
///
/// One instance, so the routes that keep the roots apply the *same* rule,
/// which is what CXP §11 requires of an artifact resolved through our own
/// records: [cxpWorkspaceStoreProvider] screens what it resolves for the
/// `crux.design_id` fallback, and the inbound request handler checks the
/// value it is about to hand to an editor argv — for `request_open_source`,
/// for a `request_open_artifact` that names a source file rather than a
/// project, and for the fallback.
///
/// A `request_open_artifact` for a SimCrux project is held to
/// [kCxpOpenArtifactContainment] instead, and so is `LocalCxpServer`'s screen
/// of the wire, because that one rule covers the artifact request's hint as
/// well as `request_open_source`.
final Provider<CxpPathContainment> cxpPathContainmentProvider =
    Provider<CxpPathContainment>(
      (ref) => CxpPathContainment(roots: () => cxpOpenDirectories(ref)),
    );

/// The rule a `request_open_artifact` for a SimCrux project is held to:
/// CXP §11.3's floor, and not the directories the user has opened.
///
/// The floor refuses what a path must never be on its way into an open:
/// empty, relative (resolved against whatever directory SimCrux was launched
/// from), carrying a NUL, or padded with white space. It judges the exact
/// string the caller is about to open, so a padded path is refused rather
/// than trimmed into a different file: trailing white space is part of a
/// POSIX file name.
///
/// ### Why a project open is not rooted
///
/// On this route a rooted rule is secure and useless at once.
/// `request_open_artifact` exists to open a project SimCrux does not have
/// open: the VS Code extension's "Open in SimCrux Desktop" sends it for the
/// workspace's `simcrux.yaml`, which is, as often as not, a config this
/// installation has never opened. Rooted on the open tabs and the recent
/// projects, the rule refused exactly the request the route serves, and the
/// roots bought nothing to pay for that:
///
/// * the sender is already a same-user process. Since CXP 1.2 a peer must
///   present the per-process token SimCrux publishes in its manifest, which
///   only a process that can read this user's application data can do, and
///   such a process can already read — or run — anything SimCrux could be
///   asked to open;
/// * SimCrux parses what this route opens: the config is read and shown as a
///   tab. Nothing runs until the user presses Run, or has turned on
///   auto-run-on-open themselves, and a project file still cannot choose the
///   binary SimCrux spawns or its environment unless the user allowed
///   project-defined tooling in Settings.
///
/// WaveCrux, NetCrux and LintCrux took the same decision for the hand-off
/// that opens their artifacts.
///
/// ### Why an editor launch keeps the roots
///
/// A `source` artifact that is not a SimCrux project goes to the editor
/// launcher, and there the path stops being parsed and becomes an argv
/// element of a program SimCrux does not control (by default
/// `code --goto {file}:{line}:{column}`). That is a different risk, and the
/// argument above does not carry over to it:
///
/// * the launcher substitutes the path into one argv element of a template
///   only the user sets, so a peer cannot add flags — but what the program
///   does with the file it is handed is that program's business. An editor
///   may treat a file as more than text to show (a workspace to open, a link
///   to follow), and SimCrux cannot bound that the way it bounds its own
///   parse;
/// * the roots are half of the gate the launcher was built against.
///   `EditorLauncher` relies on two things: substituting a peer's path into
///   a single argv element, and the inbound handler refusing, before the
///   launcher is reached, any path outside the directories the user has
///   opened. Lifting the roots here would take away half of that gate;
/// * nothing needs the floor there. The hand-off that needs it sends a
///   project, and a peer that wants a source file in an editor can open its
///   own editor.
///
/// So a project opens under this floor and a source file keeps
/// [cxpPathContainmentProvider]'s roots, as does the `crux.design_id`
/// fallback, which resolves an id a peer attached to a cross-probe through
/// store records nobody asked SimCrux to open.
const CxpPathContainment kCxpOpenArtifactContainment = CxpPathContainment();

/// Whether [path] names a SimCrux project a `request_open_artifact` opens as
/// a config tab: a regression config (`.yaml` / `.yml`, the file types File
/// → Open Project accepts), or a `<design>.crux-project` manifest naming
/// one. Any other `source` artifact is a file for the editor.
bool isSimcruxProjectPath(String path) =>
    isSimcruxConfigPath(path) || CruxProjectParser.isManifestPath(path);

/// Whether [path] names a regression config — the file a config tab holds.
bool isSimcruxConfigPath(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.yaml') || lower.endsWith('.yml');
}

/// The shared design→artifact link store.
///
/// A single keep-alive instance rooted at the suite-shared workspace directory
/// (`sharedCxpWorkspaceDirectory()`). Overridable in tests to redirect the
/// store at a temp directory so no test touches the real per-user workspace.
///
/// Carries [cxpPathContainmentProvider] so a record written by a peer — the
/// workspace directory is user-writable, and the sender chose the `design_id`
/// that selects the record — cannot name a file outside the directories this
/// process has open (CXP §11). `request_open_artifact` reads the same records
/// under the floor instead: see [resolveOpenArtifactSourcePath].
final Provider<CxpWorkspaceStore> cxpWorkspaceStoreProvider =
    Provider<CxpWorkspaceStore>(
      (ref) =>
          CxpWorkspaceStore(containment: ref.watch(cxpPathContainmentProvider)),
    );

/// Records the produced waveform at [waveformPath] in the shared workspace so a
/// peer that receives a cross-probe it cannot satisfy locally can resolve and
/// open this dump (SimCrux's key contribution as the suite's producer).
///
/// The record is keyed by [designId], which callers derive from the design's
/// **input** directory (the loaded `simcrux.yaml`'s directory) via the one
/// shared [cxpDesignIdForPath] helper — NOT from the VCD's output directory.
/// That is the join key NetCrux sends, and it lets the wave land anywhere on
/// disk (out-of-tree build dir, tmp) while still being found. The wave's
/// internal top scope (`tb_foo` vs the DUT `foo`) never enters the key; it
/// rides along only as the resolver hint [WorkspaceArtifact.topModule].
///
/// Gated on the CXP server running: with CXP off there is no peer to serve and
/// no reason to write into the shared workspace directory — which also keeps
/// the wide swath of run/open tests from writing into the real per-user
/// workspace. Best-effort throughout: a failed upsert must never break a run,
/// so every error is swallowed.
Future<void> publishWaveformWorkspaceArtifact(
  Ref ref, {
  required String designId,
  required String waveformPath,
  String? topModule,
}) async {
  if (designId.isEmpty || waveformPath.isEmpty) return;
  if (ref.read(cxpServerProvider).value == null) return;
  try {
    await ref
        .read(cxpWorkspaceStoreProvider)
        .upsertArtifact(
          designId: designId,
          kind: kCxpWaveformArtifactKind,
          path: waveformPath,
          producer: kSimcruxWorkspaceProducer,
          topModule: topModule,
          basename: p.basename(waveformPath),
        );
  } on Object {
    // The shared workspace is a courtesy link; never let a workspace write surface as an error
    // on the produce path.
  }
}

/// Resolves the shared-workspace `source` artifact for the design named by
/// [designId], preferring an exact `design_id`+kind
/// match and falling back to the descriptive [topModule]/[basename] hints.
///
/// Returns the absolute path SimCrux should open in its editor, or null when
/// the design has no source artifact recorded.
String? resolveSourceArtifactPath(
  Ref ref,
  String designId, {
  String? topModule,
  String? basename,
}) {
  if (designId.isEmpty) return null;
  final artifact = ref
      .read(cxpWorkspaceStoreProvider)
      .resolveArtifact(
        designId,
        kCxpSourceArtifactKind,
        topModule: topModule,
        basename: basename,
      );
  return artifact?.path;
}

/// Resolves the `source` artifact recorded for [designId] the way
/// `request_open_artifact` needs it: the records [cxpWorkspaceStoreProvider]
/// reads, from the same directory, admitted by [kCxpOpenArtifactContainment]
/// rather than by the rooted rule that store carries.
///
/// Reading them through the rooted store would drop the record for a
/// project SimCrux has never opened, and the request would be refused as
/// though nothing were recorded — the failure [kCxpOpenArtifactContainment]
/// explains. What is resolved here is only a candidate: a source file it
/// names still goes to the editor under the roots. The store keeps no state
/// between reads, so a second view of the directory costs nothing.
///
/// Returns the absolute path of the recorded artifact, or null when the
/// design has no source artifact recorded.
String? resolveOpenArtifactSourcePath(Ref ref, String designId) {
  if (designId.isEmpty) return null;
  final store = ref.read(cxpWorkspaceStoreProvider);
  return CxpWorkspaceStore(
    workspaceDirectory: store.workspaceDirectory,
    ttl: store.ttl,
    containment: kCxpOpenArtifactContainment,
  ).resolveArtifact(designId, kCxpSourceArtifactKind)?.path;
}

/// Opens the regression config at [configPath] as a workspace tab for a CXP
/// peer, or focuses the tab that already holds it, returning whether it did.
/// The opener the inbound request handler publishes into
/// `CxpProjectOpenHandle`.
///
/// The tab is the one `openConfigAsTab` opens for File → Open Project, and
/// the config joins the recent projects the same way, since the user asked
/// for it (in VS Code). Three things `openConfigAsTab` does are left out on
/// purpose:
///
/// * the manifest swap: the inbound handler has already swapped a
///   `<design>.crux-project` for the config it names and checked the result,
///   so the path it checked is the path opened;
/// * the snack-bar feedback: a peer's request is answered in its ack, and
///   this root-scoped route has no `BuildContext`;
/// * the `project.opened` event: its `source` token names the route in, from
///   a vocabulary the telemetry Worker enforces, and none of those routes is
///   a peer's request. Recording nothing is truer than recording the file
///   picker.
Future<bool> openCxpConfigTab(Ref ref, String configPath) async {
  try {
    unawaited(
      ref.read(appSettingsProvider.notifier).addRecentProject(configPath),
    );
    await ref
        .read(workspaceProvider.notifier)
        .openTab(
          displayName: p.basename(configPath),
          payload: SimcruxTabPayload(configPath: configPath),
        );
    return true;
  } on Object {
    return false;
  }
}
