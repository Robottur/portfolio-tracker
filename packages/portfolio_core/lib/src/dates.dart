final _isoDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

DateTime date(int y, int m, int d) => DateTime.utc(y, m, d);

DateTime parseIsoDate(String s) {
  if (!_isoDate.hasMatch(s)) throw FormatException('Invalid ISO date', s);
  final y = int.parse(s.substring(0, 4));
  final m = int.parse(s.substring(5, 7));
  final d = int.parse(s.substring(8, 10));
  final r = date(y, m, d);
  // DateTime normalizes overflow (Feb 30 -> Mar 2); reject that.
  if (r.year != y || r.month != m || r.day != d) {
    throw FormatException('Invalid calendar date', s);
  }
  return r;
}

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime istanbulToday(DateTime nowUtc) {
  // shortcut: Türkiye is fixed UTC+3 since 2016; switch to a tz database if DST returns.
  final t = nowUtc.toUtc().add(const Duration(hours: 3));
  return date(t.year, t.month, t.day);
}

DateTime minusMonthsClamped(DateTime d, int months) {
  final total = d.year * 12 + (d.month - 1) - months;
  final y = total ~/ 12, m = total % 12 + 1;
  final last = DateTime.utc(y, m + 1, 0).day;
  return date(y, m, d.day > last ? last : d.day);
}

int daysBetween(DateTime from, DateTime to) => date(
  to.year,
  to.month,
  to.day,
).difference(date(from.year, from.month, from.day)).inDays;
