import '../dates.dart';

enum Period { daily, oneMonth, threeMonths, oneYear, lifetime }

class TradingCalendar {
  TradingCalendar(Iterable<DateTime> knownDays) : _days = knownDays.toList();

  final List<DateTime> _days;

  /// Latest known trading day strictly before [d], unless it is stale.
  DateTime lastTradingDayBefore(DateTime d) {
    DateTime? known;
    for (final k in _days) {
      if (k.isBefore(d) && (known == null || k.isAfter(known))) known = k;
    }
    var weekday = d.subtract(const Duration(days: 1));
    while (weekday.weekday > DateTime.friday) {
      weekday = weekday.subtract(const Duration(days: 1));
    }
    // shortcut: falls back to weekdays when known closes are stale (> 4 days); holidays need an exchange calendar
    return known == null || daysBetween(known, weekday) > 4 ? weekday : known;
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
