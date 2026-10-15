// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The name to show for a test: [name] alone, or [name] with its [seed] when
/// the test is one instance of a seed sweep.
///
/// Every instance of a sweep shares one name, so without the seed a 40-seed
/// sweep reads as 40 identical rows and a particular seed cannot be picked
/// out of the results table or the Tests dock.
String testDisplayName(L10N l10n, String name, int? seed) =>
    seed == null ? name : l10n.dashboardTestNameWithSeed(name, seed);
