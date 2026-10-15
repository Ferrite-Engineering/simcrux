// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// A category of change between the most recent run and the one before it,
/// as counted by the dashboard's delta strip.
enum RunDeltaBucket {
  /// Tests that were passing and now fail, time out or are unknown.
  newFailures,

  /// Tests that were failing and now pass.
  fixed,

  /// Tests with no earlier result.
  newTests,

  /// Any other status change.
  otherChanges,
}
