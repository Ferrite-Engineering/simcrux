// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';

/// SimCrux's binding of the shared telemetry pipeline's one required piece of
/// configuration.
///
/// `productSlug` is the `product` envelope field and must be a member of the
/// ingestion Worker's `PRODUCTS` set — a slug it does not know rejects **every**
/// batch SimCrux ever sends, with a 400 the client never sees. `userAgentName`
/// is the display form, and matches the `User-Agent` the update check already
/// sends (`SimCrux/0.6.0`), so the two outbound calls this app makes stay
/// recognisable as the same application.
///
/// Everything else — the endpoints, the disclosure page, the queue caps, the
/// flush schedule — is suite-wide and left at the package defaults. SimCrux
/// has no reason to differ, and a product that quietly did would be sending to
/// a dataset nobody reads.
final CruxTelemetryConfig simcruxTelemetryConfig = CruxTelemetryConfig(
  productSlug: 'simcrux',
  userAgentName: 'SimCrux',
);
