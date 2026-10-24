import 'package:decimal/decimal.dart';

final _recordField = RegExp(r'^\d{1,18}(\.\d{1,8})?$');
final _userDecimal = RegExp(r'^\d+(\.\d+)?$');

/// Parses a record amount string; rejects anything but plain digits.
Decimal parseDecimalField(String s, {bool allowZero = false}) {
  if (!_recordField.hasMatch(s)) {
    throw FormatException('Invalid decimal field', s);
  }
  final d = Decimal.parse(s);
  if (!allowZero && d <= Decimal.zero) {
    throw FormatException('Decimal field must be positive', s);
  }
  return d;
}

// Rational is not exported by decimal, so take its parts (d > 0).
BigInt _halfEven(BigInt n, BigInt d) {
  var q = n ~/ d; // truncates toward zero
  final twice = n.remainder(d).abs() * BigInt.two;
  final c = twice.compareTo(d);
  if (c > 0 || (c == 0 && q.isOdd)) q += BigInt.from(n.sign);
  return q;
}

/// Exact division to 28 fractional digits, half-even.
Decimal divide(Decimal a, Decimal b) => (a / b).toDecimal(
  scaleOnInfinitePrecision: 28,
  toBigInt: (r) => _halfEven(r.numerator, r.denominator),
);

Decimal roundHalfEven(Decimal v, int scale) {
  final r = v.shift(scale).toRational();
  return Decimal.fromBigInt(_halfEven(r.numerator, r.denominator))
      .shift(-scale);
}

String _group(String digits) =>
    digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

String _grouped(Decimal v, String Function(Decimal) text) {
  final s = text(v);
  final neg = s.startsWith('-');
  final parts = (neg ? s.substring(1) : s).split('.');
  return '${neg ? '-' : ''}${_group(parts[0])}${parts.length > 1 ? '.${parts[1]}' : ''}';
}

String formatTry(Decimal v) =>
    _grouped(roundHalfEven(v, 2), (d) => d.toStringAsFixed(2));

String formatPercent(Decimal v) => '${roundHalfEven(v, 2).toStringAsFixed(2)}%';

String formatQuantity(Decimal v) =>
    _grouped(roundHalfEven(v, 8), (d) => d.toString());

/// Turkish-friendly input: `12,50` -> `12.50`; mixed separators are ambiguous -> null.
String? parseUserDecimal(String input) {
  final t = input.trim();
  if (t.contains(',') && t.contains('.')) return null;
  final s = t.replaceAll(',', '.');
  return _userDecimal.hasMatch(s) ? s : null;
}
