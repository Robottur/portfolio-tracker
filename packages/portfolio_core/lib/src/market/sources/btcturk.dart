import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';

const btcTurkHost = 'api.btcturk.com';

DateTime _ms(Object? t, String id) {
  if (t is! int || t < 100000000000 || t >= 100000000000000) {
    throw SourceException(id, 'Bad timestamp');
  }
  return DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
}

class BtcTurkSource implements PriceSource {
  BtcTurkSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'btcturk';
  @override
  String get label => 'BtcTurk';
  @override
  List<String> get domains => const [btcTurkHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.crypto};

  Future<List<Object?>> _data(String path, Map<String, String> q) async {
    final body = await getJson(
      _c,
      Uri.https(btcTurkHost, path, q),
      id,
      timeout: timeout,
    );
    if (body is! Map || body['success'] != true || body['data'] is! List) {
      throw SourceException(id, 'Unexpected response');
    }
    final data = body['data'] as List;
    if (data.isEmpty) throw SourceException(id, 'Empty data');
    return data;
  }

  Decimal _price(Object? p) =>
      p is String ? priceFromString(p, id) : priceFromJson(p, id);

  Future<PriceObservation> _latestOne(Instrument i) async {
    final pair = '${i.code}TRY';
    final row = (await _data('/api/v2/ticker', {'pairSymbol': pair})).first;
    if (row is! Map || row['pair'] != pair) {
      throw SourceException(id, 'Unexpected pair');
    }
    final t = _ms(row['timestamp'], id);
    return PriceObservation(
      instrumentId: i.id,
      price: _price(row['last']),
      sessionDate: istanbulToday(t),
      quoteTime: t,
      receivedAt: _now(),
      source: id,
      kind: PriceKind.delayedQuote,
    );
  }

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final wanted = instruments.where((i) => i.assetClass == AssetClass.crypto);
    final out = <PriceObservation>[];
    SourceException? last;
    var tried = 0;
    for (final i in wanted) {
      tried++;
      try {
        out.add(await _latestOne(i));
      } on SourceException catch (e) {
        // A rate limit applies to every request: stop and back off.
        if (e.retryAfter != null) rethrow;
        last = e;
      }
    }
    if (tried > 0 && out.isEmpty) throw last!;
    return out;
  }

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    if (instrument.assetClass != AssetClass.crypto) return const [];
    final received = _now();
    final today = istanbulToday(received);
    final pair = '${instrument.code}TRY';
    // The endpoint ignores from/to and returns all history; last=N bounds it.
    final n = daysBetween(from, today) + 2;
    final rows = await _data('/api/v2/ohlc', {
      'pairSymbol': pair,
      'last': '${n < 2 ? 2 : n}',
    });
    final out = <PriceObservation>[];
    for (final row in rows) {
      if (row is! Map || row['pairSymbol'] != pair) continue;
      final t = _ms(row['time'], id);
      final d = istanbulToday(t);
      // Bars open at 00:00 UTC; between 21:00Z and 24:00Z the Istanbul date
      // has rolled but the bar is still forming.
      if (t.add(const Duration(days: 1)).isAfter(received)) continue;
      // Today's bar is still forming; it is not a close.
      if (d.isBefore(from) || d.isAfter(to) || !d.isBefore(today)) continue;
      out.add(
        PriceObservation(
          instrumentId: instrument.id,
          price: _price(row['close']),
          sessionDate: d,
          quoteTime: null,
          receivedAt: received,
          source: id,
          kind: PriceKind.close,
        ),
      );
    }
    out.sort((a, b) => a.sessionDate.compareTo(b.sessionDate));
    return out;
  }
}
