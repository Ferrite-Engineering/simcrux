// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Derives a fresh execution seed when a [TestSpec] does not pin one.
///
/// A driver that runs a randomized testbench without a user-supplied seed
/// must still record *which* seed it used, or the run cannot be
/// reproduced and a flaky retry cannot replay the failure. This helper
/// derives a 31-bit non-negative seed from the wall clock and a process
/// counter (so two tests dispatched in the same microsecond still get
/// distinct seeds); the driver passes it to the simulator and reports it
/// back via `TestExecutionFinished.effectiveSeed`.
int deriveExecutionSeed() {
  final micros = DateTime.now().microsecondsSinceEpoch;
  final mixed = micros ^ (_seedCounter++ * 0x9E3779B1);
  return mixed & 0x7FFFFFFF;
}

int _seedCounter = 0;

/// The effective seed a driver runs with: the requested [requested] when
/// pinned, otherwise a freshly [deriveExecutionSeed]-derived value.
int resolveExecutionSeed(int? requested) => requested ?? deriveExecutionSeed();
