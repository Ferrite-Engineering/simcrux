// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/domain/interfaces/simulator_driver.dart';
import 'package:simcrux/domain/models/simulator_binary_config.dart';

/// The metric a formal result carries when an organization's formal policy
/// refused it: the comma-separated [FormalPolicyRule] tokens it broke.
///
/// The scheduler reads it so that no pass/fail detector can turn a refused
/// result back into a pass.
const String kFormalPolicyViolationMetric = 'formal.policy_violation';

/// One rule of an organization's formal policy a result can break.
enum FormalPolicyRule {
  /// The task read the design with assertions turned off (`-noassert`,
  /// `--ignore-assertions`) and the policy forbids it.
  assertionOptOut('assertion_opt_out'),

  /// The engine line is not one the policy allows.
  solverNotAllowed('solver_not_allowed'),

  /// The run names no engine, so the allow-list cannot be checked.
  solverUnknown('solver_unknown'),

  /// A bounded proof or cover was configured below the policy's floor.
  depthBelowFloor('depth_below_floor'),

  /// A bounded proof or cover whose configured bound could not be read, so
  /// the floor cannot be checked.
  depthUnknown('depth_unknown');

  const FormalPolicyRule(this.token);

  /// The stable token recorded in [kFormalPolicyViolationMetric] and in the
  /// audit line.
  final String token;
}

/// An organization's formal policy, as the product resolved it from the
/// signed policy file.
///
/// Every field is optional; an empty policy changes nothing. The policy is
/// checked against the result a formal driver already produced, from the
/// metrics it recorded: it never re-derives a verdict, it only refuses one
/// the organization does not accept.
@immutable
class FormalOrgPolicy {
  /// Creates the policy.
  const FormalOrgPolicy({
    this.forbidAssertionOptOut = false,
    this.requiredSolvers,
    this.minDepth,
  });

  /// `formalForbidAssertionOptOut`.
  final bool forbidAssertionOptOut;

  /// `formalRequiredSolvers`: allowed engine lines, or null for any.
  final Set<String>? requiredSolvers;

  /// `formalMinDepth`: the least configured bound, or null for none.
  final int? minDepth;

  /// Whether this policy constrains nothing.
  bool get isEmpty =>
      !forbidAssertionOptOut && requiredSolvers == null && minDepth == null;

  /// The rules [metrics] (a formal result's) breaks, in a stable order.
  ///
  /// Reads `formal.assertions_disabled`, `formal.engine`, `formal.solver`,
  /// `formal.mode` and `formal.depth_configured`. A result that is not a
  /// formal one (no `formal.tool`), or one that never reached its tool
  /// (`formal.not_run_reason`), breaks nothing: there is no proof to refuse.
  List<FormalPolicyRule> violationsOf(Map<String, String> metrics) {
    if (isEmpty) return const <FormalPolicyRule>[];
    if (!metrics.containsKey('formal.tool')) return const <FormalPolicyRule>[];
    if (metrics.containsKey('formal.not_run_reason')) {
      return const <FormalPolicyRule>[];
    }
    final out = <FormalPolicyRule>[];
    if (forbidAssertionOptOut &&
        (metrics['formal.assertions_disabled'] ?? '').isNotEmpty) {
      out.add(FormalPolicyRule.assertionOptOut);
    }
    final allowed = requiredSolvers;
    if (allowed != null) {
      final engine = (metrics['formal.engine'] ?? '').trim();
      if (engine.isEmpty) {
        out.add(FormalPolicyRule.solverUnknown);
      } else if (!solverAllowed(
        engine: engine,
        solver: metrics['formal.solver'],
        allowed: allowed,
      )) {
        out.add(FormalPolicyRule.solverNotAllowed);
      }
    }
    final floor = minDepth;
    final mode = metrics['formal.mode'];
    if (floor != null && (mode == 'bmc' || mode == 'cover')) {
      final configured = int.tryParse(metrics['formal.depth_configured'] ?? '');
      if (configured == null) {
        out.add(FormalPolicyRule.depthUnknown);
      } else if (configured < floor) {
        out.add(FormalPolicyRule.depthBelowFloor);
      }
    }
    return out;
  }

  /// Whether the engine line `engine solver` is one [allowed] names. An
  /// entry is an engine line, words separated by spaces and compared
  /// case-insensitively; an entry of fewer words than the line allows every
  /// line it begins (`smtbmc` allows `smtbmc yices` and `smtbmc boolector`).
  static bool solverAllowed({
    required String engine,
    required String? solver,
    required Set<String> allowed,
  }) {
    final line = _words('$engine ${solver ?? ''}');
    for (final entry in allowed) {
      final want = _words(entry);
      if (want.isEmpty || want.length > line.length) continue;
      var match = true;
      for (var i = 0; i < want.length; i++) {
        if (want[i] != line[i]) {
          match = false;
          break;
        }
      }
      if (match) return true;
    }
    return false;
  }

  static List<String> _words(String text) => text
      .toLowerCase()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList(growable: false);

  /// The sentence a refused result carries as its failure message.
  String reasonFor(List<FormalPolicyRule> rules, Map<String, String> metrics) {
    final parts = <String>[
      for (final rule in rules)
        switch (rule) {
          FormalPolicyRule.assertionOptOut =>
            'the task reads the design with assertions turned off '
                '(${metrics['formal.assertions_disabled']})',
          FormalPolicyRule.solverNotAllowed =>
            'the engine `${'${metrics['formal.engine'] ?? ''} '
                    '${metrics['formal.solver'] ?? ''}'.trim()}` is not one '
                'the organization allows',
          FormalPolicyRule.solverUnknown =>
            'the run names no engine, so the allowed engines cannot be '
                'checked',
          FormalPolicyRule.depthBelowFloor =>
            'the bound ${metrics['formal.depth_configured']} is below the '
                "organization's floor of $minDepth",
          FormalPolicyRule.depthUnknown =>
            "the configured bound could not be read, so the organization's "
                'floor of $minDepth cannot be checked',
        },
    ];
    return 'Refused by the organization policy: ${parts.join('; ')}.';
  }

  /// [finished] with this policy applied: unchanged when it breaks no rule,
  /// otherwise a failure carrying the reason and
  /// [kFormalPolicyViolationMetric]. Returns the rules it broke beside it.
  (TestExecutionFinished, List<FormalPolicyRule>) apply(
    TestExecutionFinished finished,
  ) {
    final rules = violationsOf(finished.metrics);
    if (rules.isEmpty) return (finished, rules);
    final reason = reasonFor(rules, finished.metrics);
    return (
      TestExecutionFinished(
        status: TestStatus.fail,
        exitCode: finished.exitCode,
        startedAt: finished.startedAt,
        finishedAt: finished.finishedAt,
        waveformPath: finished.waveformPath,
        stdoutPath: finished.stdoutPath,
        stderrPath: finished.stderrPath,
        failureMessage: finished.failureMessage == null
            ? reason
            : '$reason ${finished.failureMessage}',
        killSignal: finished.killSignal,
        effectiveSeed: finished.effectiveSeed,
        metrics: <String, String>{
          ...finished.metrics,
          kFormalPolicyViolationMetric: rules.map((r) => r.token).join(','),
        },
      ),
      rules,
    );
  }
}

/// Called once per result the policy refused, with the test id and the
/// rules it broke: the hook an edition that keeps an audit log records
/// through.
typedef FormalPolicyRefusalHook =
    void Function({
      required String testId,
      required String tool,
      required List<FormalPolicyRule> rules,
    });

/// An organization's formal policy and what to do when it refuses a result.
@immutable
class FormalPolicyEnforcement {
  /// Creates the enforcement.
  const FormalPolicyEnforcement({required this.policy, this.onRefused});

  /// The policy.
  final FormalOrgPolicy policy;

  /// Called for each refused result.
  final FormalPolicyRefusalHook? onRefused;
}

/// A formal driver with an organization's policy applied to every result it
/// reports.
///
/// Everything is forwarded unchanged except the terminal event, which
/// [FormalOrgPolicy.apply] may turn into a failure that names the rules it
/// broke. The verdict itself is never touched: `formal.verdict` is the
/// tool's, and the refusal is a separate fact beside it.
class FormalPolicyEnforcingDriver implements SimulatorDriver {
  /// Wraps [inner].
  FormalPolicyEnforcingDriver(this.inner, this.enforcement);

  /// The driver whose results are checked.
  final SimulatorDriver inner;

  /// The policy and its hook.
  final FormalPolicyEnforcement enforcement;

  @override
  String get id => inner.id;

  @override
  String get displayName => inner.displayName;

  @override
  SimulatorCapabilities get capabilities => inner.capabilities;

  @override
  Future<String?> detectVersion(SimulatorBinaryConfig config) =>
      inner.detectVersion(config);

  @override
  Future<CompileResult> compile(CompileRequest request) =>
      inner.compile(request);

  @override
  Stream<TestExecutionEvent> execute(ExecuteRequest request) =>
      inner.execute(request).map((event) {
        if (event is! TestExecutionFinished) return event;
        final (applied, rules) = enforcement.policy.apply(event);
        if (rules.isNotEmpty) {
          enforcement.onRefused?.call(
            testId: request.test.id,
            tool: event.metrics['formal.tool'] ?? inner.id,
            rules: rules,
          );
        }
        return applied;
      });

  @override
  void cancel(String testId) => inner.cancel(testId);
}
