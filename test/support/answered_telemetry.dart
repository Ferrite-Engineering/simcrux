// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:simcrux/core/telemetry/simcrux_telemetry_config.dart';

/// Telemetry for a test that is not about telemetry: the product's
/// telemetry configuration bound as the app binds it, and a consent answer
/// already on record, in memory, declining.
///
/// Since the public beta ended, whether anything is collected is decided by
/// the user's consent rather than closed by the build. Until the stored
/// answer has been read, the telemetry service resolves a pending one, and
/// that needs the product's configuration, which has no default binding.
/// The app binds it in `simcruxTelemetryOverrides`; a test container that
/// records an event (running a regression, opening a project) without it
/// fails with "cruxTelemetryConfigProvider has no default binding". During
/// the beta nothing reached that far, which is why these containers never
/// needed it.
///
/// The answer is `disabled` so that nothing is collected or sent, and so
/// that a widget tree showing the app does not also show the first-launch
/// disclosure: these tests are about screens a user reaches after answering
/// it. The disclosure's own behaviour and accessibility are tested in
/// `crux_telemetry`, and SimCrux's wiring of it in
/// `test/core/providers/telemetry_service_provider_test.dart`.
///
/// A function rather than a list, so each container gets its own store.
List<Override> answeredTelemetryOverrides() => <Override>[
  cruxTelemetryConfigProvider.overrideWithValue(simcruxTelemetryConfig),
  telemetryStorageProvider.overrideWithValue(
    InMemoryTelemetryStorage(<String, String>{
      kTelemetryConsentKey: TelemetryConsentState.disabled.name,
    }),
  ),
];
