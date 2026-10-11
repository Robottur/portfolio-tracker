import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'allocation_pie.dart';
import 'asset_labels.dart';
import 'holding_screen.dart';
import 'gain_colors.dart';
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
  bool _pie = false;

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
      // Groups keep the name order; holdings are sorted within each group.
      final byClass = <AssetClass, List<HoldingEntry>>{};
      for (final e in entries) {
        byClass.putIfAbsent(e.position.instrument.assetClass, () => []).add(e);
      }
      for (final k in byClass.keys) {
        byClass[k] = sortEntries(byClass[k]!, c.prefs.holdingSort);
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
          if (_period == Period.daily && closedDay)
            ExpansionTile(
              key: const PageStorageKey('market-closed'),
              tilePadding: EdgeInsets.zero,
              expandedAlignment: Alignment.centerLeft,
              title: const Text('Market closed — last prices'),
              children: [
                for (final o in v.pricesUsed.values)
                  Text('${o.instrumentId}: ${stamp(o)}'),
              ],
            ),
          if (c.displayIncomplete)
            const SizedBox.shrink()
          else if (r.unavailableReason != null)
            Text('Gain unavailable: ${r.unavailableReason}')
          else ...[
            if (r.gain != null)
              Amount(
                signedTry(r.gain!),
                style: gainStyle(context, r.gain!, big),
              ),
            const Text('Return % — Modified Dietz estimate'),
            if (r.returnPercent != null)
              Amount(
                signedPercent(r.returnPercent!),
                style: gainStyle(context, r.returnPercent!),
              )
            else if (r.percentNote != null)
              Text(r.percentNote!),
          ],
          if (r.sinceInception)
            const Text('Since inception; shorter than selected period.'),
          const Divider(),
          if (entries.isEmpty && !c.displayIncomplete)
            const Text('No holdings')
          else if (entries.isNotEmpty)
            Row(
              children: [
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: false, label: Text('List')),
                    ButtonSegment(value: true, label: Text('Pie')),
                  ],
                  selected: {_pie},
                  onSelectionChanged: (s) => setState(() => _pie = s.first),
                ),
                const Spacer(),
                if (!_pie) SortButton(controller: c),
              ],
            ),
          if (_pie && entries.isNotEmpty) AllocationPie(entries: entries),
          if (!_pie)
            for (final cls in byClass.entries) ...[
              _ClassHeading(cls.key, cls.value),
              for (final e in cls.value)
                HoldingTile(
                  entry: e,
                  onTap: () =>
                      openHolding(context, c, e.position.instrument.id),
                ),
            ],
        ],
      );
    },
  );
}

/// Class name with the total of its priced holdings.
class _ClassHeading extends StatelessWidget {
  const _ClassHeading(this.cls, this.entries);
  final AssetClass cls;
  final List<HoldingEntry> entries;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleMedium;
    final priced = entries.where((e) => e.value != null);
    final unpriced = entries.length - priced.length;
    final total = priced.fold(Decimal.zero, (s, e) => s + e.value!);
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(assetClassHeading(cls), style: style),
        if (priced.isNotEmpty)
          Amount('· ${formatTry(total)} TRY', style: style),
        if (unpriced > 0) Text('+ $unpriced unpriced'),
      ],
    );
  }
}
