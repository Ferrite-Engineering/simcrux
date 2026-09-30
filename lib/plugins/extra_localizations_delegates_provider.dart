// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Open-core extension point through which the Pro/Enterprise overlay
/// contributes additional [LocalizationsDelegate]s without forking
/// `SimcruxApp` / `SimcruxWebApp` or `bootstrap`.
///
/// The open-core default returns an empty list — `SimcruxApp.build` and
/// `SimcruxWebApp.build` each concatenate this list with
/// `L10N.localizationsDelegates` and pass the combined sequence to
/// `MaterialApp.router` / `MaterialApp`. The overlay's `proOverrides`
/// replaces this provider with one that returns Pro-specific delegates
/// (e.g. `L10NPro.delegate`) so widgets in the Pro repo can resolve their
/// own `Localizations.of<T>` lookup.
///
/// Mirrors the WaveCrux pattern in
/// `wavecrux/lib/plugins/extra_localizations_delegates_provider.dart`.
final extraLocalizationsDelegatesProvider =
    Provider<List<LocalizationsDelegate<Object?>>>((_) => const []);
