import 'dart:convert';
import 'dart:typed_data';

import 'package:decimal/decimal.dart';

import '../dates.dart';
import '../storage/blob_store.dart';
import '../strict_json.dart';
import 'cpi.dart';
import 'price.dart';

class PriceStore implements PriceLookup {
  PriceStore(this._store);

  final BlobStore _store;
  final Map<String, PriceObservation> _fetched = {};
  final Map<String, PriceObservation> _manual = {};
  final Map<String, String> _fundKinds = {};
  // source -> month -> percent text
  final Map<String, Map<String, Decimal>> _cpi = {};

  static String _fetchedKey(PriceObservation o) =>
      '${o.instrumentId}|${isoDate(o.sessionDate)}|${o.kind.name}';
  static String _manualKey(String id, DateTime d) => '$id|${isoDate(d)}';

  Iterable<PriceObservation> get _all => [
    ..._fetched.values,
    ..._manual.values,
  ];

  List<PriceObservation> get manualPrices =>
      _manual.values.toList()..sort((a, b) {
        final c = a.instrumentId.compareTo(b.instrumentId);
        return c != 0 ? c : a.sessionDate.compareTo(b.sessionDate);
      });

  Future<void> load() async {
    _fetched.clear();
    _manual.clear();
    _fundKinds.clear();
    _cpi.clear();
    await _read('prices', (o) => _fetched[_fetchedKey(o)] = o);
    await _read(
      'manual',
      (o) => _manual[_manualKey(o.instrumentId, o.sessionDate)] = o,
    );
    await _readFundKinds();
    await _readCpi();
  }

  static const _cpiSources = ['evds', 'tcmb', 'manual'];

  /// Precedence: evds, then tcmb, then manual.
  CpiSeries get cpi {
    final out = <String, CpiEntry>{};
    for (final src in _cpiSources.reversed) {
      for (final e in (_cpi[src] ?? const <String, Decimal>{}).entries) {
        out[e.key] = CpiEntry(e.value, src);
      }
    }
    return CpiSeries(out);
  }

  // At or below -100% the chained level hits zero and division fails.
  static bool _validCpiPercent(Decimal p) => p > Decimal.fromInt(-100);

  Future<void> setCpi(Map<String, Decimal> months, String source) {
    if (!months.values.every(_validCpiPercent)) {
      throw ArgumentError.value(months, 'months', 'percent must be above -100');
    }
    _cpi[source] = Map.of(months);
    return _writeCpi();
  }

  Future<void> setManualCpi(String month, Decimal percent) {
    if (!_validCpiPercent(percent)) {
      throw ArgumentError.value(percent, 'percent');
    }
    (_cpi['manual'] ??= {})[month] = percent;
    return _writeCpi();
  }

  Future<void> removeManualCpi(String month) async {
    if (_cpi['manual']?.remove(month) != null) await _writeCpi();
  }

  Future<void> _writeCpi() => _store.put(
    'cpi',
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          for (final s in _cpi.entries)
            s.key: {for (final m in s.value.entries) m.key: m.value.toString()},
        }),
      ),
    ),
  );

  Future<void> _readCpi() async {
    final bytes = await _store.get('cpi');
    if (bytes == null) return;
    try {
      final m = decodeStrictJson(utf8.decode(bytes));
      if (m is! Map) return;
      for (final src in _cpiSources) {
        final months = m[src];
        if (months is! Map) continue;
        for (final e in months.entries) {
          final p = e.value is String
              ? Decimal.tryParse(e.value as String)
              : null;
          if (e.key is String &&
              RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(e.key as String) &&
              p != null &&
              _validCpiPercent(p)) {
            (_cpi[src] ??= {})[e.key as String] = p;
          }
        }
      }
    } on FormatException {
      return;
    }
  }

  String? fundKind(String code) {
    final k = _fundKinds[code];
    return const ['YAT', 'EMK', 'BYF'].contains(k) ? k : null;
  }

  Future<void> setFundKind(String code, String kind) {
    _fundKinds[code] = kind;
    return _store.put(
      'fund_kinds',
      Uint8List.fromList(utf8.encode(jsonEncode(_fundKinds))),
    );
  }

  Future<void> _readFundKinds() async {
    final bytes = await _store.get('fund_kinds');
    if (bytes == null) return;
    try {
      final m = decodeStrictJson(utf8.decode(bytes));
      if (m is! Map) return;
      for (final e in m.entries) {
        if (e.key is String && e.value is String) {
          _fundKinds[e.key as String] = e.value as String;
        }
      }
    } on FormatException {
      return;
    }
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
