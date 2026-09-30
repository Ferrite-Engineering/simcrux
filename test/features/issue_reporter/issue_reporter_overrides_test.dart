// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_issue_reporter/crux_issue_reporter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simcrux/features/issue_reporter/providers/issue_reporter_overrides.dart';

void main() {
  group('simcruxIssueReporterOverrides', () {
    ProviderContainer build() {
      final container = ProviderContainer(
        overrides: simcruxIssueReporterOverrides,
      );
      addTearDown(container.dispose);
      return container;
    }

    test('binds a config so the package default never throws', () {
      expect(
        () => build().read(cruxIssueReporterConfigProvider),
        returnsNormally,
      );
    });

    test('files against the SimCrux open-core repository', () {
      final config = build().read(cruxIssueReporterConfigProvider);
      expect(config.productName, 'SimCrux');
      expect(config.repositorySlug, 'Ferrite-Engineering/simcrux');
      expect(config.issueTemplate, 'bug_report.yml');
    });

    test('the slug is the open-core repo and never the beta tracker', () {
      // The tracker moved at the 1.0 launch; the gating flag flips on its own
      // schedule and must not drag the issue routing back to `-beta`.
      expect(simcruxIssueRepositorySlug, 'Ferrite-Engineering/simcrux');
      expect(simcruxIssueRepositorySlug, isNot(contains('-beta')));
    });

    test('the new-issue URL is a well-formed GitHub endpoint', () {
      final config = build().read(cruxIssueReporterConfigProvider);
      expect(config.newIssueUrl.host, 'github.com');
      expect(
        config.newIssueUrl.path,
        '/${config.repositorySlug}/issues/new',
      );
    });

    test(
      'the diagnostics-report seam stays unbound — that report carries a path',
      () {
        // `buildTabDiagnosticsReport` opens with `Config: <projectFilePath>`.
        // Wiring it into the reporter would breach the no-paths contract.
        expect(build().read(cruxIssueDiagnosticsReportProvider), isNull);
      },
    );

    test('the reporter is open to every tier — no overlay data by default', () {
      final provider = build().read(cruxIssueReporterDataProviderProvider);
      expect(provider, isA<NoopCruxIssueReporterDataProvider>());
      expect(
        provider.extraCategories(CruxIssueSessionContext.empty),
        isEmpty,
        reason: 'the Pro State category belongs to the overlay',
      );
    });
  });
}
