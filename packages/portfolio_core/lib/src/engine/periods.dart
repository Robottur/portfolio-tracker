import '../dates.dart';

enum Period { daily, oneMonth, threeMonths, oneYear, lifetime }

class TradingCalendar {
  TradingCalendar(Iterable<DateTime> knownDays) : _days = knownDays.toList();

  final List<DateTime> _days;

  /// Latest known trading day strictly before [d].
  DateTime lastTradingDayBefore(DateTime d) {
    DateTime? best;
    for (final k in _days) {
      if (k.isBefore(d) && (best == null || k.isAfter(best))) best = k;
    }
    if (best != null) return best;
    // shortcut: weekday fallback ignores holidays until closes are cached
    var x = d.subtract(const Duration(days: 1));
    while (x.weekday > DateTime.friday) {
      x = x.subtract(const Duration(days: 1));
    }
    return x;
  }
}

/// Lifetime is handled in computePeriod (it depends on the first transaction).
DateTime baselineFor(Period p, DateTime end, TradingCalendar cal) =>
    switch (p) {
      Period.daily => cal.lastTradingDayBefore(end),
      Period.oneMonth => minusMonthsClamped(end, 1),
      Period.threeMonths => minusMonthsClamped(end, 3),
      Period.oneYear => minusMonthsClamped(end, 12),
      Period.lifetime => throw ArgumentError(
        'lifetime has no calendar baseline',
      ),
    };
