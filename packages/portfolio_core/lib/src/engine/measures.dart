import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../decimal_util.dart';
import '../market/cpi.dart';
import '../market/price.dart';
import '../model/transaction.dart';
import 'periods.dart';
import 'replay.dart';
import 'returns.dart';

enum Measure { tryNominal, usd, real }

class MissingRate implements Exception {
  MissingRate(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// Multipliers that turn nominal TRY into another measure.
abstract interface class Rates {
  Decimal? at(DateTime day);
  Decimal? get current;
  String missing(DateTime day);
  String? get note;
}

class UsdRates implements Rates {
  UsdRates(this._prices);
  final PriceLookup _prices;

  static Decimal? _inv(PriceObservation? o) =>
      o == null ? null : divide(Decimal.one, o.price);

  // The refresh fetches a 10-day window; an older close is a stale rate.
  @override
  Decimal? at(DateTime day) {
    final o = _prices.closeOnOrBefore('FX:USD', day);
    return o == null || day.difference(o.sessionDate).inDays > 10
        ? null
        : _inv(o);
  }

  @override
  Decimal? get current => _inv(_prices.latest('FX:USD'));

  @override
  String missing(DateTime day) => 'Missing USD/TRY rate for ${isoDate(day)}';

  @override
  String? get note => null;
}

class RealRates implements Rates {
  RealRates(this._cpi, {required this.today});
  final CpiSeries _cpi;
  final DateTime today;

  @override
  Decimal? at(DateTime day) {
    final latest = _cpi.latestMonth;
    final then = _cpi.index(monthKey(day));
    final now = latest == null ? null : _cpi.index(latest);
    return then == null || now == null ? null : divide(now, then);
  }

  @override
  Decimal? get current => Decimal.one;

  @override
  String missing(DateTime day) {
    final latest = _cpi.latestMonth;
    if (latest == null) return 'Add inflation data in Settings';
    final m = monthKey(day);
    return 'Inflation missing for ${_cpi.firstMissing(m, latest) ?? m}';
  }

  @override
  String? get note {
    final latest = _cpi.latestMonth;
    return latest != null && monthKey(today).compareTo(latest) > 0
        ? 'inflation known through $latest'
        : null;
  }
}

List<Transaction> convertTransactions(Iterable<Transaction> txs, Rates rates) {
  final sorted = txs.toList()
    ..sort((a, b) => a.effectiveDate.compareTo(b.effectiveDate));
  final rated = <Transaction>[];
  for (final t in sorted) {
    final r = rates.at(t.effectiveDate);
    if (r == null) throw MissingRate(rates.missing(t.effectiveDate));
    rated.add(t.scaledBy(r));
  }
  return rated;
}

PriceLookup convertPrices(PriceLookup prices, Rates rates) =>
    _Converted(prices, rates);

class _Converted implements PriceLookup {
  _Converted(this._prices, this._rates);
  final PriceLookup _prices;
  final Rates _rates;

  PriceObservation _scale(PriceObservation o, Decimal rate) => PriceObservation(
    instrumentId: o.instrumentId,
    price: o.price * rate,
    sessionDate: o.sessionDate,
    quoteTime: o.quoteTime,
    receivedAt: o.receivedAt,
    source: o.source,
    kind: o.kind,
  );

  @override
  PriceObservation? closeOnOrBefore(String instrumentId, DateTime date) {
    final o = _prices.closeOnOrBefore(instrumentId, date);
    if (o == null) return null;
    final r = _rates.at(date);
    if (r == null) throw MissingRate(_rates.missing(date));
    return _scale(o, r);
  }

  @override
  PriceObservation? latest(String instrumentId) {
    final o = _prices.latest(instrumentId);
    if (o == null) return null;
    final r = _rates.current;
    if (r == null) throw MissingRate(_rates.missing(o.sessionDate));
    return _scale(o, r);
  }
}

PeriodResult measuredPeriod({
  required Rates rates,
  required Period period,
  required DateTime today,
  required List<Transaction> transactions,
  required PriceLookup prices,
  required TradingCalendar calendar,
}) {
  // computePeriod's ledger check must win over a missing rate.
  if (!replay(transactions, through: today).valid) {
    return unavailablePeriod(
      reason: 'Ledger has unresolved issues',
      period: period,
      today: today,
      transactions: transactions,
      calendar: calendar,
    );
  }
  try {
    return computePeriod(
      period: period,
      today: today,
      transactions: convertTransactions(transactions, rates),
      prices: convertPrices(prices, rates),
      calendar: calendar,
    );
  } on MissingRate catch (e) {
    return unavailablePeriod(
      reason: e.reason,
      period: period,
      today: today,
      transactions: transactions,
      calendar: calendar,
    );
  }
}
