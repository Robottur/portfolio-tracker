import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';

const yahooHost = 'query1.finance.yahoo.com';

DateTime _epoch(int s) =>
    DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);

/// Returns `chart.result[0]`; an error object, null or empty result throws.
Future<Map<String, Object?>> fetchYahooChart(
  http.Client c,
  String symbol, {
  DateTime? from,
  DateTime? to,
  String sourceId = 'yahoo',
  Duration timeout = requestTimeout,
}) async {
  final q = from != null && to != null
      ? {
          'period1': '${from.millisecondsSinceEpoch ~/ 1000}',
          // inclusive of the end day
          'period2':
              '${to.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000}',
          'interval': '1d',
        }
      : {'range': '1d', 'interval': '1d'};
  final body = await getJson(
    c,
    Uri.https(yahooHost, '/v8/finance/chart/$symbol', q),
    sourceId,
    timeout: timeout,
  );
  final chart = body is Map ? body['chart'] : null;
  final result = chart is Map ? chart['result'] : null;
  if (result is! List || result.isEmpty || result.first is! Map) {
    throw SourceException(sourceId, 'No data for $symbol');
  }
  return (result.first as Map).cast<String, Object?>();
}

/// Latest quote of a chart: price, epoch-s quote time.
({Decimal price, DateTime time}) yahooQuote(
  Map<String, Object?> chart,
  String currency,
  String sourceId,
) {
  final meta = chart['meta'];
  if (meta is! Map) throw SourceException(sourceId, 'No meta');
  if (meta['currency'] != currency) {
    throw SourceException(sourceId, 'Unexpected currency ${meta['currency']}');
  }
  final t = meta['regularMarketTime'];
  if (t is! int) throw SourceException(sourceId, 'No quote time');
  return (
    price: priceFromJson(meta['regularMarketPrice'], sourceId),
    time: _epoch(t),
  );
}

/// Daily closes keyed by Istanbul date; null closes are skipped.
Map<DateTime, Decimal> yahooHistory(
  Map<String, Object?> chart,
  String sourceId,
) {
  final ts = chart['timestamp'];
  final ind = chart['indicators'];
  final quote = ind is Map ? ind['quote'] : null;
  final close = quote is List && quote.isNotEmpty && quote.first is Map
      ? (quote.first as Map)['close']
      : null;
  if (ts is! List || close is! List || ts.length != close.length) {
    throw SourceException(sourceId, 'Malformed history');
  }
  return {
    for (var i = 0; i < ts.length; i++)
      if (close[i] != null)
        istanbulToday(_epoch(ts[i] as int)): priceFromJson(close[i], sourceId),
  };
}

class YahooSource implements PriceSource {
  YahooSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'yahoo';
  @override
  String get label => 'Yahoo Finance';
  @override
  List<String> get domains => const [yahooHost];
  @override
  Set<AssetClass> get assetClasses => const {
    AssetClass.bistShare,
    AssetClass.fx,
  };

  static String? _symbol(Instrument i) => switch (i.assetClass) {
    AssetClass.bistShare => '${i.code}.IS',
    AssetClass.fx => '${i.code}TRY=X',
    _ => null,
  };

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final out = <PriceObservation>[];
    SourceException? last;
    var tried = 0;
    for (final i in instruments) {
      final sym = _symbol(i);
      if (sym == null) continue;
      tried++;
      try {
        final q = yahooQuote(
          await fetchYahooChart(_c, sym, timeout: timeout),
          'TRY',
          id,
        );
        out.add(
          PriceObservation(
            instrumentId: i.id,
            price: q.price,
            sessionDate: istanbulToday(q.time),
            quoteTime: q.time,
            receivedAt: _now(),
            source: id,
            kind: PriceKind.delayedQuote,
          ),
        );
      } on SourceException catch (e) {
        last = e;
      }
    }
    // One delisted ticker must not hide the others.
    if (tried > 0 && out.isEmpty) throw last!;
    return out;
  }

  // Yahoo history is split-adjusted, so it must not feed cost-basis valuation.
  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async => const [];
}
