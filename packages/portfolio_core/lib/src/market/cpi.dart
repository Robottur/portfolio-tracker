import 'package:decimal/decimal.dart';

import '../decimal_util.dart';

String monthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

String _shift(String month, int by) {
  final n =
      int.parse(month.substring(0, 4)) * 12 +
      int.parse(month.substring(5)) -
      1 +
      by;
  return '${(n ~/ 12).toString().padLeft(4, '0')}-${(n % 12 + 1).toString().padLeft(2, '0')}';
}

class CpiEntry {
  CpiEntry(this.percent, this.source);
  final Decimal percent;

  /// `evds`, `tcmb` or `manual`.
  final String source;
}

/// Monthly CPI changes (percent) chained into a price level.
class CpiSeries {
  CpiSeries(this.months)
    : latestMonth = months.isEmpty ? null : (months.keys.toList()..sort()).last,
      _first = months.isEmpty ? null : (months.keys.toList()..sort()).first {
    final first = _first;
    if (first == null) return;
    // Level is 1 in the month before the earliest month; the chain stops at a gap.
    var level = Decimal.one;
    _levels[_shift(first, -1)] = level;
    for (var m = first; m.compareTo(latestMonth!) <= 0; m = _shift(m, 1)) {
      final e = months[m];
      if (e == null) break;
      level = roundHalfEven(
        level * (Decimal.one + divide(e.percent, Decimal.fromInt(100))),
        28,
      );
      _levels[m] = level;
    }
  }

  final Map<String, CpiEntry> months;
  final String? latestMonth;
  final String? _first;
  final Map<String, Decimal> _levels = {};

  /// True when any month comes from the 2-decimal TCMB page.
  bool get hasEstimates => months.values.any((e) => e.source == 'tcmb');

  /// Null before the month preceding the first entry and after a gap; carries forward after latestMonth.
  Decimal? index(String month) {
    final latest = latestMonth;
    if (latest == null) return null;
    return _levels[month.compareTo(latest) > 0 ? latest : month];
  }

  /// Fraction, e.g. 0.21 for +21%.
  Decimal? change(String fromMonth, String toMonth) {
    final a = index(fromMonth), b = index(toMonth);
    if (a == null || b == null) return null;
    return divide(b, a) - Decimal.one;
  }

  String? firstMissing(String fromMonth, String toMonth) {
    final first = _first;
    if (first == null || fromMonth.compareTo(_shift(first, -1)) < 0) {
      return fromMonth;
    }
    final end = toMonth.compareTo(latestMonth!) < 0 ? toMonth : latestMonth!;
    var m = first; // a gap before `from` also breaks index(from)
    for (; m.compareTo(end) <= 0; m = _shift(m, 1)) {
      if (!months.containsKey(m)) return m;
    }
    return null;
  }
}

String? validateManualCpi(
  String month,
  String percentText, {
  required DateTime today,
  required Set<String> manualMonths,
}) {
  if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(month)) {
    return 'Month must be YYYY-MM';
  }
  if (month.compareTo(monthKey(today)) > 0) return 'Month is in the future';
  if (manualMonths.contains(month)) return 'Month already entered';
  // parseUserDecimal takes no sign; monthly CPI can be negative.
  final t = percentText.trim();
  final neg = t.startsWith('-');
  final s = parseUserDecimal(neg ? t.substring(1) : t);
  final abs = s == null ? null : Decimal.tryParse(s);
  final p = abs == null ? null : (neg ? -abs : abs);
  if (p == null) return 'Percent is not a number';
  if (p < Decimal.fromInt(-50) || p > Decimal.fromInt(100)) {
    return 'Percent must be between -50 and 100';
  }
  return null;
}
