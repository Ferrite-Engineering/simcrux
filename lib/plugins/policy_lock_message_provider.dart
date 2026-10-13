// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_settings_ui/crux_settings_ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Resolves the localized sentence a locked setting shows, at a context
/// below the app's localizations.
typedef PolicyLockMessageBuilder = String Function(BuildContext context);

/// Extension point for the sentence every `CruxPolicyLock` in the app shows.
///
/// `SimcruxApp` mounts one `CruxPolicyLockScope` in its `MaterialApp.builder`,
/// above the root navigator, so a locked control in a dialog reads the same
/// sentence as one in Settings. Open core locks nothing from a policy file
/// itself and returns null here, which leaves the shared English sentence
/// ([kCruxPolicyLockNoteEn]). An edition that honours organization policy
/// overrides this with its localized sentence.
final Provider<PolicyLockMessageBuilder?> policyLockMessageProvider =
    Provider<PolicyLockMessageBuilder?>(
      (_) => null,
      name: 'policyLockMessageProvider',
    );

/// The sentence [builder] resolves at [context], or the shared English one.
String policyLockMessage(
  BuildContext context,
  PolicyLockMessageBuilder? builder,
) => builder?.call(context) ?? kCruxPolicyLockNoteEn;
