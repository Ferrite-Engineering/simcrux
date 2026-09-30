// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart' show kTelemetryFormFactors;

/// Maps the layout idiom the app **already** uses onto the coarse
/// `form_factor` bucket (`crux_telemetry`'s [kTelemetryFormFactors]).
///
/// This is the one half of the telemetry envelope `crux_telemetry` leaves to
/// the product, and deliberately: the derivation must read the idiom the app
/// actually drew, so telemetry can never disagree with what the user is
/// looking at. A second breakpoint set inside the shared package is exactly
/// how the two would come to disagree.
///
/// **SimCrux has no device-class system, and this function introduces none.**
/// It is desktop-first with a desktop-class web viewer (`CLAUDE.md` → Platform
/// Targets); the same statement is already written down, in code, in
/// `features/beta_expiry/widgets/beta_expiry_metrics.dart`, where WaveCrux's
/// `MobileMetrics.of(context, deviceClass)` lookup collapses to desktop
/// constants for the same reason. So the idiom SimCrux draws has exactly two
/// values and the mapping has exactly two arms. Inventing a width breakpoint
/// here to produce `phone` / `tablet` rows would report a layout SimCrux does
/// not have — a fabricated dimension is worse than a missing one, because a
/// missing one is visible in the data and a fabricated one is not.
///
/// `kIsWeb` wins outright: a browser tab is a browser tab whatever its width,
/// and `web` vs `desktop` is the split the roadmap question ("does the web
/// build earn its maintenance") actually needs. No dimensions are sent, and
/// none are derivable from the buckets.
///
/// If SimCrux ever grows a real phone or tablet layout, this is the single
/// function that changes, and the arm it grows must come from that layout's
/// own idiom enum — never from a `MediaQuery` width read here.
String telemetryFormFactorFor({required bool isWeb}) =>
    isWeb ? 'web' : 'desktop';
