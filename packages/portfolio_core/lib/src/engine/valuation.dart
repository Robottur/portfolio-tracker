import 'package:decimal/decimal.dart';

import '../market/price.dart';
import 'replay.dart';

enum DataStatus { complete, indicative, manual, unavailable }

class Valuation {
  Valuation(this.holdingValues, this.pricesUsed, this.missing);

  final Map<String, Decimal> holdingValues;
  final Map<String, PriceObservation> pricesUsed;
  final List<String> missing;

  Decimal get knownValue =>
      holdingValues.values.fold(Decimal.zero, (a, b) => a + b);

  /// Null when any holding has no price: a missing price is never zero.
  Decimal? get total => missing.isEmpty ? knownValue : null;

  DataStatus get status {
    if (missing.isNotEmpty) return DataStatus.unavailable;
    final kinds = pricesUsed.values.map((o) => o.kind).toSet();
    if (kinds.contains(PriceKind.manual)) return DataStatus.manual;
    if (kinds.contains(PriceKind.delayedQuote) ||
        kinds.contains(PriceKind.derived)) {
      return DataStatus.indicative;
    }
    return DataStatus.complete;
  }
}

Valuation valueHoldings(
  Map<String, Position> positions,
  PriceObservation? Function(String instrumentId) priceFor,
) {
  final values = <String, Decimal>{};
  final used = <String, PriceObservation>{};
  final missing = <String>[];
  for (final e in positions.entries) {
    if (e.value.quantity == Decimal.zero) continue;
    final p = priceFor(e.key);
    if (p == null) {
      missing.add(e.key);
    } else {
      used[e.key] = p;
      values[e.key] = e.value.quantity * p.price;
    }
  }
  return Valuation(values, used, missing..sort());
}
