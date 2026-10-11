import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../model/instrument.dart';
import '../consent_client.dart';
import '../price.dart';
import '../source.dart';

const binanceHost = 'api.binance.com';

class BinanceSource implements PriceSource {
  BinanceSource(
    this._c, {
    required DateTime Function() nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc;

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'binance';
  @override
  String get label => 'Binance (crypto)';
  @override
  List<String> get domains => const [binanceHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.crypto};

  /// Decoded JSON, or null when Binance says the symbol does not exist
  /// (HTTP 400, code -1121), which is not an error.
  Future<Object?> _get(String path, Map<String, String> q) async {
    final http.Response r;
    try {
      r = await _c
          .get(
            Uri.https(binanceHost, path, q),
            headers: {'User-Agent': 'Mozilla/5.0'},
          )
          .timeout(timeout);
    } on ConsentDeniedException {
      rethrow;
    } on Exception catch (e) {
      throw SourceException(id, 'Request failed: ${e.runtimeType}');
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      body = null;
    }
    if (r.statusCode == 400 && body is Map && body['code'] == -1121) {
      return null;
    }
    if (r.statusCode == 418) {
      // IP ban: back off like a 429.
      final secs = int.tryParse(r.headers['retry-after'] ?? '') ?? 60;
      throw SourceException(
        id,
        'Banned (418)',
        retryAfter: Duration(seconds: secs.clamp(0, 3600)),
      );
    }
    checkResponse(r, id);
    if (body == null) throw SourceException(id, 'Response is not JSON');
    return body;
  }

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final out = <PriceObservation>[];
    SourceException? last;
    var tried = 0;
    for (final i in instruments.where(
      (i) => i.assetClass == AssetClass.crypto,
    )) {
      tried++;
      try {
        final pair = '${i.code}TRY';
        final body = await _get('/api/v3/ticker/price', {'symbol': pair});
        if (body == null) continue;
        if (body is! Map || body['symbol'] != pair) {
          throw SourceException(id, 'Unexpected response');
        }
        final p = body['price'];
        if (p is! String) throw SourceException(id, 'Unexpected response');
        final now = _now();
        out.add(
          PriceObservation(
            instrumentId: i.id,
            price: priceFromString(p, id),
            sessionDate: istanbulToday(now),
            quoteTime: now,
            receivedAt: now,
            source: id,
            kind: PriceKind.delayedQuote,
          ),
        );
      } on SourceException catch (e) {
        // A rate limit or ban applies to every request: stop and back off.
        if (e.retryAfter != null) rethrow;
        last = e;
      }
    }
    if (tried > 0 && out.isEmpty && last != null) throw last;
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
    final today = DateTime.utc(received.year, received.month, received.day);
    final pair = '${instrument.code}TRY';
    final body = await _get('/api/v3/klines', {
      'symbol': pair,
      'interval': '1d',
      'startTime': '${from.millisecondsSinceEpoch}',
      'endTime':
          '${to.add(const Duration(days: 1)).millisecondsSinceEpoch - 1}',
    });
    if (body == null) return const [];
    if (body is! List) throw SourceException(id, 'Unexpected response');
    final out = <PriceObservation>[];
    for (final row in body) {
      if (row is! List || row.length < 5) {
        throw SourceException(id, 'Unexpected response');
      }
      final t = row[0];
      final c = row[4];
      if (t is! int || c is! String) {
        throw SourceException(id, 'Unexpected response');
      }
      final open = DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
      // shortcut: Binance days are UTC days (close at 03:00 Istanbul); use an Istanbul-aligned source if one appears
      final d = DateTime.utc(open.year, open.month, open.day);
      // The current UTC day's candle is still live; it is not a close.
      if (d.isBefore(from) || d.isAfter(to) || !d.isBefore(today)) continue;
      out.add(
        PriceObservation(
          instrumentId: instrument.id,
          price: priceFromString(c, id),
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
