// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_telemetry/crux_telemetry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/flow/flow_handoff_launcher.dart';

/// The app's [FlowHandoffLauncher], recording `flow.handoff.launched` and
/// `flow.tool.missing` through the consented telemetry service. Tests
/// override it with a launcher whose starter records instead of spawning.
final Provider<FlowHandoffLauncher> flowHandoffLauncherProvider =
    Provider<FlowHandoffLauncher>(
      (ref) =>
          FlowHandoffLauncher(telemetry: ref.watch(telemetryServiceProvider)),
    );
