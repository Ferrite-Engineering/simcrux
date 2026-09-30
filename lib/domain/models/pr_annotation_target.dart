// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:meta/meta.dart';

/// Which platform a [PrAnnotationTarget] addresses.
///
/// Each enum value selects a different concrete
/// [PrAnnotationDispatcher] under the Pro overlay:
///
/// - `github` — `GitHubPrAnnotationDispatcher` (Checks API +
///   Issues comments + Pull Requests).
/// - `gitlab` — `GitLabMrAnnotationDispatcher` (Notes + Discussions
///   + Pipelines).
/// - `webhook` — `WebhookPrAnnotationDispatcher` (POSTs the
///   documented JSON payload to a user-supplied URL).
enum PrAnnotationPlatform {
  /// GitHub.com or GitHub Enterprise.
  github,

  /// GitLab.com or self-hosted GitLab.
  gitlab,

  /// Generic webhook receiver (Slack incoming-webhook, custom
  /// integration, internal automation server, etc.).
  webhook,
}

/// Where to send a batch of [PrAnnotation]s.
///
/// Plain immutable value type. The auth token is intentionally kept
/// off the [toString] output and the equality / hashCode
/// implementations include it only via the token's length (so two
/// targets with different tokens are unequal without leaking the
/// token contents into logging or test diff output).
@immutable
class PrAnnotationTarget {
  /// Creates a [PrAnnotationTarget].
  const PrAnnotationTarget({
    required this.platform,
    this.repositoryRef,
    this.prNumber,
    this.authToken,
    this.webhookUrl,
  });

  /// Which platform this target addresses.
  final PrAnnotationPlatform platform;

  /// Repository reference: `owner/repo` for GitHub,
  /// `group/project` (or a numeric project id as a string) for
  /// GitLab. Ignored when [platform] is [PrAnnotationPlatform.webhook].
  final String? repositoryRef;

  /// PR / MR number to annotate. Null for [PrAnnotationPlatform.webhook]
  /// targets (the receiver decides what context to apply).
  final int? prNumber;

  /// Auth token (Bearer-style for GitHub, PRIVATE-TOKEN for GitLab,
  /// optional Bearer for webhook).
  ///
  /// **Important.** Never log or print this field — the [toString]
  /// output below redacts it explicitly. Settings UIs persist
  /// tokens to platform-secure storage; the Pro overlay's settings
  /// section is responsible for that path.
  final String? authToken;

  /// Receiver URL for [PrAnnotationPlatform.webhook]. Null for
  /// GitHub / GitLab targets.
  final String? webhookUrl;

  /// True when the target carries the minimum fields its platform
  /// requires:
  ///
  /// - github / gitlab: `repositoryRef + prNumber + authToken`.
  /// - webhook: `webhookUrl` (authToken optional — webhook
  ///   receivers behind IP allowlisting authenticate by network).
  bool get isComplete {
    switch (platform) {
      case PrAnnotationPlatform.github:
      case PrAnnotationPlatform.gitlab:
        return repositoryRef != null &&
            repositoryRef!.isNotEmpty &&
            prNumber != null &&
            authToken != null &&
            authToken!.isNotEmpty;
      case PrAnnotationPlatform.webhook:
        return webhookUrl != null && webhookUrl!.isNotEmpty;
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrAnnotationTarget &&
          other.platform == platform &&
          other.repositoryRef == repositoryRef &&
          other.prNumber == prNumber &&
          other.authToken == authToken &&
          other.webhookUrl == webhookUrl;

  @override
  int get hashCode => Object.hash(
    platform,
    repositoryRef,
    prNumber,
    // Token length only — keep equality strict without leaking
    // the secret into hash diagnostics.
    authToken?.length,
    webhookUrl,
  );

  /// Token-redacted [toString] for safe logging.
  @override
  String toString() {
    final redactedToken = authToken == null ? 'null' : '<redacted>';
    return 'PrAnnotationTarget(platform: $platform, '
        'repositoryRef: $repositoryRef, prNumber: $prNumber, '
        'authToken: $redactedToken, webhookUrl: $webhookUrl)';
  }
}
