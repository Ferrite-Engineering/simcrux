// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/lifecycle/active_run_registry.dart';
import 'package:simcrux/services/lifecycle/app_exit_coordinator.dart';

/// App-scoped [ActiveRunRegistry].
///
/// Deliberately NOT part of the per-tab override set: every tab's
/// runner must register into the same instance for the exit path to
/// see runs started in background tabs.
final Provider<ActiveRunRegistry> activeRunRegistryProvider =
    Provider<ActiveRunRegistry>((ref) => ActiveRunRegistry());

/// How the app terminates the host process. Production calls
/// `dart:io`'s [exit]; tests override this to record the code.
final Provider<ProcessExitCallback> processExitProvider =
    Provider<ProcessExitCallback>((ref) => exit);

/// App-scoped [AppExitCoordinator] driving the orderly-shutdown path
/// for the Quit action and for OS-initiated termination.
final Provider<AppExitCoordinator> appExitCoordinatorProvider =
    Provider<AppExitCoordinator>(
      (ref) =>
          AppExitCoordinator(registry: ref.watch(activeRunRegistryProvider)),
    );
