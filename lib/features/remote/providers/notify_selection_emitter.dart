// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_cxp/crux_cxp.dart';
import 'package:crux_workspace/crux_workspace.dart' as crux;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/features/remote/providers/cross_probe_events_provider.dart';
import 'package:simcrux/features/remote/providers/cxp_server_provider.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';
import 'package:simcrux/features/workspace/domain/simcrux_tab_payload.dart';
import 'package:simcrux/features/workspace/providers/active_tab_container.dart';
import 'package:simcrux/features/workspace/providers/workspace_provider.dart';
import 'package:simcrux/services/remote/cxp/simcrux_cxp_server.dart';
import 'package:simcrux/services/remote/cxp/simcrux_name_resolver.dart';

/// "Anchor" provider whose only purpose is to wire the
/// `notify_selection` emitter into the running app.
///
/// Watch this provider from a root-scope `ProviderScope` (the app
/// bootstrap will keep-alive it) and it will:
///
/// 1. Listen to [selectedTestIdProvider] (per-tab) — broadcast
///    [NotifySelection] with an [ElementKind.test] [ElementId] whenever
///    the active selection changes.
/// 2. Listen to [explicitSourceSelectionProvider] — broadcast
///    [NotifySelection] with an [ElementKind.source] [ElementId]
///    whenever the user navigates the inspector to a source file
///    (e.g. via the "Open Source" action).
///
/// Gated on [cxpServerProvider]: the emitter is dormant when the CXP
/// server is not running. The provider can be `.watch`ed from the
/// cross-probe panel or kept alive by the app root.
final Provider<NotifySelectionEmitter> notifySelectionEmitterProvider =
    Provider<NotifySelectionEmitter>((ref) {
      const resolver = SimCruxNameResolver();
      final emitter = NotifySelectionEmitter(ref: ref, resolver: resolver)
        ..attach();
      ref.onDispose(emitter.detach);
      return emitter;
    });

/// Per-tab provider the inspector populates when the user navigates
/// to a source file. Bridges from the existing "Open Source" action
/// into the CXP emitter without coupling the inspector to crux_cxp.
final NotifierProvider<ExplicitSourceSelectionNotifier, String?>
explicitSourceSelectionProvider =
    NotifierProvider<ExplicitSourceSelectionNotifier, String?>(
      ExplicitSourceSelectionNotifier.new,
    );

/// Notifier backing [explicitSourceSelectionProvider].
class ExplicitSourceSelectionNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  /// Records the user's explicit source navigation. Pass `null` to
  /// clear.
  // ignore: use_setters_to_change_properties
  void select(String? sourcePath) => state = sourcePath;
}

/// Wires SimCrux's selection providers into the CXP server's outbound
/// `notify_selection` stream.
///
/// One emitter per running app; ownership lives in the
/// `Provider` above. Internally uses `ref.listen` so the provider
/// machinery handles dispose / hot-reload correctly.
///
/// **Active-tab routing.** `selectedTestIdProvider` is per-tab
/// (open-core mode) or tab-project-scoped (Pro mode), while this
/// emitter is root-hosted — a root-`ref` listen alone would observe
/// only the dormant root instance and never fire for real tab
/// selections. The emitter therefore additionally tracks the ACTIVE
/// tab (via [workspaceProvider]) and subscribes to the active tab's
/// container, re-attaching whenever the active tab changes. The root
/// listen stays as the empty-workspace fallback (headless tests,
/// pre-hydration startup). `explicitSourceSelectionProvider` is
/// app-global in both modes and keeps the plain root listen.
class NotifySelectionEmitter {
  /// Constructs an emitter bound to [ref] and the given [resolver].
  NotifySelectionEmitter({required this.ref, required this.resolver});

  /// The Riverpod ref the emitter watches against.
  final Ref ref;

  /// Resolver used to canonicalise local references for the wire.
  final NameResolver resolver;

  ProviderSubscription<String?>? _testSub;
  ProviderSubscription<String?>? _sourceSub;
  ProviderSubscription<AsyncValue<crux.Workspace<SimcruxTabPayload>>>?
  _workspaceSub;
  ProviderSubscription<String?>? _activeTabTestSub;
  crux.TabId? _subscribedTabId;

  /// Subscribe to the selection providers. Idempotent — calling twice
  /// without [detach] in between cancels the previous subscriptions
  /// first.
  void attach() {
    detach();
    _testSub = ref.listen<String?>(
      selectedTestIdProvider,
      (previous, next) => _emitTest(previous: previous, next: next),
    );
    _sourceSub = ref.listen<String?>(
      explicitSourceSelectionProvider,
      (previous, next) => _emitSource(previous: previous, next: next),
    );
    // Track the active tab so test-selection changes made inside the
    // per-tab container reach the wire.
    _workspaceSub = ref.listen<AsyncValue<crux.Workspace<SimcruxTabPayload>>>(
      workspaceProvider,
      (_, _) => _rebindActiveTab(),
    );
    _rebindActiveTab();
  }

  /// Cancel the active selection subscriptions.
  void detach() {
    _testSub?.close();
    _sourceSub?.close();
    _workspaceSub?.close();
    _activeTabTestSub?.close();
    _testSub = null;
    _sourceSub = null;
    _workspaceSub = null;
    _activeTabTestSub = null;
    _subscribedTabId = null;
  }

  /// (Re-)subscribes to the active tab container's
  /// `selectedTestIdProvider`. No-op when the active tab is unchanged;
  /// drops the per-tab subscription when no tab is active or the
  /// container managers are not bound.
  void _rebindActiveTab() {
    final activeTabId = ref.read(workspaceProvider).value?.activeTabId;
    if (activeTabId == _subscribedTabId) return;
    _activeTabTestSub?.close();
    _activeTabTestSub = null;
    _subscribedTabId = null;
    if (activeTabId == null) return;
    final tabContainer = activeTabContainerOf(ref);
    if (tabContainer == null) return;
    _subscribedTabId = activeTabId;
    _activeTabTestSub = tabContainer.listen<String?>(
      selectedTestIdProvider,
      (previous, next) => _emitTest(previous: previous, next: next),
    );
  }

  void _emitTest({required String? previous, required String? next}) {
    if (next == null) return;
    if (next == previous) return;
    final id = resolver.toCanonical(kind: ElementKind.test, local: next);
    if (id == null) return;
    _broadcast(
      NotifySelection(elements: <ElementId>[id], displayName: next),
    );
  }

  void _emitSource({required String? previous, required String? next}) {
    if (next == null) return;
    if (next == previous) return;
    final id = resolver.toCanonical(kind: ElementKind.source, local: next);
    if (id == null) return;
    _broadcast(
      NotifySelection(elements: <ElementId>[id], displayName: next),
    );
  }

  void _broadcast(NotifySelection message) {
    // Gate on the "Broadcast selection automatically" setting. When off, the
    // live cross-probe is silenced — selection changes no longer announce to
    // peers (explicit sends / "Debug in WaveCrux" use a different path and are
    // unaffected). Defaults to true if settings have not hydrated yet.
    final autoBroadcast =
        ref.read(appSettingsProvider).value?.broadcastSelectionOnCrossProbe ??
        true;
    if (!autoBroadcast) return;
    final serverAsync = ref.read(cxpServerProvider);
    final server = serverAsync.value;
    if (server == null) return;
    server.broadcast(message);
    ref
        .read(crossProbeEventsProvider.notifier)
        .record(
          CrossProbeEvent(
            timestamp: DateTime.now(),
            direction: CrossProbeDirection.outbound,
            kind: message.kind,
            peerId: '*broadcast*',
            summary: message.displayName,
          ),
        );
  }
}
