// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simcrux/services/job_scheduler/dump_retention.dart';
import 'package:simcrux/services/job_scheduler/waveform_archive.dart';

/// Overridable directory hint for tests. When null (the default) the archive
/// roots at `<applicationSupportDirectory>/waveforms`. Tests override this to
/// redirect the pool into a temp directory.
final Provider<String?> waveformArchiveDirectoryOverrideProvider =
    Provider<String?>((_) => null);

/// Retention policy for the passing-test waveform archive.
///
/// A **separate** budget from `dumpRetentionPolicyProvider` (the failing
/// work-dir retention) by design: archived passing waveforms and retained
/// failing-test dirs must never evict one another. Waveform dumps are small
/// and the interactive use case only needs the recent handful, so this pool is
/// capped tighter than the failure budget — the 25 most recent passing
/// waveforms under a 512 MiB ceiling.
final Provider<DumpRetentionPolicy> passingWaveformRetentionPolicyProvider =
    Provider<DumpRetentionPolicy>(
      (_) => const DumpRetentionPolicy(
        keepLastNFailures: 25,
        maxTotalBytes: 512 * 1024 * 1024,
      ),
    );

/// The durable [WaveformArchive] into which passing tests' waveform dumps are
/// relocated before their (transient, temp-dir) work directories are swept, so
/// "Debug in WaveCrux" and the inspector's waveform view resolve a file that
/// survives the run — and app restarts.
final Provider<WaveformArchive> waveformArchiveProvider =
    Provider<WaveformArchive>((ref) {
      final override = ref.watch(waveformArchiveDirectoryOverrideProvider);
      return WaveformArchive(
        resolveRoot: () async {
          if (override != null) return p.join(override, 'waveforms');
          final dir = await getApplicationSupportDirectory();
          return p.join(dir.path, 'waveforms');
        },
      );
    });
