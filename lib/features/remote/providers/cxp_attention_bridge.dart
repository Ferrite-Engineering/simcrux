// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_window_chrome/crux_window_chrome.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/models/app_settings.dart';
import 'package:simcrux/features/settings/providers/app_settings_provider.dart';

/// "Anchor" provider that mirrors [AppSettings.requestAttentionOnCrossProbe]
/// into the global [windowAttentionRequester].
///
/// Watch from the app root so the bridge lives for the app's lifetime. When the
/// preference is on, an actionable inbound cross-probe's `requestUserAttention`
/// reaches the native method-channel backend (dock bounce / taskbar flash);
/// when off, it is swapped for a no-op so the same call becomes silent.
final Provider<CxpAttentionBridge> cxpAttentionBridgeProvider =
    Provider<CxpAttentionBridge>((ref) {
      final bridge = CxpAttentionBridge(ref)..start();
      ref.onDispose(bridge.dispose);
      return bridge;
    });

/// Tracks the attention preference and swaps [windowAttentionRequester]
/// accordingly. Idempotent per value so an unrelated settings change does not
/// churn the global.
class CxpAttentionBridge {
  /// Creates a bridge bound to [_ref]. Call [start] to begin listening.
  CxpAttentionBridge(this._ref);

  final Ref _ref;
  ProviderSubscription<AsyncValue<AppSettings>>? _sub;
  bool? _previous;

  /// Begin listening for settings changes. Idempotent.
  void start() {
    _sub ??= _ref.listen<AsyncValue<AppSettings>>(
      appSettingsProvider,
      _onSettings,
      fireImmediately: true,
    );
  }

  void _onSettings(
    AsyncValue<AppSettings>? previous,
    AsyncValue<AppSettings> next,
  ) {
    final settings = next.value;
    if (settings == null) return;
    final enabled = settings.requestAttentionOnCrossProbe;
    if (enabled == _previous) return;
    _previous = enabled;
    windowAttentionRequester = enabled
        ? const MethodChannelWindowAttentionRequester()
        : const NoopWindowAttentionRequester();
  }

  /// Cancels the settings subscription.
  void dispose() {
    _sub?.close();
    _sub = null;
  }
}
