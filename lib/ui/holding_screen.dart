import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';
import '../app/device_prefs.dart';
import 'asset_labels.dart';
import 'gain_colors.dart';
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

List<HoldingEntry> entriesFrom(
  (ReplayResult, PriceLookup) data, {
  bool closed = false,
}) => [
  for (final p in data.$1.positions.values)
    if (closed || p.quantity > Decimal.zero)
      HoldingEntry(p, data.$2.latest(p.instrument.id)),
]..sort((a, b) => a.position.instrument.id.compareTo(b.position.instrument.id));

List<HoldingEntry> holdingEntries(AppController c, {bool closed = false}) =>
    entriesFrom((c.displayReplay, c.prices), closed: closed);

/// Unrealized % per open holding in real terms; empty when REAL is unavailable.
Map<String, Decimal> realGains(AppController c) {
  final h = c.holdingsIn(Measure.real);
  return h == null
      ? {}
      : {
          for (final e in entriesFrom(h))
            if (e.unrealizedPercent != null)
              e.position.instrument.id: e.unrealizedPercent!,
        };
}

const measureNames = {
  Measure.tryNominal: 'TRY',
  Measure.usd: 'USD',
  Measure.real: 'Real',
};

/// `<USD|Real> unavailable: <reason>` when [wanted] cannot be shown, else null.
String? unavailableLine(AppController c, Measure wanted, Period p) =>
    c.holdingsIn(wanted) != null
    ? null
    : '${measureNames[wanted]} unavailable: '
          '${c.measureUnavailable(wanted) ?? c.displayPeriodIn(wanted, p).unavailableReason ?? 'a rate is missing'}';

String _signed1(Decimal v) {
  final r = roundHalfEven(v, 1);
  return r >= Decimal.zero
      ? '+${r.toStringAsFixed(1)}%'
      : '−${(-r).toStringAsFixed(1)}%';
}

/// Largest first for numeric orders; entries without the number go last.
List<HoldingEntry> sortEntries(List<HoldingEntry> entries, HoldingSort by) {
  Decimal? key(HoldingEntry e) => switch (by) {
    HoldingSort.name => null,
    HoldingSort.value => e.value,
    HoldingSort.gainTry => e.closed ? null : e.unrealized,
    HoldingSort.gainPercent => e.closed ? null : e.unrealizedPercent,
  };
  int byName(HoldingEntry a, HoldingEntry b) {
    final x = a.position.instrument, y = b.position.instrument;
    final c = x.code.compareTo(y.code);
    return c != 0 ? c : x.id.compareTo(y.id);
  }

  return [...entries]..sort((a, b) {
    final ka = key(a), kb = key(b);
    if (ka != null && kb != null && ka != kb) return kb.compareTo(ka);
    if ((ka == null) != (kb == null)) return ka == null ? 1 : -1;
    return byName(a, b);
  });
}

const _sortLabels = {
  HoldingSort.name: 'Name',
  HoldingSort.value: 'Value',
  HoldingSort.gainTry: 'TRY gain',
  HoldingSort.gainPercent: '% gain',
};

class SortButton extends StatelessWidget {
  const SortButton({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => PopupMenuButton<HoldingSort>(
    tooltip: 'Sort',
    initialValue: controller.prefs.holdingSort,
    onSelected: (s) => controller.setHoldingSort(s).catchError((_) {
      // A sort order is a convenience; the list keeps its last order.
    }),
    itemBuilder: (_) => [
      for (final e in _sortLabels.entries)
        PopupMenuItem(value: e.key, child: Text(e.value)),
    ],
    // The popup button's own InkWell is the single focus stop.
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: Theme.of(context).colorScheme.primary),
        child: IconTheme.merge(
          data: IconThemeData(color: Theme.of(context).colorScheme.primary),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort, size: 18),
              const SizedBox(width: 8),
              Text('Sort: ${_sortLabels[controller.prefs.holdingSort]} ▾'),
            ],
          ),
        ),
      ),
    ),
  );
}

class HoldingTile extends StatelessWidget {
  const HoldingTile({
    super.key,
    required this.entry,
    required this.onTap,
    this.selected = false,
    this.measure = Measure.tryNominal,
    this.real,
  });

  final HoldingEntry entry;
  final Measure measure;

  /// Real unrealized % for the beat-inflation marker.
  final Decimal? real;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tag = entry.price == null ? null : priceTag(entry.price!);
    return ListTile(
      selected: selected,
      isThreeLine: true, // value, gain and gain % stack on the right
      title: Text(
        '${entry.position.instrument.code}${entry.closed ? ' (closed)' : ''}',
      ),
      subtitle: Wrap(
        spacing: 8,
        children: [
          Amount(formatQuantity(entry.position.quantity)),
          if (tag != null) Text(tag),
          if (real != null && !entry.closed)
            Amount('real ${_signed1(real!)}', style: gainStyle(context, real!)),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (entry.value == null)
            const Text('Price missing')
          else
            Amount(formatMoney(entry.value!, measure)),
          if (entry.unrealized != null && !entry.closed) ...[
            Amount(
              signedMoney(entry.unrealized!, measure),
              style: gainStyle(context, entry.unrealized!),
            ),
            // Own line: beside the TRY gain it overflows phone widths.
            if (entry.unrealizedPercent != null)
              Amount(
                signedPercent(entry.unrealizedPercent!),
                style: gainStyle(context, entry.unrealized!),
              ),
          ],
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
    required this.onOpenIssues,
  });
  final AppController controller;
  final VoidCallback onOpenIssues;

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
      final wanted = c.prefs.measure;
      final data = c.holdingsIn(wanted);
      final m = data == null ? Measure.tryNominal : wanted;
      final entries = c.displayIncomplete
          ? <HoldingEntry>[]
          : sortEntries(
              entriesFrom(
                data ?? c.holdingsIn(Measure.tryNominal)!,
                closed: _closed,
              ),
              c.prefs.holdingSort,
            );
      final notice = unavailableLine(c, wanted, Period.lifetime);
      final real = realGains(c);
      final list = ListView(
        children: [
          StatusBanner(controller: c, onOpenIssues: widget.onOpenIssues),
          Align(
            alignment: Alignment.centerLeft,
            child: SortButton(controller: c),
          ),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(notice),
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
              measure: m,
              real: real[e.position.instrument.id],
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
            '${p.instrument.code} · ${assetClassLabel(p.instrument.assetClass)}',
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
                  : Amount(
                      signedTry(e.unrealized!),
                      style: gainStyle(context, e.unrealized!),
                    ),
            ),
            if (e.unrealizedPercent != null)
              _row(
                'Unrealized %',
                Amount(
                  signedPercent(e.unrealizedPercent!),
                  style: gainStyle(context, e.unrealizedPercent!),
                ),
              ),
          ],
          _row(
            'Realized gain',
            Amount(
              signedTry(p.realized),
              style: gainStyle(context, p.realized),
            ),
          ),
          _row('Net dividends', Amount(signedTry(p.dividends))),
          ..._block(context, 'In USD', Measure.usd),
          ..._block(context, 'After inflation', Measure.real),
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

  /// Cost, value and gains of this holding in a measure; the reason if it can't be shown.
  List<Widget> _block(BuildContext context, String title, Measure m) {
    final head = Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
    final data = controller.holdingsIn(m);
    final p = data?.$1.positions[instrumentId];
    if (data == null || p == null) {
      return [
        head,
        Text(
          controller.measureUnavailable(m) ??
              controller
                  .displayPeriodIn(m, Period.lifetime)
                  .unavailableReason ??
              'a rate is missing',
        ),
      ];
    }
    final e = HoldingEntry(p, data.$2.latest(instrumentId));
    final pct = e.unrealizedPercent;
    return [
      head,
      _row('Cost', Amount(formatMoney(p.cost, m))),
      _row(
        'Value',
        e.value == null
            ? const Text('Unavailable')
            : Amount(formatMoney(e.value!, m)),
      ),
      if (!e.closed && e.unrealized != null)
        _row(
          'Unrealized gain',
          Amount(
            signedMoney(e.unrealized!, m),
            style: gainStyle(context, e.unrealized!),
          ),
        ),
      if (!e.closed && pct != null)
        _row(
          'Unrealized %',
          Amount(signedPercent(pct), style: gainStyle(context, pct)),
        ),
      _row(
        'Realized gain',
        Amount(
          signedMoney(p.realized, m),
          style: gainStyle(context, p.realized),
        ),
      ),
      if (m == Measure.real && !e.closed && pct != null)
        Amount(
          roundHalfEven(pct, 2) >= Decimal.zero
              ? 'Beat inflation by ${formatPercent(pct)} since purchase'
              : 'Behind inflation by ${formatPercent(-pct)}',
        ),
    ];
  }

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
