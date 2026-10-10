import 'package:decimal/decimal.dart';

import '../dates.dart';

enum PriceKind { close, delayedQuote, manual, derived }

class PriceObservation {
  PriceObservation({
    required this.instrumentId,
    required this.price,
    required this.sessionDate,
    required this.quoteTime,
    required this.receivedAt,
    required this.source,
    required this.kind,
  });

  final String instrumentId;
  final Decimal price;
  final DateTime sessionDate;
  final DateTime? quoteTime;
  final DateTime receivedAt;
  final String source;
  final PriceKind kind;

  Map<String, Object?> toJson() => {
    'instrument_id': instrumentId,
    'price': price.toString(),
    'session_date': isoDate(sessionDate),
    'quote_time': quoteTime?.toUtc().toIso8601String(),
    'received_at': receivedAt.toUtc().toIso8601String(),
    'source': source,
    'kind': kind.name,
  };

  /// Strict: throws [FormatException] on anything malformed.
  factory PriceObservation.fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('Not an object');
    }
    String str(String k) {
      final v = json[k];
      if (v is! String || v.isEmpty) throw FormatException('Bad field', k);
      return v;
    }

    DateTime utc(String s) {
      final t = DateTime.tryParse(s);
      if (t == null || !t.isUtc) throw FormatException('Bad UTC time', s);
      return t;
    }

    final q = json['quote_time'];
    if (q != null && q is! String) {
      throw const FormatException('Bad quote_time');
    }
    final kind = PriceKind.values.where((e) => e.name == str('kind'));
    if (kind.isEmpty) throw const FormatException('Bad kind');
    return PriceObservation(
      instrumentId: str('instrument_id'),
      price: parseCachedPrice(str('price')),
      sessionDate: parseIsoDate(str('session_date')),
      quoteTime: q == null ? null : utc(q as String),
      receivedAt: utc(str('received_at')),
      source: str('source'),
      kind: kind.first,
    );
  }
}

abstract interface class PriceLookup {
  PriceObservation? closeOnOrBefore(String instrumentId, DateTime date);
  PriceObservation? latest(String instrumentId);
}

final _cachedPrice = RegExp(r'^\d{1,18}(\.\d{1,28})?$');

/// A price must survive a save/reload unchanged, so one rule covers both:
/// derived prices (divide) carry up to 28 fractional digits.
bool isStorablePrice(Decimal p) =>
    p > Decimal.zero && _cachedPrice.hasMatch(p.toString());

Decimal parseCachedPrice(String s) {
  if (!_cachedPrice.hasMatch(s)) throw FormatException('Invalid price', s);
  final d = Decimal.parse(s);
  if (d <= Decimal.zero) throw FormatException('Price must be positive', s);
  return d;
}
