import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../storage/blob_store.dart';
import '../strict_json.dart';
import 'price.dart';

class PriceStore implements PriceLookup {
  PriceStore(this._store);

  final BlobStore _store;
  final Map<String, PriceObservation> _fetched = {};
  final Map<String, PriceObservation> _manual = {};

  static String _fetchedKey(PriceObservation o) =>
      '${o.instrumentId}|${isoDate(o.sessionDate)}|${o.kind.name}';
  static String _manualKey(String id, DateTime d) => '$id|${isoDate(d)}';

  Iterable<PriceObservation> get _all => [
    ..._fetched.values,
    ..._manual.values,
  ];

  Future<void> load() async {
    _fetched.clear();
    _manual.clear();
    await _read('prices', (o) => _fetched[_fetchedKey(o)] = o);
    await _read(
      'manual',
      (o) => _manual[_manualKey(o.instrumentId, o.sessionDate)] = o,
    );
  }

  // A corrupt cache must never crash or become a price: skip what does not parse.
  Future<void> _read(String key, void Function(PriceObservation) add) async {
    final bytes = await _store.get(key);
    if (bytes == null) return;
    try {
      final list = decodeStrictJson(utf8.decode(bytes));
      if (list is! List) return;
      for (final e in list) {
        try {
          add(PriceObservation.fromJson(e));
        } on FormatException {
          continue;
        }
      }
    } on FormatException {
      return;
    }
  }

  Future<void> _write(String key, Iterable<PriceObservation> obs) => _store.put(
    key,
    Uint8List.fromList(
      utf8.encode(jsonEncode([for (final o in obs) o.toJson()])),
    ),
  );

  Future<void> addFetched(List<PriceObservation> obs) async {
    for (final o in obs) {
      if (!isStorablePrice(o.price)) continue;
      final k = _fetchedKey(o);
      final old = _fetched[k];
      if (old == null || o.receivedAt.isAfter(old.receivedAt)) _fetched[k] = o;
    }
    await _write('prices', _fetched.values);
  }

  Future<void> setManual(
    String instrumentId,
    DateTime date,
    Decimal price, {
    required DateTime nowUtc,
  }) async {
    if (!isStorablePrice(price)) throw ArgumentError.value(price, 'price');
    _manual[_manualKey(instrumentId, date)] = PriceObservation(
      instrumentId: instrumentId,
      price: price,
      sessionDate: date,
      quoteTime: null,
      receivedAt: nowUtc,
      source: 'manual',
      kind: PriceKind.manual,
    );
    await _write('manual', _manual.values);
  }

  Future<void> removeManual(String instrumentId, DateTime date) async {
    if (_manual.remove(_manualKey(instrumentId, date)) != null) {
      await _write('manual', _manual.values);
    }
  }

  // Higher = better for a close lookup on one session date.
  static int _closeRank(PriceObservation o) => switch (o.kind) {
    PriceKind.manual => 2,
    PriceKind.close => 1,
    _ => 0,
  };

  @override
  PriceObservation? closeOnOrBefore(String instrumentId, DateTime date) {
    PriceObservation? best;
    for (final o in _all) {
      if (o.instrumentId != instrumentId ||
          o.sessionDate.isAfter(date) ||
          o.kind == PriceKind.delayedQuote) {
        continue;
      }
      if (best == null) {
        best = o;
        continue;
      }
      final c = o.sessionDate.compareTo(best.sessionDate);
      if (c > 0 ||
          (c == 0 &&
              (_closeRank(o) > _closeRank(best) ||
                  (_closeRank(o) == _closeRank(best) &&
                      o.receivedAt.isAfter(best.receivedAt))))) {
        best = o;
      }
    }
    return best;
  }

  static DateTime _at(PriceObservation o) =>
      o.quoteTime ?? o.sessionDate.add(const Duration(days: 1));

  @override
  PriceObservation? latest(String instrumentId) {
    PriceObservation? best;
    for (final o in _all) {
      if (o.instrumentId != instrumentId) continue;
      if (best == null) {
        best = o;
        continue;
      }
      var c = o.sessionDate.compareTo(best.sessionDate);
      if (c == 0) c = _at(o).compareTo(_at(best));
      if (c == 0) {
        c =
            (o.kind == PriceKind.manual ? 1 : 0) -
            (best.kind == PriceKind.manual ? 1 : 0);
      }
      if (c == 0) c = o.receivedAt.compareTo(best.receivedAt);
      if (c > 0) best = o;
    }
    return best;
  }

  List<DateTime> knownBistTradingDays() => {
    for (final o in _fetched.values)
      if (o.kind == PriceKind.close && o.instrumentId.startsWith('XIST:'))
        o.sessionDate,
  }.toList()..sort();
}
