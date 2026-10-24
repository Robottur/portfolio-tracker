import 'dart:async';

import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import '../platform/folder_access.dart';
import 'dashboard_screen.dart';
import 'holding_screen.dart';
import 'settings_screen.dart';
import 'transactions_screen.dart';

const _titles = ['Dashboard', 'Holdings', 'Transactions', 'Settings'];
const _icons = [
  Icons.dashboard_outlined,
  Icons.account_balance_wallet_outlined,
  Icons.receipt_long_outlined,
  Icons.settings_outlined,
];

class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.controller,
    this.pick = pickRecordFolder,
  });

  final AppController controller;
  final Future<PickedFolder?> Function() pick;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _problemsFirst = false;
  late final AppLifecycleListener _lifecycle;
  late final Timer _prices;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.controller.onResume);
    // Best effort; the coordinator throttles and records source errors.
    _prices = Timer.periodic(
      const Duration(minutes: 5),
      (_) => widget.controller.refreshPrices().ignore(),
    );
  }

  @override
  void dispose() {
    _prices.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _go(int i) => setState(() {
    _index = i;
    _problemsFirst = false;
  });

  // Conflicts are decided in Transactions; every other issue is in Problems.
  void _openIssues() {
    final onlyConflicts = widget.controller.issues.every(
      (i) => i.kind == IssueKind.competingLeaves,
    );
    setState(() {
      _index = onlyConflicts ? 2 : 3;
      _problemsFirst = !onlyConflicts;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final destinations = [
      for (var i = 0; i < _titles.length; i++) (_icons[i], _titles[i]),
    ];
    final body = switch (_index) {
      0 => DashboardScreen(controller: c, onOpenIssues: _openIssues),
      1 => HoldingsView(controller: c, onOpenIssues: _openIssues),
      2 => TransactionsScreen(controller: c),
      _ => SettingsScreen(
        controller: c,
        pick: widget.pick,
        problemsFirst: _problemsFirst,
      ),
    };
    return Scaffold(
      appBar: AppBar(
        title: Text(c.scan?.descriptor?.name ?? 'Portfolio Tracker'),
        actions: [
          IconButton(
            tooltip: 'Privacy mode',
            icon: Icon(c.privacyMode ? Icons.visibility_off : Icons.visibility),
            onPressed: () => c.setPrivacy(!c.privacyMode),
          ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  labelType: NavigationRailLabelType.all,
                  onDestinationSelected: _go,
                  destinations: [
                    for (final (icon, label) in destinations)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        label: Text(label),
                      ),
                  ],
                ),
                Expanded(child: body),
              ],
            )
          : body,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _go,
              destinations: [
                for (final (icon, label) in destinations)
                  NavigationDestination(icon: Icon(icon), label: label),
              ],
            ),
    );
  }
}
