import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  test('F: baselines', () {
    final cal = TradingCalendar([date(2026, 10, 8), date(2026, 10, 9)]);
    expect(
      baselineFor(Period.oneMonth, date(2026, 3, 31), cal),
      date(2026, 2, 28),
    );
    expect(
      baselineFor(Period.threeMonths, date(2026, 5, 31), cal),
      date(2026, 2, 28),
    );
    expect(
      baselineFor(Period.oneYear, date(2028, 2, 29), cal),
      date(2027, 2, 28),
    );
    expect(
      baselineFor(Period.daily, date(2026, 10, 11), cal),
      date(2026, 10, 9),
    );
  });

  test('calendar falls back to the latest weekday when nothing is known', () {
    final cal = TradingCalendar([]);
    expect(cal.lastTradingDayBefore(date(2026, 10, 12)), date(2026, 10, 9));
    expect(cal.lastTradingDayBefore(date(2026, 10, 13)), date(2026, 10, 12));
  });

  test('calendar uses a known day strictly before the date', () {
    final cal = TradingCalendar([date(2026, 10, 8), date(2026, 10, 9)]);
    expect(cal.lastTradingDayBefore(date(2026, 10, 9)), date(2026, 10, 8));
  });
}
