// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:simcrux/domain/enums/formal_verdict.dart';

/// The four buckets a formal verdict is shown in, plus Unrecognised.
///
/// | Bucket | Verdict tokens | Property statuses |
/// |---|---|---|
/// | [proved] | `PASS` | proved, reached |
/// | [counterexample] | `FAIL` | counterexample, not reached |
/// | [inconclusive] | `UNKNOWN`, `TIMEOUT` | inconclusive |
/// | [didNotRun] | `ERROR`, `NO_OUTCOME` | did not run |
/// | [unrecognised] | a stored token this build cannot parse | none |
///
/// Inconclusive is never shown in error red: nothing was learned, which is
/// not the same as something being wrong.
enum FormalBucket {
  /// Held over the whole configured bound, or unbounded.
  proved('proved'),

  /// The design is wrong, or a cover was shown unreachable.
  counterexample('counterexample'),

  /// Nothing was learned.
  inconclusive('inconclusive'),

  /// A tooling problem: the check never ran.
  didNotRun('did_not_run'),

  /// A stored verdict this build cannot read. Lands conservative, never in
  /// [proved].
  unrecognised('unrecognised');

  const FormalBucket(this.wireName);

  /// Stable token. Never localize it.
  final String wireName;

  /// The bucket for [verdict].
  static FormalBucket of(FormalVerdict verdict) => switch (verdict) {
    FormalVerdict.pass => FormalBucket.proved,
    FormalVerdict.fail => FormalBucket.counterexample,
    FormalVerdict.unknown || FormalVerdict.timeout => FormalBucket.inconclusive,
    FormalVerdict.error || FormalVerdict.noOutcome => FormalBucket.didNotRun,
  };

  /// The bucket for a stored verdict token, [unrecognised] when
  /// [FormalVerdict.fromWireName] cannot parse it.
  static FormalBucket ofStored(Object? token) {
    final verdict = FormalVerdict.fromWireName(token);
    return verdict == null ? FormalBucket.unrecognised : of(verdict);
  }
}
