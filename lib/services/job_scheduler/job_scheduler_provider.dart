// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/job_scheduler.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/regression_config.dart';
import 'package:simcrux/services/driver_plugin/simulator_driver_plugin_registry_provider.dart';
import 'package:simcrux/services/job_scheduler/dump_retention_provider.dart';
import 'package:simcrux/services/job_scheduler/local_job_scheduler.dart';
import 'package:simcrux/services/job_scheduler/process_reaper_provider.dart';
import 'package:simcrux/services/job_scheduler/waveform_archive_provider.dart';
import 'package:simcrux/services/retry_policy/retry_policy_provider.dart';
import 'package:simcrux/services/simulator/cocotb_driver.dart';
import 'package:simcrux/services/simulator/demo_simulator_driver.dart';
import 'package:simcrux/services/simulator/ghdl_driver.dart';
import 'package:simcrux/services/simulator/icarus_driver.dart';
import 'package:simcrux/services/simulator/riscv_arch_driver.dart';
import 'package:simcrux/services/simulator/riscv_formal_driver.dart';
import 'package:simcrux/services/simulator/simulator_driver_registry.dart';
import 'package:simcrux/services/simulator/verilator_driver.dart';

/// Whether the hidden [DemoSimulatorDriver] (`simulator: demo`) is wired
/// into [simulatorDriverRegistryProvider].
///
/// Off by default — the demo runner is a dev / beta-demo affordance, not
/// a user-facing simulator, so a normal launch never surfaces it in the
/// diagnostics probe or the dashboard's simulator filter. Enabled by the
/// `SIMCRUX_DEMO_RUNNER` environment variable (`1` / `true`), so a demo
/// or dashboard-at-scale walkthrough can populate the desktop dashboard
/// with fast fake rows without a real toolchain. Tests override this
/// provider directly rather than mutating the process environment.
final Provider<bool> demoRunnerEnabledProvider = Provider<bool>((ref) {
  final raw = Platform.environment['SIMCRUX_DEMO_RUNNER']?.toLowerCase();
  return raw == '1' || raw == 'true';
});

/// The set of simulator drivers wired into the scheduler.
///
/// [IcarusDriver], [VerilatorDriver], [GhdlDriver] (VHDL),
/// [CocotbDriver] (Python testbenches wrapping any of the above) and the
/// two RISC-V drivers. The Pro overlay registers vendor drivers via its
/// Riverpod overrides.
///
/// Threads
/// [simulatorDriverPluginRegistryProvider] in so the runner
/// (`LocalJobScheduler`) resolves plugin-contributed drivers through
/// the registry's `resolveDriverFor` async hook. Built-ins win on
/// name collision; the precedence rule is enforced inside
/// `SimulatorDriverRegistry.resolveDriverFor` and verified by unit
/// test. Open-core builds bind the no-op plugin registry so the
/// behavior is built-ins only by default; the Pro overlay's
/// `proOverrides` replaces the plugin registry with the subprocess
/// implementation.
final Provider<SimulatorDriverRegistry> simulatorDriverRegistryProvider =
    Provider<SimulatorDriverRegistry>(
      (ref) {
        // The platform process reaper (POSIX process-tree / Windows
        // taskkill-tree) is shared across every built-in driver so a
        // runaway simulator — or a Cocotb `make → python → vvp` chain — is
        // reaped as a tree, not orphaned. Tests override the
        // [processReaperProvider] with a FakeProcessRunner.
        final reaper = ref.watch(processReaperProvider);
        final drivers = <String, SimulatorDriver>{
          'icarus': IcarusDriver(reaper: reaper),
          'verilator': VerilatorDriver(reaper: reaper),
          'ghdl': GhdlDriver(reaper: reaper),
          'cocotb': CocotbDriver(reaper: reaper),
          // RISC-V compatibility. Registered unconditionally and **never**
          // tier-gated: the compatibility verdict is open core, forever.
          // Note this also means `simulatorVersionsProvider` will probe the
          // RISC-V toolchain when the issue reporter opens — that provider
          // is lazy and never warmed at startup, so an app launch pays
          // nothing for it.
          RiscvArchDriver.kId: RiscvArchDriver(reaper: reaper),
          // The bounded-proof driver, on the same terms: a formal
          // property's pass/fail is correctness and is never gated. The
          // Pro formal dashboard is the analysis layer over these rows.
          RiscvFormalDriver.kId: RiscvFormalDriver(reaper: reaper),
        };
        // The hidden no-op demo runner, off unless the
        // `SIMCRUX_DEMO_RUNNER` gate is set. It spawns no process, so a
        // project whose tests declare `simulator: demo` fills the desktop
        // dashboard with fast fake rows without a real toolchain.
        if (ref.watch(demoRunnerEnabledProvider)) {
          drivers[DemoSimulatorDriver.kId] = const DemoSimulatorDriver();
        }
        return SimulatorDriverRegistry(
          drivers,
          pluginRegistry: ref.watch(simulatorDriverPluginRegistryProvider),
        );
      },
    );

/// Max distinct simulator-binary configurations for which
/// [JobSchedulerCache] retains a scheduler. Beyond this the
/// least-recently-used entry is evicted.
const int kJobSchedulerCacheSize = 4;

/// Bounded cache of [JobScheduler]s keyed by the part of a
/// [RegressionConfig] the scheduler actually consumes — its
/// `simulators:` block.
///
/// A `Provider.family` keyed on the whole [RegressionConfig] grew one
/// retained scheduler per *edit* of the project file (every keystroke
/// in the config editor mints a new, value-unequal config), and each
/// retained scheduler pinned its finished runs' event sinks and driver
/// handles. Keying on the simulator-binary signature also keeps
/// [JobScheduler.cancel] reachable across an unrelated config edit:
/// the in-flight run stays on the same scheduler instance.
class JobSchedulerCache {
  /// Creates a cache that builds schedulers via [_build].
  JobSchedulerCache(this._build);

  final JobScheduler Function(RegressionConfig) _build;

  /// Insertion-ordered so `keys.first` is the least-recently-used.
  final Map<String, JobScheduler> _entries = <String, JobScheduler>{};

  /// Number of retained schedulers. Exposed for tests and diagnostics.
  int get size => _entries.length;

  /// Returns the scheduler for [config], building (and caching) one on
  /// first use.
  JobScheduler schedulerFor(RegressionConfig config) {
    final key = _keyFor(config);
    final existing = _entries.remove(key);
    if (existing != null) {
      // Re-insert to refresh LRU position.
      _entries[key] = existing;
      return existing;
    }
    final built = _build(config);
    _entries[key] = built;
    while (_entries.length > kJobSchedulerCacheSize) {
      _entries.remove(_entries.keys.first);
    }
    return built;
  }

  static String _keyFor(RegressionConfig config) {
    final entries = config.simulatorBinaries.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return entries
        .map(
          (e) =>
              '${e.key} ${e.value.source.name} '
              '${e.value.customPath} '
              '${_sortedPairs(e.value.extraEnv)} '
              '${_sortedPairs(e.value.options)}',
        )
        .join('|');
  }

  static String _sortedPairs(Map<String, String> map) {
    final pairs = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return pairs.map((e) => '${e.key}=${e.value}').join(',');
  }
}

/// The active [JobSchedulerCache].
///
/// Callers resolve a scheduler with
/// `ref.read(jobSchedulerProvider).schedulerFor(config)`. The long-lived
/// global state (driver instances) is provided by
/// [simulatorDriverRegistryProvider]. Concurrency is per run, not global:
/// each `RegressionRequest` carries its own `concurrency`, which the
/// scheduler enforces with a semaphore of its own.
final Provider<JobSchedulerCache> jobSchedulerProvider =
    Provider<JobSchedulerCache>((ref) {
      final driverRegistry = ref.watch(simulatorDriverRegistryProvider);
      // Wire the active retry policy into the scheduler. Open-core binds
      // `NoopRetryPolicy` (no retries); the Pro overlay overrides
      // `retryPolicyProvider` with `FlakyRetryPolicy`, which reruns
      // flaky-classified tests. Without this the scheduler falls back to
      // its `NoopRetryPolicy` default and the Pro override never reaches
      // the run loop.
      final retryPolicy = ref.watch(retryPolicyProvider);
      final dumpRetentionPolicy = ref.watch(dumpRetentionPolicyProvider);
      // Durable archive (+ its own bounded budget) into which passing tests'
      // waveform dumps are relocated before their temp work dirs are swept, so
      // "Debug in WaveCrux" / the inspector can still open them.
      final waveformArchive = ref.watch(waveformArchiveProvider);
      final passingWaveformRetentionPolicy = ref.watch(
        passingWaveformRetentionPolicyProvider,
      );
      return JobSchedulerCache(
        (config) => LocalJobScheduler(
          driverRegistry: driverRegistry,
          config: config,
          retryPolicy: retryPolicy,
          dumpRetentionPolicy: dumpRetentionPolicy,
          passingWaveformArchive: waveformArchive,
          passingWaveformRetentionPolicy: passingWaveformRetentionPolicy,
        ),
      );
    });

/// The factory the **headless** runner builds its scheduler with.
///
/// A seam, and the reason it is separate from [jobSchedulerProvider] is worth
/// stating: the interactive cache also threads the retry policy and the
/// passing-waveform archive, which the `--ci` path does not use. Pointing
/// `--ci` at that cache would have been a shorter diff and would have quietly
/// given every CI job Pro's auto-retry — a real behaviour change smuggled in
/// as plumbing.
///
/// Dump retention is the exception, and deliberately shared: without it a
/// failing test's work dir (and its waveform) is never pruned, so a
/// long-lived self-hosted runner fills `$TMPDIR/runs/` night after night.
/// [dumpRetentionPolicyProvider]'s default (50 failure dirs, 2 GiB) exists to
/// bound exactly that.
///
/// What it buys is the thing `--ci` could not do: a Pro overlay override
/// reaches the headless scheduler. The Pro overlay binds
/// `TemplatedJobScheduler` here when the signed policy file names a
/// distributed backend, which is what makes "distributed execution" mean
/// anything in the pipeline where a grid is actually used.
///
/// Open core resolves [LocalJobScheduler] and nothing else. No backend
/// vocabulary, no submit/poll/cancel templates and no scheduler binary is
/// named anywhere in this repo — the templated backend is a Pro capability
/// and lives in the overlay.
final Provider<JobScheduler Function(RegressionConfig)>
ciSchedulerFactoryProvider = Provider<JobScheduler Function(RegressionConfig)>((
  ref,
) {
  final driverRegistry = ref.watch(simulatorDriverRegistryProvider);
  final dumpRetentionPolicy = ref.watch(dumpRetentionPolicyProvider);
  return (config) => LocalJobScheduler(
    driverRegistry: driverRegistry,
    config: config,
    dumpRetentionPolicy: dumpRetentionPolicy,
  );
}, name: 'ciSchedulerFactoryProvider');
