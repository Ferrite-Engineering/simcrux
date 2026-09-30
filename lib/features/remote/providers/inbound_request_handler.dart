// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/inspector/services/editor_launcher_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/remote/providers/notify_selection_emitter.dart';
import 'package:simcrux/features/remote/services/cxp_workspace_link.dart';
import 'package:simcrux/features/workspace/providers/active_tab_container.dart';
import 'package:simcrux/features/workspace/services/crux_project_resolution.dart';
import 'package:simcrux/services/remote/cxp/cxp_project_open_handle.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';

/// "Anchor" provider that wires the inbound CXP request handler into
/// the running app. Watch from the app root so its inbound stream
/// subscription is kept alive for the app's lifetime.
final Provider<InboundRequestHandler> inboundRequestHandlerProvider =
    Provider<InboundRequestHandler>((ref) {
      final handler = InboundRequestHandler(ref: ref)..attach();
      ref.onDispose(handler.detach);
      return handler;
    });

/// Handles inbound `request_highlight` and `request_open_source`
/// messages by dispatching them to SimCrux's selection providers,
/// dashboard filter, and editor launcher.
///
/// The handler is intentionally thin — every effect goes through an
/// existing per-feature provider so the inbound code path matches the
/// internal code path. The notify_selection emitter then observes the
/// resulting state change and re-broadcasts, completing the round-trip
/// for symmetric peers.
///
/// **Active-tab routing.** `selectedTestIdProvider`,
/// `dashboardFilterProvider`, and `activeConfigProvider` are per-tab
/// (open-core mode) or tab-project-scoped (Pro mode); this handler is
/// root-hosted. Every read/write therefore resolves the ACTIVE tab's
/// container via [activeTabContainerOf] first — writing the root
/// instances would be a silent no-op while the ack still claimed
/// `honored: true`. The direct root-`ref` fallback applies only when
/// no workspace is mounted (headless tests, pre-hydration startup).
class InboundRequestHandler {
  /// Constructs a handler bound to [ref].
  InboundRequestHandler({required this.ref});

  /// Riverpod ref used for reads + writes.
  final Ref ref;

  StreamSubscription<InboundCxpMessage>? _sub;

  /// The handle [attach] published an opener into, and that opener, so
  /// [detach] — which runs in the provider's `onDispose`, where `ref` may not
  /// be used — clears its own and nobody else's.
  CxpProjectOpenHandle? _openHandle;
  Future<bool> Function(String configPath)? _publishedOpener;

  /// Subscribe to the running server's inbound stream, now and whenever it
  /// (re)starts. Called once, from the provider's build.
  ///
  /// The listener is registered before anything else. The app anchors this
  /// handler at startup, while the server is still binding, and a handler
  /// that returned on "no server yet" never registered the listener that
  /// would have picked the server up: no inbound request was dispatched or
  /// acknowledged all session.
  ///
  /// It also publishes the project opener a `request_open_artifact` for a
  /// SimCrux project goes through ([openCxpConfigTab]) into the services-layer
  /// [CxpProjectOpenHandle]. SimCrux's tabs are root-scoped, so opening one
  /// needs the workspace notifier and no widget, and this handler lives as
  /// long as the app does. An opener already published — a test's — is left
  /// in place.
  void attach() {
    detach();
    ref.listen<AsyncValue<SimCruxCxpServer?>>(cxpServerProvider, (_, next) {
      unawaited(_sub?.cancel());
      _sub = next.value?.inbound.listen(_dispatch);
    }, fireImmediately: true);
    final handle = ref.read(cxpProjectOpenHandleProvider);
    if (handle.opener == null) {
      Future<bool> opener(String configPath) =>
          openCxpConfigTab(ref, configPath);
      handle.opener = opener;
      _openHandle = handle;
      _publishedOpener = opener;
    }
  }

  /// Cancel the inbound subscription, and withdraw the opener [attach]
  /// published.
  void detach() {
    unawaited(_sub?.cancel());
    _sub = null;
    final handle = _openHandle;
    if (handle != null && identical(handle.opener, _publishedOpener)) {
      handle.opener = null;
    }
    _openHandle = null;
    _publishedOpener = null;
  }

  void _dispatch(InboundCxpMessage inbound) {
    final msg = inbound.message;
    if (msg is RequestHighlight) {
      unawaited(_handleAndReplyHighlight(inbound, msg));
    } else if (msg is RequestOpenArtifact) {
      unawaited(_handleAndReplyOpenArtifact(inbound, msg));
    } else if (msg is RequestOpenSource) {
      unawaited(
        _handleRequestOpenSource(msg).then((ack) {
          _replyOpenSource(inbound, ack);
          if (ack.honored) unawaited(requestUserAttention());
        }),
      );
    }
  }

  /// Handles an inbound `request_highlight`: applies it locally, and when that
  /// misses falls back to the shared workspace — reads
  /// `crux.design_id` from the message metadata, resolves the design's `source`
  /// artifact, and opens it in the editor. Replies with the ack and requests
  /// user attention on any honored outcome.
  Future<void> _handleAndReplyHighlight(
    InboundCxpMessage inbound,
    RequestHighlight msg,
  ) async {
    var ack = _handleRequestHighlight(msg);
    if (!ack.honored) {
      final opened = await _openDesignSourceFromWorkspace(msg.metadata);
      if (opened) {
        ack = const RequestHighlightAck(
          inReplyTo: '',
          honored: true,
          reason: 'opened design source from the shared workspace',
        );
      }
    }
    _replyHighlight(inbound, ack);
    // An actionable inbound message was applied — nudge the OS's
    // attention affordance without stealing focus. Gated by the user setting
    // via the swappable `windowAttentionRequester` seam, so this is a no-op
    // when the preference is off (and under tests, which have no native side).
    if (ack.honored) unawaited(requestUserAttention());
    // Both outcomes are recorded, and that is the point of the `honored`
    // property: a cross-probe a peer sent and this app could not act on is the
    // failure mode the suite network-effect funnel exists to surface, so
    // dropping it would leave the metric reading healthy exactly when it is
    // not. Nothing about the element, the sender or the ack's `reason` string
    // travels — one direction token and one bool.
    ref
        .read(telemetryServiceProvider)
        .record(
          TelemetryEvent(
            'cxp.crossprobe',
            properties: <String, Object?>{
              'direction': 'inbound',
              'honored': ack.honored,
            },
          ),
        );
  }

  /// Handles an inbound `request_open_artifact`: SimCrux consumes only
  /// `source` artifacts, resolving the concrete file through its shared
  /// workspace store (preferring that over the sender's hint path, whose
  /// absolute path may not exist on this machine's layout), opening it, and
  /// requesting attention. A SimCrux project opens as a config tab
  /// ([_openProjectForPeer]); any other source file opens in the user's
  /// editor ([_openSourceInEditor]). Acks honored=false with a reason when
  /// the kind is not `source`, nothing is recorded or hinted, the path is
  /// refused, or the open fails.
  Future<void> _handleAndReplyOpenArtifact(
    InboundCxpMessage inbound,
    RequestOpenArtifact msg,
  ) async {
    final ack = await _handleRequestOpenArtifact(msg);
    final server = ref.read(cxpServerProvider).value;
    if (server != null) {
      server.sendTo(
        inbound.from.peerId,
        RequestOpenArtifactAck(
          inReplyTo: inbound.envelope.messageId,
          honored: ack.honored,
          reason: ack.reason,
        ),
      );
    }
    if (ack.honored) unawaited(requestUserAttention());
  }

  Future<RequestOpenArtifactAck> _handleRequestOpenArtifact(
    RequestOpenArtifact msg,
  ) async {
    if (msg.artifactKind != kCxpSourceArtifactKind) {
      return RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason:
            'simcrux opens only source artifacts, not "${msg.artifactKind}"',
      );
    }
    // Read under the floor: the rooted store drops the record for a project
    // never opened here, the one "Open in SimCrux Desktop" publishes before
    // it sends. It is only a candidate; which rule it then answers to
    // depends on what it names.
    final path = resolveOpenArtifactSourcePath(ref, msg.designId) ?? msg.path;
    if (path == null) {
      return RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason: 'no source artifact recorded for design "${msg.designId}"',
      );
    }
    // CXP §11's MUST: the same scrutiny as a `file_path` on the wire, on the
    // value about to be opened. That value came either from our own records
    // — selected by a `design_id` the sender chose, in a user-writable
    // directory — or from the sender's hint, so neither is a provenance. The
    // floor applies whichever way the path goes next, on the exact string;
    // the reason travels back in the ack and never repeats the path
    // (CXP §9.11).
    final refusal = kCxpOpenArtifactContainment.refuse(path);
    if (refusal != null) {
      return RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason: refusal,
      );
    }
    return await (isSimcruxProjectPath(path)
        ? _openProjectForPeer(path)
        : _openSourceInEditor(path));
  }

  /// Opens the SimCrux project at [path] as a config tab, through the
  /// services-layer [CxpProjectOpenHandle]: the answer VS Code's "Open in
  /// SimCrux Desktop" asks for. It used to go to the editor launcher like any
  /// other `source` path, so the YAML came back to VS Code as text while the
  /// ack said it was honoured.
  ///
  /// Held to the floor, which [path] has passed, and not to the directories
  /// the user has opened: `kCxpOpenArtifactContainment` says why a project
  /// open may be, and why an editor launch may not.
  ///
  /// A `<design>.crux-project` is swapped here for the config it names, and
  /// the floor judges the swapped path too, so the string checked is the
  /// string opened (CXP §11.3); the opener swaps nothing.
  Future<RequestOpenArtifactAck> _openProjectForPeer(String path) async {
    // A hint can name the sender's path on its own machine layout, or a
    // config since deleted; a tab for it would hold nothing but an error.
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
      return const RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason: 'the artifact is not a file here',
      );
    }
    final String config;
    switch (const CruxProjectResolver().resolve(path)) {
      case NotAManifest():
        config = path;
      case ManifestSimulation(:final configPath):
        config = configPath;
      case ManifestAmbiguous():
        return const RequestOpenArtifactAck(
          inReplyTo: '',
          honored: false,
          reason: 'the design directory holds more than one manifest',
        );
      case ManifestUnusable():
        return const RequestOpenArtifactAck(
          inReplyTo: '',
          honored: false,
          reason: 'the design manifest names no SimCrux config that is here',
        );
    }
    // The floor again, on the swapped path. The manifest planner today only
    // yields absolute, trimmed paths, so this cannot refuse one; it is here
    // so the string opened is a string checked if the planner ever changes.
    if (config != path) {
      final refusal = kCxpOpenArtifactContainment.refuse(config);
      if (refusal != null) {
        return RequestOpenArtifactAck(
          inReplyTo: '',
          honored: false,
          reason: refusal,
        );
      }
    }
    // What a config tab holds. A manifest that names another manifest, or a
    // directory, is not opened as though it were a config.
    if (!isSimcruxConfigPath(config)) {
      return const RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason: 'the design manifest does not name a SimCrux config',
      );
    }
    final opened = await ref.read(cxpProjectOpenHandleProvider).open(config);
    return opened
        ? const RequestOpenArtifactAck(inReplyTo: '', honored: true)
        : const RequestOpenArtifactAck(
            inReplyTo: '',
            honored: false,
            reason: 'SimCrux could not open the project',
          );
  }

  /// Opens a `source` artifact that is not a SimCrux project in the user's
  /// editor — the gate an editor launch has always had, unchanged: the
  /// rooted rule, the directories the user has opened, on the value about to
  /// become an argv element, and `EditorLauncher`'s substitution into a
  /// single element of the template the user set. `kCxpOpenArtifactContainment`
  /// says why the floor a project open is held to is not enough here.
  Future<RequestOpenArtifactAck> _openSourceInEditor(String path) async {
    final refusal = ref.read(cxpPathContainmentProvider).refuse(path);
    if (refusal != null) {
      return RequestOpenArtifactAck(
        inReplyTo: '',
        honored: false,
        reason: refusal,
      );
    }
    final launcher = ref.read(editorLauncherProvider);
    final ok = await launcher.openSource(filePath: path);
    if (ok) return const RequestOpenArtifactAck(inReplyTo: '', honored: true);
    return const RequestOpenArtifactAck(
      inReplyTo: '',
      honored: false,
      reason: 'editor command malformed or failed to launch',
    );
  }

  /// Shared-workspace fallback: resolves `crux.design_id` from [metadata] against
  /// the shared workspace and, if a `source` artifact is recorded for that
  /// design, opens it in the editor. Returns whether one was opened. The join
  /// is one-directional — the consumer trusts the sender's `crux.design_id` and
  /// never re-derives an id from the file it opens.
  Future<bool> _openDesignSourceFromWorkspace(
    Map<String, Object?> metadata,
  ) async {
    final designId = metadata[cxpDesignIdMetadataKey];
    if (designId is! String || designId.isEmpty) return false;
    final path = resolveSourceArtifactPath(ref, designId);
    if (path == null) return false;
    // CXP §11: the record was selected by the sender's `design_id`, so the
    // path gets the wire rule on the value about to be opened.
    if (!ref.read(cxpPathContainmentProvider).allows(path)) return false;
    final launcher = ref.read(editorLauncherProvider);
    return await launcher.openSource(filePath: path);
  }

  /// Reads provider [provider] from the active tab's container when
  /// one is mounted, falling back to the root scope otherwise.
  T _readScoped<T>(ProviderListenable<T> provider) {
    final tab = activeTabContainerOf(ref);
    if (tab != null) return tab.read(provider);
    return ref.read(provider);
  }

  /// Whether [testId] names a test of the active tab's loaded
  /// [RegressionConfig]. False when no config is loaded — an unloaded
  /// project has no test inventory to select against, so the honest
  /// ack for any test id is `honored: false`.
  bool _testExists(String testId) {
    final config = _readScoped<RegressionConfig?>(activeConfigProvider);
    if (config == null) return false;
    for (final suite in config.suites) {
      for (final test in suite.tests) {
        if (test.id == testId) return true;
      }
    }
    return false;
  }

  RequestHighlightAck _handleRequestHighlight(RequestHighlight msg) {
    final element = msg.element;
    const inReplyTo = '';
    switch (element.kind.known) {
      case null:
        // [ElementKind] is an open wire type — a peer on a later
        // protocol revision may send a kind this build does not model.
        // Forward-compatible default: ignore it gracefully with an
        // honest `honored: false`, never throw. Crashing the inbound
        // dispatch on an unrecognised kind would defeat the whole point
        // of the type being open.
        return RequestHighlightAck(
          inReplyTo: inReplyTo,
          honored: false,
          reason: 'unsupported element kind: ${element.kind.name}',
        );

      case KnownElementKind.test:
        // Honest ack: only claim `honored` when the named test exists
        // in the active tab's loaded config AND the selection lands in
        // the active tab's scope. Selecting a nonexistent id would
        // leave the inspector empty while telling the peer it worked.
        if (!_testExists(element.path)) {
          return RequestHighlightAck(
            inReplyTo: inReplyTo,
            honored: false,
            reason: 'test not found in the active project: ${element.path}',
          );
        }
        _readScoped(selectedTestIdProvider.notifier).select(element.path);
        return const RequestHighlightAck(inReplyTo: inReplyTo, honored: true);

      case KnownElementKind.source:
        // Same vocabulary trick as the originator side — if the path
        // looks like a waveform, SimCrux doesn't host a waveform
        // viewer, so reply with a graceful "not supported here".
        // Otherwise treat as a source file the user wants to look at:
        // record an explicit source selection so the inspector can
        // surface it (and the notify_selection emitter re-broadcasts).
        // Root-scoped on purpose: explicitSourceSelectionProvider is
        // app-global in both open-core and Pro modes.
        ref.read(explicitSourceSelectionProvider.notifier).select(element.path);
        return const RequestHighlightAck(inReplyTo: inReplyTo, honored: true);

      case KnownElementKind.signal:
      case KnownElementKind.net:
      case KnownElementKind.port:
        // Filter the results table to tests whose name substring
        // matches the leaf identifier. Best-effort — SimCrux does not
        // yet maintain a signal→test reverse index. The substring
        // match is the cheap approximation.
        final leaf = _leafOf(element.path);
        _readScoped(
          dashboardFilterProvider.notifier,
        ).setTestNameSubstring(leaf);
        return const RequestHighlightAck(inReplyTo: inReplyTo, honored: true);

      case KnownElementKind.instance:
      case KnownElementKind.scope:
        // Filter to tests whose name substring matches the instance /
        // scope leaf identifier — same approximation as above. The
        // instance segment of a hierarchical name is the most likely
        // match against a SimCrux test name (typical convention:
        // tb_<module> for unit tests).
        final leaf = _leafOf(element.path);
        _readScoped(
          dashboardFilterProvider.notifier,
        ).setTestNameSubstring(leaf);
        return const RequestHighlightAck(inReplyTo: inReplyTo, honored: true);

      case KnownElementKind.breakpoint:
        // SimCrux does not yet expose a breakpoint editor surface —
        // the breakpoint mapping is reserved by the resolver so the
        // wire-up is one line when the editor lands. Graceful no.
        return const RequestHighlightAck(
          inReplyTo: inReplyTo,
          honored: false,
          reason: 'breakpoint editor not yet implemented in this build',
        );

      case KnownElementKind.marker:
      case KnownElementKind.rule:
        // SimCrux is not the natural owner of waveform markers
        // (WaveCrux) or rule sites (LintCrux). Decline politely.
        return RequestHighlightAck(
          inReplyTo: inReplyTo,
          honored: false,
          reason: 'simcrux does not own ${element.kind.name} elements',
        );
    }
  }

  Future<RequestOpenSourceAck> _handleRequestOpenSource(
    RequestOpenSource msg,
  ) async {
    // The last gate before a peer's string becomes an editor argv, and the
    // one that keeps it to the directories the user has opened:
    // `LocalCxpServer` screens the wire with the floor only, because its one
    // rule also screens a `request_open_artifact` hint, which must not be
    // rooted (`kCxpOpenArtifactContainment`). A path outside the directories
    // the user has opened is refused here even when it is perfectly absolute
    // (CXP §11), and the reason never repeats it.
    final refusal = ref.read(cxpPathContainmentProvider).refuse(msg.filePath);
    if (refusal != null) {
      return RequestOpenSourceAck(
        inReplyTo: '',
        honored: false,
        reason: refusal,
      );
    }
    final launcher = ref.read(editorLauncherProvider);
    final column = msg.column ?? 1;
    final ok = await launcher.openSource(
      filePath: msg.filePath,
      line: msg.line,
      column: column,
    );
    if (ok) {
      return const RequestOpenSourceAck(inReplyTo: '', honored: true);
    }
    return const RequestOpenSourceAck(
      inReplyTo: '',
      honored: false,
      reason: 'editor command malformed or failed to launch',
    );
  }

  void _replyHighlight(
    InboundCxpMessage inbound,
    RequestHighlightAck ack,
  ) {
    final serverAsync = ref.read(cxpServerProvider);
    final server = serverAsync.value;
    if (server == null) return;
    server.sendTo(
      inbound.from.peerId,
      RequestHighlightAck(
        inReplyTo: inbound.envelope.messageId,
        honored: ack.honored,
        reason: ack.reason,
      ),
    );
  }

  void _replyOpenSource(
    InboundCxpMessage inbound,
    RequestOpenSourceAck ack,
  ) {
    final serverAsync = ref.read(cxpServerProvider);
    final server = serverAsync.value;
    if (server == null) return;
    server.sendTo(
      inbound.from.peerId,
      RequestOpenSourceAck(
        inReplyTo: inbound.envelope.messageId,
        honored: ack.honored,
        reason: ack.reason,
      ),
    );
  }

  String _leafOf(String hierarchicalPath) {
    if (hierarchicalPath.isEmpty) return hierarchicalPath;
    // Strip optional [range] bit slice off the right.
    var p = hierarchicalPath;
    final bracket = p.indexOf('[');
    if (bracket > 0) p = p.substring(0, bracket);
    final lastDot = p.lastIndexOf('.');
    if (lastDot < 0) return p;
    return p.substring(lastDot + 1);
  }
}
