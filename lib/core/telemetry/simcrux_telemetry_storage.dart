// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// SimCrux's persistence adapter for the two per-installation telemetry
/// values — the consent decision and the installation id.
///
/// Both live in `SharedPreferences` under the suite-fixed keys
/// [kTelemetryConsentKey] and [kTelemetryInstallationIdKey], **outside**
/// `AppSettings`. That is deliberate: `AppSettings` is the user's preference
/// document, the thing they copy to a second machine or check into a repo
/// beside `simcrux.yaml`, and neither of these values may travel that way.
/// Consent is a property of this installation, and the installation id is what
/// makes "distinct installations" countable — an id that arrived with a copied
/// settings file would make two machines look like one.
///
/// It is also what makes the `--ci` consent rule implementable at all: a
/// headless run reads the *same* two keys the GUI wrote, so "has the GUI on
/// this machine consented" is a plain preferences read rather than a second
/// consent channel that could drift from the first.
///
/// Every method **fails soft**. `crux_telemetry` never throws into a feature
/// flow, and this adapter sits underneath that promise: an unreadable store
/// reads as "never answered", which collects nothing, and an unwritable one
/// loses the decision rather than the frame.
class SimcruxTelemetryStorage extends TelemetryStorage {
  /// Creates the adapter. Stateless — `SharedPreferences.getInstance()` is
  /// itself cached by the plugin.
  const SimcruxTelemetryStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return (await SharedPreferences.getInstance()).getString(key);
    } on Object catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await (await SharedPreferences.getInstance()).setString(key, value);
    } on Object catch (_) {
      // Losing a preference write is not worth surfacing anything to anyone.
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      await (await SharedPreferences.getInstance()).remove(key);
    } on Object catch (_) {
      // Same posture as write: a delete that cannot complete leaves the value
      // in place, and the caller learns about it from the disclosure not
      // appearing rather than from an exception on a testing path.
    }
  }
}
