// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

/// Log channel for everything the trend store says about itself — a
/// quarantined file, a rebuild from `results.ndjson`.
///
/// A bare constant in its own library so both halves of the conditional
/// export and the rebuild service share one channel name without any of them
/// importing the others. A support conversation filters on this string.
const String kTrendStoreLogName = 'simcrux.trend_store';
