// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// A named mutex that the job scheduler honors so that tests
/// declaring the same lock are not run concurrently.
///
/// Maps to the `resources:` list in `simcrux.yaml`. The canonical use
/// case is hardware-in-the-loop: only one test can hold
/// `fpga_board_0` at a time, regardless of overall parallelism.
@immutable
class ResourceLock {
  /// Creates a [ResourceLock] with the given [name].
  const ResourceLock({required this.name});

  /// User-supplied identifier (e.g. `fpga_board_0`,
  /// `xilinx_license`). Equality and hashing are name-based.
  final String name;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ResourceLock && other.name == name;
  }

  @override
  int get hashCode => name.hashCode;
}
