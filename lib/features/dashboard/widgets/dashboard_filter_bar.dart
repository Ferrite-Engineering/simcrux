// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:crux_async/crux_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/domain/enums/test_status.dart';
import 'package:simcrux/features/dashboard/providers/dashboard_providers.dart';
import 'package:simcrux/features/dashboard/widgets/dashboard_status_icon.dart';
import 'package:simcrux/l10n/generated/app_localizations.dart';

/// The horizontal filter bar that sits above the dashboard's results
/// table.
///
/// Two surfaces:
///
/// 1. A free-text "filter by test name" field, debounced into
///    [DashboardFilterNotifier] by the suite's [Debouncer] at its default
///    trailing delay: a burst of keystrokes is one filter update, with the
///    last text typed. Every change to the filter re-derives the dashboard's
///    rows (filter, sort and join over the whole run), so a word typed at
///    speed applies once, when typing settles, and not once per letter.
/// 2. Multi-select [FilterChip]s for status, suite, and simulator.
///    The available chips for suite/simulator are derived from
///    [activeConfigProvider]; status chips come from [TestStatus.values].
///    A chip applies at once; there is nothing to coalesce.
///
/// Clear drops a keystroke still waiting out the debounce, so it cannot land
/// after the reset and undo it.
class DashboardFilterBar extends ConsumerStatefulWidget {
  /// Creates a [DashboardFilterBar].
  const DashboardFilterBar({super.key});

  @override
  ConsumerState<DashboardFilterBar> createState() => _DashboardFilterBarState();
}

class _DashboardFilterBarState extends ConsumerState<DashboardFilterBar> {
  final Debouncer _nameDebouncer = Debouncer();

  @override
  void dispose() {
    _nameDebouncer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10N.of(context);
    final theme = Theme.of(context);
    final filter = ref.watch(dashboardFilterProvider);
    final config = ref.watch(activeConfigProvider);

    final suiteIds = <String>{};
    final simulatorIds = <String>{};
    if (config != null) {
      for (final suite in config.suites) {
        suiteIds.add(suite.name);
        for (final test in suite.tests) {
          simulatorIds.add(test.simulatorId);
        }
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: l10n.dashboardFilterTestNameHint,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (value) => _nameDebouncer.run(
                    () => ref
                        .read(dashboardFilterProvider.notifier)
                        .setTestNameSubstring(value),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: filter.isUnset
                    ? null
                    : () {
                        _nameDebouncer.cancel();
                        ref.read(dashboardFilterProvider.notifier).reset();
                      },
                icon: const Icon(Icons.clear, size: 18),
                label: Text(l10n.dashboardFilterClear),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _FilterChipGroup(
            heading: l10n.dashboardFilterByStatus,
            options: TestStatus.values
                .map(
                  (s) => _ChipOption<TestStatus>(
                    value: s,
                    label: testStatusLabel(l10n, s),
                  ),
                )
                .toList(),
            selected: filter.statuses,
            onToggle: (status) =>
                ref.read(dashboardFilterProvider.notifier).toggleStatus(status),
          ),
          if (suiteIds.isNotEmpty) ...[
            const SizedBox(height: 4),
            _FilterChipGroup(
              heading: l10n.dashboardFilterBySuite,
              options: suiteIds
                  .map((s) => _ChipOption<String>(value: s, label: s))
                  .toList(),
              selected: filter.suites,
              onToggle: (s) =>
                  ref.read(dashboardFilterProvider.notifier).toggleSuite(s),
            ),
          ],
          if (simulatorIds.isNotEmpty) ...[
            const SizedBox(height: 4),
            _FilterChipGroup(
              heading: l10n.dashboardFilterBySimulator,
              options: simulatorIds
                  .map((s) => _ChipOption<String>(value: s, label: s))
                  .toList(),
              selected: filter.simulators,
              onToggle: (s) =>
                  ref.read(dashboardFilterProvider.notifier).toggleSimulator(s),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChipOption<T> {
  _ChipOption({required this.value, required this.label});
  final T value;
  final String label;
}

class _FilterChipGroup<T> extends StatelessWidget {
  const _FilterChipGroup({
    required this.heading,
    required this.options,
    required this.selected,
    required this.onToggle,
  });

  final String heading;
  final List<_ChipOption<T>> options;
  final Set<T> selected;
  final void Function(T value) onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(heading, style: theme.textTheme.labelMedium),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final opt in options)
                FilterChip(
                  label: Text(opt.label),
                  selected: selected.contains(opt.value),
                  onSelected: (_) => onToggle(opt.value),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
