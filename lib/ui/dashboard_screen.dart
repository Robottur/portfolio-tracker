import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'holding_screen.dart';
import 'privacy.dart';
import 'status_banner.dart';

const _labels = {
  Period.daily: 'Daily',
  Period.oneMonth: '1M',
  Period.threeMonths: '3M',
  Period.oneYear: '1Y',
  Period.lifetime: 'Lifetime',
};

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.controller,
    required this.onOpenIssues,
  });

  final AppController controller;
  final VoidCallback onOpenIssues;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Period _period = Period.daily;
  bool _refreshing = false;

  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      await widget.controller.refreshPrices(manual: true);
    } on Object {
      // The coordinator records source errors; the banner shows them.
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final prices = c.prices;
      final v = valueHoldings(c.displayReplay.positions, prices.latest);
      final r = c.displayPeriod(_period);
      final enabled = c.prefs.enabledSources.isNotEmpty;
      // shortcut: weekends only; holidays need an exchange calendar
      final closedDay =
          c.today.weekday == DateTime.saturday ||
          c.today.weekday == DateTime.sunday;
      final entries = c.displayIncomplete
          ? <HoldingEntry>[]
          : holdingEntries(c);
      final byClass = <AssetClass, List<HoldingEntry>>{};
      for (final e in entries) {
        byClass.putIfAbsent(e.position.instrument.assetClass, () => []).add(e);
      }
      final big = Theme.of(context).textTheme.headlineMedium;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          StatusBanner(controller: c, onOpenIssues: widget.onOpenIssues),
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: enabled ? '' : 'Enable a price source in Settings',
              child: OutlinedButton.icon(
                onPressed: enabled && !_refreshing ? _refresh : null,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh prices'),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (c.displayIncomplete)
            Text(
              'Unavailable — ledger has ${c.issueCount} '
              '${c.issueCount == 1 ? 'issue' : 'issues'}',
              style: big,
            )
          else if (v.total != null) ...[
            const Text('Portfolio value'),
            Amount('${formatTry(v.total!)} TRY', style: big),
          ] else ...[
            const Text('Known priced holdings'),
            Amount('${formatTry(v.knownValue)} TRY', style: big),
            Text('No price for: ${v.missing.join(', ')}'),
          ],
          const SizedBox(height: 12),
          SegmentedButton<Period>(
            showSelectedIcon: false,
            segments: [
              for (final p in Period.values)
                ButtonSegment(value: p, label: Text(_labels[p]!)),
            ],
            selected: {_period},
            onSelectionChanged: (s) => setState(() => _period = s.first),
          ),
          const SizedBox(height: 8),
          if (_period == Period.daily && closedDay) ...[
            const Text('Market closed'),
            for (final o in v.pricesUsed.values)
              Text('${o.instrumentId}: ${stamp(o)}'),
          ],
          if (c.displayIncomplete)
            const SizedBox.shrink()
          else if (r.unavailableReason != null)
            Text('Gain unavailable: ${r.unavailableReason}')
          else ...[
            if (r.gain != null) Amount(signedTry(r.gain!), style: big),
            const Text('Return % — Modified Dietz estimate'),
            if (r.returnPercent != null)
              Amount(signedPercent(r.returnPercent!))
            else if (r.percentNote != null)
              Text(r.percentNote!),
          ],
          if (r.sinceInception)
            const Text('Since inception; shorter than selected period.'),
          const Divider(),
          if (entries.isEmpty && !c.displayIncomplete)
            const Text('No holdings'),
          for (final cls in byClass.entries) ...[
            Text(cls.key.json, style: Theme.of(context).textTheme.titleMedium),
            for (final e in cls.value)
              HoldingTile(
                entry: e,
                onTap: () => openHolding(context, c, e.position.instrument.id),
              ),
          ],
        ],
      );
    },
  );
}
