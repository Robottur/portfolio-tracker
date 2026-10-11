import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:portfolio_core/portfolio_core.dart';

import '../app/app_controller.dart';

/// Sign plus words, so a gain or loss never depends on colour.
String signedTry(Decimal v) {
  final r = roundHalfEven(v, 2);
  if (r == Decimal.zero) return '${formatTry(r)} TRY';
  return r > Decimal.zero
      ? '+${formatTry(r)} TRY gain'
      : '−${formatTry(-r)} TRY loss';
}

String signedPercent(Decimal v) {
  final r = roundHalfEven(v, 2);
  if (r == Decimal.zero) return formatPercent(r);
  return r > Decimal.zero ? '+${formatPercent(r)}' : '−${formatPercent(-r)}';
}

// Derived gold is "indicative" everywhere (spec §7.2), whatever its kind.
String? priceTag(PriceObservation o) => switch (o.kind) {
  _ when o.source == 'gold' => 'indicative',
  PriceKind.delayedQuote => 'Delayed',
  PriceKind.derived => 'indicative',
  PriceKind.manual => 'manual',
  PriceKind.close => null,
};

String _two(int n) => n.toString().padLeft(2, '0');

String stamp(PriceObservation o) {
  final q = o.quoteTime?.toUtc();
  return q == null
      ? isoDate(o.sessionDate)
      : '${isoDate(q)} ${_two(q.hour)}:${_two(q.minute)} UTC';
}

class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.controller,
    required this.onOpenIssues,
  });

  final AppController controller;
  final VoidCallback onOpenIssues;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scan = c.scan;
    final valuation = valueHoldings(c.displayReplay.positions, c.prices.latest);
    final issues = c.issueCount;
    final prev = c.lastValidScan;
    final times = [
      for (final o in valuation.pricesUsed.values) o.quoteTime ?? o.sessionDate,
    ]..sort();
    final offline = [
      for (final id in c.prefs.enabledSources)
        if (c.refresher.status[id]?.lastError case final e?)
          'Offline — $id: $e',
    ];
    final lines = <Widget>[
      if (scan != null && !scan.complete && prev != null)
        Text('Showing previous data from ${_local(prev.scannedAt)}'),
      if (issues > 0)
        TextButton.icon(
          onPressed: onOpenIssues,
          icon: const Icon(Icons.warning_amber_outlined),
          label: Text('$issues ledger ${issues == 1 ? 'issue' : 'issues'}'),
        ),
      if (times.isNotEmpty)
        Text(
          'Quotes: ${_range(times.first, times.last)} '
          '(latest ${_age(times.last, c.today)})',
        ),
      if (c.pendingCount > 0)
        Text('${c.pendingCount} entries waiting to be written'),
      for (final o in offline) Text(o),
      if (valuation.status == DataStatus.indicative ||
          valuation.status == DataStatus.manual)
        const Text('Some prices are delayed, indicative or manual.'),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines,
        ),
      ),
    );
  }

  static String _local(DateTime t) {
    final l = t.toLocal();
    return '${isoDate(DateTime.utc(l.year, l.month, l.day))} '
        '${_two(l.hour)}:${_two(l.minute)}';
  }

  static String fmt(DateTime t) {
    final u = t.toUtc();
    return u.hour == 0 && u.minute == 0
        ? isoDate(u)
        : '${isoDate(u)} ${_two(u.hour)}:${_two(u.minute)} UTC';
  }

  static String _range(DateTime a, DateTime b) =>
      a == b ? fmt(a) : '${fmt(a)} – ${fmt(b)}';

  static String _age(DateTime t, DateTime today) {
    final q = istanbulToday(t.toUtc());
    final d = daysBetween(q, today);
    return d <= 0 ? 'today' : '$d ${d == 1 ? 'day' : 'days'} old';
  }
}
