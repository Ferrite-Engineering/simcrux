// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/interfaces/pr_annotation_dispatcher.dart';

/// Extension-point seam for the active [PrAnnotationDispatcher].
///
/// **Open-core default.** Returns [NoopPrAnnotationDispatcher], which
/// answers every batch with zero entries. Every caller of this provider
/// — the dispatch service behind the Pro run-completion hook and the
/// manual dispatch action — is Pro overlay code; the open core has none.
///
/// **Pro override.** The Pro overlay registers a composite
/// dispatcher that fans out to the per-platform implementations
/// (GitHub Checks API, GitLab Notes/Discussions API, generic
/// webhook). The composite picks the correct concrete dispatcher
/// from the active target's
/// `PrAnnotationTarget.platform`. The composite + per-platform
/// implementations live in the Pro overlay.
final Provider<PrAnnotationDispatcher> prAnnotationDispatcherProvider =
    Provider<PrAnnotationDispatcher>(
      (_) => const NoopPrAnnotationDispatcher(),
    );
