import 'package:flutter/material.dart';

import '../app/app_controller.dart';

const _titles = ['Dashboard', 'Holdings', 'Transactions', 'Settings'];
const _icons = [
  Icons.dashboard_outlined,
  Icons.account_balance_wallet_outlined,
  Icons.receipt_long_outlined,
  Icons.settings_outlined,
];

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: widget.controller.onResume);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final wide = MediaQuery.sizeOf(context).width >= 840;
    final destinations = [
      for (var i = 0; i < _titles.length; i++) (_icons[i], _titles[i]),
    ];
    // Tasks 15-17 replace these placeholder bodies.
    final body = Center(child: Text(_titles[_index]));
    return Scaffold(
      appBar: AppBar(
        title: Text(c.scan?.descriptor?.name ?? 'Asset Portfolio'),
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
                  onDestinationSelected: (i) => setState(() => _index = i),
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
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final (icon, label) in destinations)
                  NavigationDestination(icon: Icon(icon), label: label),
              ],
            ),
    );
  }
}
