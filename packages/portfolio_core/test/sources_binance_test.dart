import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();
final btc = Instrument.create(AssetClass.crypto, 'BTC');
http.Response ok(String b) => http.Response.bytes(utf8.encode(b), 200);

BinanceSource make(
  http.Response Function(Uri) r, {
  DateTime? now,
  List<Uri>? log,
}) => BinanceSource(
  MockClient((req) async {
    log?.add(req.url);
    return r(req.url);
  }),
  nowUtc: () => now ?? DateTime.utc(2026, 10, 12),
);

void main() {
  test('price fixture parses', () async {
    final log = <Uri>[];
    final s = make(
      (_) => ok(fx('binance_btctry_price.json')),
      now: DateTime.utc(2026, 10, 11, 22),
      log: log,
    );
    final r = await s.latest([btc]);
    expect(log.single.host, 'api.binance.com');
    expect(log.single.queryParameters, {'symbol': 'BTCTRY'});
    expect(r.single.price, Decimal.parse('4124203.00000000'));
    expect(r.single.kind, PriceKind.delayedQuote);
    expect(r.single.source, 'binance');
    expect(r.single.sessionDate, DateTime.utc(2026, 10, 12));
    expect(r.single.quoteTime, DateTime.utc(2026, 10, 11, 22));
  });

  test('invalid symbol is not listed', () async {
    final s = make(
      (_) => http.Response(fx('binance_invalid_symbol.json'), 400),
    );
    expect(await s.latest([btc]), isEmpty);
  });

  test('other 400 is an error', () async {
    final s = make((_) => http.Response('{"code":-1100,"msg":"x"}', 400));
    await expectLater(s.latest([btc]), throwsA(isA<SourceException>()));
  });

  test('klines fixture parses', () async {
    final log = <Uri>[];
    final s = make((_) => ok(fx('binance_btctry_klines.json')), log: log);
    final r = await s.closes(
      btc,
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 11),
    );
    expect(log.single.queryParameters, {
      'symbol': 'BTCTRY',
      'interval': '1d',
      'startTime': '${DateTime.utc(2026, 10, 9).millisecondsSinceEpoch}',
      'endTime': '${DateTime.utc(2026, 10, 12).millisecondsSinceEpoch - 1}',
    });
    expect(r.map((o) => o.sessionDate), [
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 10),
      DateTime.utc(2026, 10, 11),
    ]);
    expect(r.map((o) => o.price), [
      Decimal.parse('4065859.00000000'),
      Decimal.parse('4083989.00000000'),
      Decimal.parse('4124203.00000000'),
    ]);
    expect(r.every((o) => o.kind == PriceKind.close), isTrue);
  });

  test('closes leaves out the live UTC day', () async {
    final s = make(
      (_) => ok(fx('binance_btctry_klines.json')),
      now: DateTime.utc(2026, 10, 11, 12),
    );
    final r = await s.closes(
      btc,
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 11),
    );
    expect(r.map((o) => o.sessionDate), [
      DateTime.utc(2026, 10, 9),
      DateTime.utc(2026, 10, 10),
    ]);
  });

  test('429 and 418 back off', () async {
    for (final (code, h, secs) in [
      (429, {'retry-after': '120'}, 120),
      (418, {'retry-after': '300'}, 300),
      (418, <String, String>{}, 60),
      (418, {'retry-after': '99999'}, 3600),
    ]) {
      final s = make((_) => http.Response('', code, headers: h));
      await expectLater(
        s.latest([btc]),
        throwsA(
          isA<SourceException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            Duration(seconds: secs),
          ),
        ),
      );
    }
  });
}
