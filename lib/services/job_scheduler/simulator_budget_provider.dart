// Copyright 2026 Ferrite Engineering LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:simcrux/services/job_scheduler/simulator_budget.dart';

/// The one [SimulatorBudget] every interactive run draws from.
///
/// Lives in the root container (nothing overrides it per tab), which is what
/// makes it shared. The limit starts at [kDefaultSimulatorBudget]; the
/// settings layer, which owns the user's value, sets `limit` when settings
/// load and whenever the user edits it (see `AppSettingsNotifier`). The
/// headless runner has one run per process and does not use it: there
/// `--max-parallel` is the total.
///
/// Kept apart from [SimulatorBudget] because the headless CLI's import
/// closure reaches that file and must stay free of Flutter
/// (`test/static/headless_cli_closure_guard_test.dart`).
final Provider<SimulatorBudget> simulatorBudgetProvider =
    Provider<SimulatorBudget>(
      (_) => SimulatorBudget(),
      name: 'simulatorBudgetProvider',
    );
