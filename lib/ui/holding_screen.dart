import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import 'privacy.dart';
import 'status_banner.dart';

class HoldingEntry {
  HoldingEntry(this.position, this.price);
  final Position position;
  final PriceObservation? price;

  Decimal? get value => price == null ? null : position.quantity * price!.price;
  Decimal? get unrealized => value == null ? null : value! - position.cost;
  Decimal? get unrealizedPercent =>
      unrealized != null && position.cost > Decimal.zero
      ? divide(unrealized! * Decimal.fromInt(100), position.cost)
      : null;
  bool get closed => position.quantity == Decimal.zero;
}

List<HoldingEntry> holdingEntries(AppController c, {bool closed = false}) => [
  for (final p in c.displayReplay.positions.values)
    if (closed || p.quantity > Decimal.zero)
      HoldingEntry(p, c.prices.latest(p.instrument.id)),
]..sort((a, b) => a.position.instrument.id.compareTo(b.position.instrument.id));

class HoldingTile extends StatelessWidget {
  const HoldingTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.selected = false,
  });

  final HoldingEntry entry;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tag = entry.price == null ? null : priceTag(entry.price!);
    return ListTile(
      selected: selected,
      title: Text(
        '${entry.position.instrument.code}${entry.closed ? ' (closed)' : ''}',
      ),
      subtitle: Wrap(
        spacing: 8,
        children: [
          Amount(formatQuantity(entry.position.quantity)),
          if (tag != null) Text(tag),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (entry.value == null)
            const Text('Price missing')
          else
            Amount('${formatTry(entry.value!)} TRY'),
          if (entry.unrealized != null && !entry.closed)
            Amount(signedTry(entry.unrealized!)),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Holdings tab: list with a closed toggle; beside a detail pane when wide.
class HoldingsView extends StatefulWidget {
  const HoldingsView({
    super.key,
    required this.controller,
    required this.onOpenTransactions,
  });
  final AppController controller;
  final VoidCallback onOpenTransactions;

  @override
  State<HoldingsView> createState() => _HoldingsViewState();
}

class _HoldingsViewState extends State<HoldingsView> {
  bool _closed = false;
  String? _selected;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final wide = MediaQuery.sizeOf(context).width >= 840;
      final entries = c.displayIncomplete
          ? <HoldingEntry>[]
          : holdingEntries(c, closed: _closed);
      final list = ListView(
        children: [
          StatusBanner(
            controller: c,
            onOpenTransactions: widget.onOpenTransactions,
          ),
          SwitchListTile(
            title: const Text('Show closed positions'),
            value: _closed,
            onChanged: (v) => setState(() => _closed = v),
          ),
          if (c.displayIncomplete)
            ListTile(
              title: Text(
                'Unavailable — ledger has ${c.issueCount} '
                '${c.issueCount == 1 ? 'issue' : 'issues'}',
              ),
            )
          else if (entries.isEmpty)
            const ListTile(title: Text('No holdings')),
          for (final e in entries)
            HoldingTile(
              entry: e,
              selected: wide && e.position.instrument.id == _selected,
              onTap: () {
                final id = e.position.instrument.id;
                if (wide) {
                  setState(() => _selected = id);
                } else {
                  openHolding(context, c, id);
                }
              },
            ),
        ],
      );
      if (!wide) return list;
      return Row(
        children: [
          SizedBox(width: 420, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: _selected == null
                ? const Center(child: Text('Select a holding'))
                : HoldingDetail(controller: c, instrumentId: _selected!),
          ),
        ],
      );
    },
  );
}

void openHolding(BuildContext context, AppController c, String id) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HoldingScreen(controller: c, instrumentId: id),
      ),
    );

class HoldingScreen extends StatelessWidget {
  const HoldingScreen({
    super.key,
    required this.controller,
    required this.instrumentId,
  });
  final AppController controller;
  final String instrumentId;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(instrumentId)),
    body: HoldingDetail(controller: controller, instrumentId: instrumentId),
  );
}

class HoldingDetail extends StatelessWidget {
  const HoldingDetail({
    super.key,
    required this.controller,
    required this.instrumentId,
  });
  final AppController controller;
  final String instrumentId;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final p = controller.displayReplay.positions[instrumentId];
      if (p == null) return const Center(child: Text('No such holding'));
      final e = HoldingEntry(p, controller.prices.latest(instrumentId));
      final o = e.price;
      final tag = o == null ? null : priceTag(o);
      final history =
          [
            for (final t in controller.displayTransactions)
              if (t.instrument.id == instrumentId) t,
          ]..sort((a, b) {
            final c = b.effectiveDate.compareTo(a.effectiveDate);
            return c != 0 ? c : b.dayOrder.compareTo(a.dayOrder);
          });
      final avg = p.averageCost;
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            '${p.instrument.code} · ${p.instrument.assetClass.json}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          _row('Instrument', Text(instrumentId)),
          _row('Quantity', Amount(formatQuantity(p.quantity))),
          _row('Remaining cost', Amount('${formatTry(p.cost)} TRY')),
          _row(
            'Average cost',
            avg == null ? const Text('—') : Amount(formatQuantity(avg)),
          ),
          _row(
            'Latest price',
            o == null
                ? const Text('Price missing')
                : Wrap(
                    spacing: 8,
                    children: [
                      Amount('${formatQuantity(o.price)} TRY'),
                      Text('${stamp(o)} · ${o.source}'),
                      if (tag != null) Text(tag),
                    ],
                  ),
          ),
          _row(
            'Market value',
            e.value == null
                ? const Text('Unavailable')
                : Amount('${formatTry(e.value!)} TRY'),
          ),
          if (!e.closed) ...[
            _row(
              'Unrealized gain',
              e.unrealized == null
                  ? const Text('Unavailable')
                  : Amount(signedTry(e.unrealized!)),
            ),
            if (e.unrealizedPercent != null)
              _row('Unrealized %', Amount(signedPercent(e.unrealizedPercent!))),
          ],
          _row('Realized gain', Amount(signedTry(p.realized))),
          _row('Net dividends', Amount(signedTry(p.dividends))),
          const Divider(),
          Text('History', style: Theme.of(context).textTheme.titleMedium),
          for (final t in history)
            ListTile(
              dense: true,
              title: Text('${isoDate(t.effectiveDate)} ${t.type.json}'),
              trailing: Amount(_summary(t)),
            ),
        ],
      );
    },
  );

  static String _summary(Transaction t) => switch (t.type) {
    TxType.buy || TxType.sell =>
      '${formatQuantity(t.quantity!)} @ ${formatQuantity(t.unitPrice!)}',
    TxType.dividend => '${formatTry(t.grossAmount!)} TRY',
    TxType.split => '${t.ratioNumerator}:${t.ratioDenominator}',
  };

  static Widget _row(String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 140, child: Text(label)),
        Flexible(child: value),
      ],
    ),
  );
}
