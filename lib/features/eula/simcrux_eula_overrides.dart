// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io' show exit;

import 'package:crux_eula/crux_eula.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/core/eula/simcrux_eula_storage.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where the published agreement lives. The dialog carries the full text
/// already; this is for a user who wants it in a browser tab, to print or to
/// send to someone.
const String kSimcruxEulaUrl = 'https://edacrux.app/eula';

/// Root-scope overrides binding the cross-suite `crux_eula` package to
/// SimCrux's persistence and its quit path.
///
/// Spread into the root `ProviderContainer` ahead of the Pro overlay's
/// overrides under the standard later-wins semantics. The overlay adds nothing
/// here today: acceptance is required at every edition, Open Core included, so
/// there is no Pro-only behaviour to layer on.
final List<Override> simcruxEulaOverrides = <Override>[
  // Where `eula.acceptedVersion` lives. The package default is an in-memory
  // store, which would present the agreement on every launch.
  cruxEulaStorageProvider.overrideWithValue(const SimcruxEulaStorage()),

  // "Read it on edacrux.app". Unbound, the package hides the link rather than
  // rendering one that does nothing.
  cruxEulaOpenOnlineProvider.overrideWithValue(
    () => launchUrl(Uri.parse(kSimcruxEulaUrl)),
  ),

  // Decline ends the session, because EULA section 2.1 leaves no third
  // outcome — the application does not proceed until the agreement is
  // accepted.
  //
  // Not bound on the web, where there is no process to exit and closing the
  // tab is the browser's affordance rather than ours. The package hides the
  // button when this is null, which is the honest surface there: a "quit"
  // that cannot quit is worse than no button.
  if (!kIsWeb) cruxEulaOnDeclineProvider.overrideWithValue(() => exit(0)),
];
