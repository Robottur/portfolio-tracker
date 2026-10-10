import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  test('dates', () {
    expect(
      istanbulToday(DateTime.utc(2026, 10, 10, 22, 30)),
      date(2026, 10, 11),
    );
    expect(
      istanbulToday(DateTime.utc(2026, 10, 10, 20, 59)),
      date(2026, 10, 10),
    );
    expect(minusMonthsClamped(date(2026, 3, 31), 1), date(2026, 2, 28));
    expect(minusMonthsClamped(date(2028, 2, 29), 12), date(2027, 2, 28));
    expect(minusMonthsClamped(date(2026, 1, 15), 2), date(2025, 11, 15));
    expect(daysBetween(date(2026, 4, 30), date(2026, 5, 30)), 30);
    expect(daysBetween(date(2026, 3, 1), date(2026, 3, 1)), 0);
  });
  test('iso dates', () {
    expect(isoDate(date(2026, 1, 5)), '2026-01-05');
    expect(parseIsoDate('2026-02-28'), date(2026, 2, 28));
    for (final bad in [
      '2026-02-30',
      '2026-2-3',
      '20260203',
      '2026-02-03T00:00:00Z',
      '',
      'x',
    ]) {
      expect(() => parseIsoDate(bad), throwsFormatException, reason: bad);
    }
  });
}
