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
      final wanted = c.prefs.measure;
      final data = c.holdingsIn(wanted);
      // An unavailable measure leaves every figure in TRY.
      final m = data == null ? Measure.tryNominal : wanted;
      final unavailable = unavailableLine(c, wanted, _period);
      final shown = data ?? c.holdingsIn(Measure.tryNominal)!;
      final v = valueHoldings(shown.$1.positions, shown.$2.latest);
      final r = c.displayPeriodIn(m, _period);
      final enabled = c.prefs.enabledSources.isNotEmpty;
      // shortcut: weekends only; holidays need an exchange calendar
      final closedDay =
          c.today.weekday == DateTime.saturday ||
          c.today.weekday == DateTime.sunday;
      final entries = c.displayIncomplete
          ? <HoldingEntry>[]
          : entriesFrom(shown);
      final real = realGains(c);
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
            Amount(formatMoney(v.total!, m), style: big),
          ] else ...[
            const Text('Known priced holdings'),
            Amount(formatMoney(v.knownValue, m), style: big),
            Text('No price for: ${v.missing.join(', ')}'),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SegmentedButton<Period>(
                showSelectedIcon: false,
                segments: [
                  for (final p in Period.values)
                    ButtonSegment(value: p, label: Text(_labels[p]!)),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.first),
              ),
              SegmentedButton<Measure>(
                showSelectedIcon: false,
                segments: [
                  for (final k in Measure.values)
                    ButtonSegment(value: k, label: Text(measureNames[k]!)),
                ],
                selected: {wanted},
                onSelectionChanged: (s) => c.setMeasure(s.first).catchError((
                  _,
                ) {
                  // A measure is a convenience; the view keeps its last choice.
                }),
              ),
            ],
          ),
          if (unavailable != null) Text(unavailable),
          if (m == Measure.real)
            if (c.ratesFor(m)?.note case final note?)
              Text("in today's lira, $note"),
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
                signedMoney(r.gain!, m),
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
          if (!c.displayIncomplete) _Comparison(c, _period),
          if (r.sinceInception)
            const Text('Since inception; shorter than selected period.'),
          const Divider(),
          if (entries.isEmpty && !c.displayIncomplete)
            const Text('No holdings')
          else if (entries.isNotEmpty)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
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
                if (!_pie) SortButton(controller: c),
              ],
            ),
          if (_pie && entries.isNotEmpty)
            AllocationPie(entries: entries, measure: m),
          if (!_pie)
            for (final cls in byClass.entries) ...[
              _ClassHeading(cls.key, cls.value, m),
              for (final e in cls.value)
                HoldingTile(
                  entry: e,
                  measure: m,
                  real: real[e.position.instrument.id],
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
  const _ClassHeading(this.cls, this.entries, this.measure);
  final AssetClass cls;
  final List<HoldingEntry> entries;
  final Measure measure;

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
          Amount('· ${formatMoney(total, measure)}', style: style),
        if (unpriced > 0) Text('+ $unpriced unpriced'),
      ],
    );
  }
}

/// The period's return in TRY next to inflation, real and USD.
class _Comparison extends StatelessWidget {
  const _Comparison(this.c, this.period);
  final AppController c;
  final Period period;

  @override
  Widget build(BuildContext context) {
    final t = c.displayPeriod(period);
    final cpi = c.prices.cpi;
    final from = monthKey(t.baseline), to = monthKey(t.end);
    final inflation = cpi.change(from, to);
    String part(String label, Measure m) {
      final r = c.displayPeriodIn(m, period);
      final reason = c.measureUnavailable(m) ?? r.unavailableReason;
      if (reason != null) return '$label: $reason';
      return r.returnPercent == null
          ? '$label: n/a'
          : '$label ${signedPercent(r.returnPercent!)}';
    }

    final note = c.ratesFor(Measure.real)?.note;
    final line = Amount(
      [
        if (t.returnPercent != null)
          'TRY ${signedPercent(t.returnPercent!)}'
        else
          'TRY: ${t.unavailableReason ?? 'n/a'}',
        if (inflation != null)
          'inflation ${signedPercent(inflation * Decimal.fromInt(100))}'
        else
          'inflation: ${cpi.latestMonth == null ? 'Add inflation data in Settings' : 'Inflation missing for ${cpi.firstMissing(from, to) ?? from}'}',
        part('real', Measure.real),
        part('USD', Measure.usd),
      ].join(' · '),
    );
    return note == null
        ? line
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [line, Text(note)],
          );
  }
}
