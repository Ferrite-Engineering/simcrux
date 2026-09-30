// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_ide_layout/crux_ide_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/core/help_urls.dart';
import 'package:simcrux/domain/models/test_spec.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/inspector/providers/selected_test_provider.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// SimCrux's test search — the suite's Search surface (⌘/Ctrl+F), which
/// previously showed a "not yet implemented" snackbar while the toolbar,
/// menu, and palette all advertised it. Hosted on the suite-standard
/// [CruxSearchDialog] shell (query field, debounce, ↑/↓/Enter navigation,
/// empty state).
///
/// Searches the ACTIVE tab's regression config by test name, suite, and
/// simulator id; activating a result selects the test — driving the same
/// [selectedTestIdProvider] the test browser and inspector share — and
/// closes.
class SimcruxSearchDialog extends ConsumerStatefulWidget {
  /// Creates the search dialog body.
  const SimcruxSearchDialog({super.key});

  /// Opens the dialog against [tabContainer] — the ACTIVE tab's container,
  /// so the config and selection resolve per-tab even though the dialog
  /// route lives above the tab scope.
  static Future<void> open(
    BuildContext context,
    ProviderContainer tabContainer,
  ) {
    // Re-entrancy guard: Cmd/Ctrl+F auto-repeat or a double-tap on the menu /
    // palette entry must not stack a second search dialog. Guarded inside
    // the opener so every caller is covered.
    return ModalGuard.run(
      'search',
      () => showDialog<void>(
        context: context,
        builder: (_) => UncontrolledProviderScope(
          container: tabContainer,
          child: const SimcruxSearchDialog(),
        ),
      ),
    );
  }

  @override
  ConsumerState<SimcruxSearchDialog> createState() =>
      _SimcruxSearchDialogState();
}

class _SimcruxSearchDialogState extends ConsumerState<SimcruxSearchDialog> {
  List<TestSpec> _search(String query) {
    final config = ref.read(activeConfigProvider);
    if (config == null) return const [];
    final all = [for (final suite in config.suites) ...suite.tests];
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final t in all)
        if (t.name.toLowerCase().contains(q) ||
            t.suiteName.toLowerCase().contains(q) ||
            t.simulatorId.toLowerCase().contains(q))
          t,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    return CruxSearchDialog<TestSpec>(
      title: l10n.searchDialogTitle,
      hintText: l10n.searchDialogHint,
      emptyLabel: l10n.searchDialogNoMatches,
      fieldKey: const ValueKey('simcruxSearchField'),
      // Contextual docs: the results-dashboard guide's test-name search
      // section. SimCrux has no mode chips, so the header row holds only
      // the right-aligned help icon.
      headerBuilder: (headerContext, _) => Align(
        alignment: Alignment.centerRight,
        child: CruxHelpLink(
          url: HelpUrls.resultsDashboard,
          tooltip: L10N.of(headerContext).helpLinkLearnMore,
        ),
      ),
      search: _search,
      onActivateResult: (test) =>
          ref.read(selectedTestIdProvider.notifier).select(test.id),
      rowBuilder:
          (rowContext, test, {required highlighted, required onActivate}) =>
              CruxSearchResultTile(
                key: ValueKey('simcruxSearchResult-${test.id}'),
                title: test.name,
                subtitle: '${test.suiteName} · ${test.simulatorId}',
                leading: const Icon(Icons.science_outlined, size: 18),
                highlighted: highlighted,
                onTap: onActivate,
              ),
    );
  }
}
