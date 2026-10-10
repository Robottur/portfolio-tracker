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

String? priceTag(PriceKind k) => switch (k) {
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
    required this.valuation,
    required this.onOpenTransactions,
  });

  final AppController controller;
  final Valuation valuation;
  final VoidCallback onOpenTransactions;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final scan = c.scan;
    final issues =
        (scan?.ledger.issues.length ?? 0) + (scan?.fileIssues.length ?? 0);
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
          onPressed: onOpenTransactions,
          icon: const Icon(Icons.warning_amber_outlined),
          label: Text('$issues ledger ${issues == 1 ? 'issue' : 'issues'}'),
        ),
      if (times.isNotEmpty)
        Text(
          'Quotes: ${_range(times.first, times.last)} '
          '(latest ${_age(times.last, c.today)})',
        ),
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

  static String _fmt(DateTime t) => t.isUtc && t.hour == 0 && t.minute == 0
      ? isoDate(t)
      : '${isoDate(t)} ${_two(t.hour)}:${_two(t.minute)} UTC';

  static String _range(DateTime a, DateTime b) =>
      a == b ? _fmt(a) : '${_fmt(a)} – ${_fmt(b)}';

  static String _age(DateTime t, DateTime today) {
    final d = daysBetween(DateTime.utc(t.year, t.month, t.day), today);
    return d <= 0 ? 'today' : '$d ${d == 1 ? 'day' : 'days'} old';
  }
}
