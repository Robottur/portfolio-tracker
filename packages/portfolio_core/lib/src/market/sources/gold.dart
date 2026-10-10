import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;

import '../../dates.dart';
import '../../decimal_util.dart';
import '../../model/instrument.dart';
import '../price.dart';
import '../source.dart';
import 'yahoo.dart';

final _gramsPerOunce = Decimal.parse('31.1034768');

/// Gram gold in TRY = GC=F (USD/oz) x USDTRY=X / grams per troy ounce.
Decimal _gram(Decimal ounceUsd, Decimal usdTry) =>
    divide(ounceUsd * usdTry, _gramsPerOunce);

class GoldSource implements PriceSource {
  GoldSource(
    this._c, {
    DateTime Function()? nowUtc,
    this.timeout = requestTimeout,
  }) : _now = nowUtc ?? (() => DateTime.now().toUtc());

  final http.Client _c;
  final DateTime Function() _now;
  final Duration timeout;

  @override
  String get id => 'gold';
  @override
  String get label => 'Gold (derived)';
  @override
  List<String> get domains => const [yahooHost];
  @override
  Set<AssetClass> get assetClasses => const {AssetClass.gold};

  Future<(Map<String, Object?>, Map<String, Object?>)> _charts({
    DateTime? from,
    DateTime? to,
  }) async {
    final gc = await fetchYahooChart(
      _c,
      'GC=F',
      from: from,
      to: to,
      sourceId: id,
      timeout: timeout,
    );
    final fx = await fetchYahooChart(
      _c,
      'USDTRY=X',
      from: from,
      to: to,
      sourceId: id,
      timeout: timeout,
    );
    return (gc, fx);
  }

  @override
  Future<List<PriceObservation>> latest(List<Instrument> instruments) async {
    final wanted = instruments.where((i) => i.id == 'GOLD:GRAM');
    if (wanted.isEmpty) return const [];
    final (gcChart, fxChart) = await _charts();
    final gc = yahooQuote(gcChart, 'USD', id);
    final fx = yahooQuote(fxChart, 'TRY', id);
    final a = istanbulToday(gc.time), b = istanbulToday(fx.time);
    return [
      PriceObservation(
        instrumentId: 'GOLD:GRAM',
        price: _gram(gc.price, fx.price),
        sessionDate: a.isAfter(b) ? a : b,
        // Older quote: the conservative claim about how fresh the price is.
        quoteTime: gc.time.isBefore(fx.time) ? gc.time : fx.time,
        receivedAt: _now(),
        source: id,
        kind: PriceKind.derived,
      ),
    ];
  }

  @override
  Future<List<PriceObservation>> closes(
    Instrument instrument,
    DateTime from,
    DateTime to,
  ) async {
    if (instrument.id != 'GOLD:GRAM') return const [];
    final (gcChart, fxChart) = await _charts(from: from, to: to);
    final gc = yahooHistory(gcChart, id), fx = yahooHistory(fxChart, id);
    final received = _now();
    // Today's bar is still forming; it is not a close.
    final today = istanbulToday(received);
    final days =
        gc.keys
            .where(
              (d) =>
                  fx.containsKey(d) &&
                  !d.isBefore(from) &&
                  !d.isAfter(to) &&
                  d.isBefore(today),
            )
            .toList()
          ..sort();
    return [
      for (final d in days)
        PriceObservation(
          instrumentId: instrument.id,
          price: _gram(gc[d]!, fx[d]!),
          sessionDate: d,
          quoteTime: null,
          receivedAt: received,
          source: id,
          kind: PriceKind.derived,
        ),
    ];
  }
}
