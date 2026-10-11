import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../decimal_util.dart';
import '../market/price.dart';
import '../model/instrument.dart';
import '../model/transaction.dart';
import 'periods.dart';
import 'replay.dart';
import 'valuation.dart';

const _noCapital = 'N/A — no positive weighted capital';

class PeriodResult {
  PeriodResult({
    required this.period,
    required this.baseline,
    required this.end,
    this.valueStart,
    this.valueEnd,
    this.gain,
    this.returnPercent,
    this.unavailableReason,
    this.percentNote,
    this.sinceInception = false,
    this.indicative = false,
  });

  final Period period;
  final DateTime baseline;
  final DateTime end;
  final Decimal? valueStart;
  final Decimal? valueEnd;
  final Decimal? gain;
  final Decimal? returnPercent;
  final String? unavailableReason;
  final String? percentNote;
  final bool sinceInception;
  final bool indicative;
}

DateTime? _firstDate(List<Transaction> txs) => txs.isEmpty
    ? null
    : txs.map((t) => t.effectiveDate).reduce((a, b) => a.isBefore(b) ? a : b);

PeriodResult computePeriod({
  required Period period,
  required DateTime today,
  required List<Transaction> transactions,
  required PriceLookup prices,
  required TradingCalendar calendar,
}) {
  final first = _firstDate(transactions);
  if (first == null) {
    return PeriodResult(
      period: period,
      baseline: today,
      end: today,
      valueStart: Decimal.zero,
      valueEnd: Decimal.zero,
      gain: Decimal.zero,
      percentNote: _noCapital,
    );
  }
  final lifetime = period == Period.lifetime;
  final dayBeforeFirst = first.subtract(const Duration(days: 1));
  var b = lifetime ? dayBeforeFirst : baselineFor(period, today, calendar);
  var sinceInception = false;
  if (b.isBefore(dayBeforeFirst)) {
    b = dayBeforeFirst;
    sinceInception = !lifetime;
  }

  PeriodResult unavailable(String reason) => PeriodResult(
    period: period,
    baseline: b,
    end: today,
    unavailableReason: reason,
    sinceInception: sinceInception,
  );

  final endReplay = replay(transactions, through: today);
  if (!endReplay.valid) return unavailable('Ledger has unresolved issues');

  final Valuation? startVal = b.isBefore(first)
      ? null
      : valueHoldings(
          replay(transactions, through: b).positions,
          (id) => prices.closeOnOrBefore(id, b),
        );
  final endVal = valueHoldings(endReplay.positions, prices.latest);
  final missing = {...?startVal?.missing, ...endVal.missing}.toList()..sort();
  if (missing.isNotEmpty) {
    return unavailable('Missing price for ${missing.join(', ')}');
  }

  final vb = startVal?.total ?? Decimal.zero;
  final ve = endVal.total!;
  final flows = endReplay.flows.where((f) => f.date.isAfter(b)).toList();
  final gain = ve - vb - flows.fold(Decimal.zero, (a, f) => a + f.amount);

  final days = daysBetween(b, today) < 1 ? 1 : daysBetween(b, today);
  final d = Decimal.fromInt(days);
  var w = vb;
  for (final f in flows) {
    final weight = divide(
      Decimal.fromInt(days - daysBetween(b, f.date) + 1),
      d,
    );
    w += weight * f.amount;
  }
  final positive = w > Decimal.zero;
  return PeriodResult(
    period: period,
    baseline: b,
    end: today,
    valueStart: vb,
    valueEnd: ve,
    gain: gain,
    returnPercent: positive ? divide(gain * Decimal.fromInt(100), w) : null,
    percentNote: positive ? null : _noCapital,
    sinceInception: sinceInception,
    indicative: endVal.status != DataStatus.complete,
  );
}

Map<DateTime, List<Instrument>> historicalPriceNeeds({
  required DateTime today,
  required List<Transaction> transactions,
  required TradingCalendar calendar,
}) {
  final first = _firstDate(transactions);
  if (first == null) return {};
  final out = <DateTime, List<Instrument>>{};
  for (final p in Period.values.where((p) => p != Period.lifetime)) {
    final b = baselineFor(p, today, calendar);
    if (b.isBefore(first)) continue;
    // Daily asks for the latest weekday, not the latest known close, so the
    // fetch discovers sessions the app has not seen yet.
    final day = p == Period.daily ? weekdayBefore(today) : b;
    final held = {
      ...?out[day],
      for (final pos in replay(transactions, through: b).positions.values)
        if (pos.quantity > Decimal.zero) pos.instrument,
    };
    if (held.isNotEmpty) out[day] = held.toList();
  }
  return out;
}
