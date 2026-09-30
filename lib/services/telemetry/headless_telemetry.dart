// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether a **headless** SimCrux invocation (`--ci`, `export-dashboard`) may
/// transmit telemetry.
///
/// ## The `--ci` rule
///
/// A headless run transmits **only when the stored consent is explicitly
/// `enabled`**. `unset` transmits nothing, and — this is the half that matters
/// — it never prompts.
///
/// Both halves are load-bearing, and for different reasons:
///
///  * **`unset` must not prompt.** A CI job has no one at the keyboard. A
///    first-launch disclosure rendered into a headless run is a build that
///    hangs until the job times out, on a machine nobody is watching. There is
///    no UI on this path at all, so this is guaranteed structurally rather
///    than by a check — but it is the reason the second half cannot be
///    "prompt, then decide".
///  * **`unset` must not transmit.** Silence is not consent. The one place a
///    "collect unless told otherwise" default would be least visible and least
///    defensible is a machine whose user never opened the app, so `unset` on
///    this path is a hard no rather than a deferred yes.
///
/// The consequence is deliberate and worth stating plainly: **a machine that
/// has only ever run `simcrux --ci` never sends anything.** Consent is written
/// by the GUI and by nothing else; a pure build agent has no GUI, so it stays
/// `unset` forever. Headless telemetry therefore only ever describes a
/// developer's own workstation, where the GUI has run and its user has said
/// yes. That is also why the queue can be left for the next launch — see
/// [recordHeadlessTelemetry].
///
/// ## What this is *not*
///
/// It is not `telemetryEnabledProvider`. That provider treats `unset` as
/// enabled under `TELEMETRY_DEV`, which is right for a developer exercising
/// the pipeline through the UI and wrong here for the reason above. What the
/// dev flag *does* still do on this path is select the dataset: a headless
/// `TELEMETRY_DEV` build with stored consent posts to the staging endpoint,
/// exactly as a GUI one does, so end-to-end verification covers `--ci` too.
///
/// [container] must already carry `simcruxTelemetryOverrides`.
Future<bool> headlessTelemetryAllowed(ProviderContainer container) async {
  // The store publishes `unset` synchronously and loads asynchronously. A
  // GUI reads it again on the next frame; a CLI process has no next frame, so
  // reading without waiting here would report `unset` on **every** headless
  // run — a consent rule that always answered "no" would look identical to
  // one that worked, and would be found only by someone wondering why the
  // dataset had no `trigger: ci` rows in it.
  await container.read(telemetryConsentReadyProvider.future);

  final dev = container.read(telemetryDevModeProvider);
  if (!dev && container.read(telemetryBetaPeriodProvider)) return false;

  return container.read(telemetryConsentStoreProvider) ==
      TelemetryConsentState.enabled;
}

/// The [TelemetryService] a headless invocation records against.
///
/// The live service when — and only when — [headlessTelemetryAllowed] says
/// this invocation may transmit; [NoopTelemetryService] otherwise, so the
/// headless call sites record unconditionally exactly as the GUI ones do.
///
/// Returning the no-op **without touching the telemetry graph** matters more
/// than it looks: not reading `telemetryServiceProvider` is what guarantees no
/// `LiveTelemetryService` is constructed, and therefore that a declined or
/// unanswered machine issues zero HTTP requests and starts zero timers from a
/// headless run. A gate that constructed the service and then declined to feed
/// it would still have opened a socket on launch.
///
/// ## Process lifetime: why nothing is flushed here
///
/// A CLI process lives for seconds. The shared service's schedule — flush the
/// previous session's queue on `start()`, then every six hours — means this
/// run's own events are written to the queue file and handed to whatever runs
/// next. Nothing here awaits a flush, and that is a decision rather than an
/// omission:
///
///  * **The data is not stranded.** Consent is written by the GUI, so a
///    machine recording anything here is a machine that runs the GUI. The next
///    launch's flush picks the queue up. The pure-CI case — where "next launch"
///    would never come — is exactly the case that records nothing at all.
///  * **A build must not wait on our network.** Awaiting a flush would put an
///    HTTPS round trip on the critical path of somebody's CI step, where it
///    can sit behind a corporate proxy for the full 15-second POST timeout, in
///    exchange for data that goes out a few hours later anyway. Telemetry does
///    not get to make a regression slower.
///  * **The queue cannot become disk growth.** It is capped at 2000 events and
///    7 days, dropping the oldest, and a headless run records single digits.
///
/// What *is* guaranteed before the process ends is the **disk** write, not the
/// network one. Disposing the container cancels the service's six-hour timer —
/// without which the isolate would stay alive long after `--ci` set its exit
/// code — and schedules the queue rewrite, which Dart's event loop drains
/// before the process terminates because `bootstrap` returns rather than
/// calling `exit()`. Callers must dispose the container they pass in.
Future<TelemetryService> resolveHeadlessTelemetry(
  ProviderContainer container,
) async {
  if (!await headlessTelemetryAllowed(container)) {
    return const NoopTelemetryService();
  }
  return container.read(telemetryServiceProvider);
}
