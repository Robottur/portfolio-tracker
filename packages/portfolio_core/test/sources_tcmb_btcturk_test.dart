import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

String fx(String n) => File('test/fixtures/$n').readAsStringSync();
final now = DateTime.utc(2026, 10, 10, 12);
DateTime nowUtc() => now;
final usd = Instrument.create(AssetClass.fx, 'USD');
final jpy = Instrument.create(AssetClass.fx, 'JPY');
final xyz = Instrument.create(AssetClass.fx, 'XYZ');
final btc = Instrument.create(AssetClass.crypto, 'BTC');
final eth = Instrument.create(AssetClass.crypto, 'ETH');

http.Response ok(String b) => http.Response.bytes(utf8.encode(b), 200);

MockClient routes(Map<String, http.Response Function()> r, [List<Uri>? log]) =>
    MockClient((req) async {
      log?.add(req.url);
      for (final e in r.entries) {
        if (req.url.toString().contains(e.key)) return e.value();
      }
      return http.Response('', 404);
    });

void main() {
  group('TCMB', () {
    test('latest: USD, JPY per unit, unknown code skipped', () async {
      final log = <Uri>[];
      final s = TcmbSource(
        routes({'today.xml': () => ok(fx('tcmb_09102026.xml'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.latest([usd, jpy, xyz]);
      expect(log.single.path, '/kurlar/today.xml');
      expect(r.map((o) => o.instrumentId), ['FX:USD', 'FX:JPY']);
      expect(r[0].price, Decimal.parse('49.1274'));
      expect(r[0].kind, PriceKind.close);
      expect(r[0].quoteTime, isNull);
      expect(r[0].sessionDate, DateTime.utc(2026, 10, 9));
      expect(r[1].price, lessThan(Decimal.one));
      expect(r[1].price * Decimal.fromInt(100), isNot(Decimal.zero));
    });

    test('latest: none present -> empty', () async {
      final s = TcmbSource(
        routes({'today.xml': () => ok(fx('tcmb_09102026.xml'))}),
        nowUtc: nowUtc,
      );
      expect(await s.latest([xyz]), isEmpty);
    });

    test('closes walks back over 404 to the 9th', () async {
      final log = <Uri>[];
      final s = TcmbSource(
        routes({'202610/09102026.xml': () => ok(fx('tcmb_09102026.xml'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.closes(
        usd,
        DateTime.utc(2026, 10, 3),
        DateTime.utc(2026, 10, 10),
      );
      expect(log.map((u) => u.path), [
        '/kurlar/202610/10102026.xml',
        '/kurlar/202610/09102026.xml',
      ]);
      expect(r.single.sessionDate, DateTime.utc(2026, 10, 9));
      expect(r.single.price, Decimal.parse('49.1274'));
    });

    test('closes: identity mismatch, malformed xml, html', () async {
      for (final body in [
        fx('tcmb_09102026.xml').replaceFirst('10/09/2026', '10/08/2026'),
        '<Tarih_Date Date="10/09/2026"><Currency',
        '<html>blocked</html>',
      ]) {
        final s = TcmbSource(routes({'.xml': () => ok(body)}), nowUtc: nowUtc);
        await expectLater(
          s.closes(usd, DateTime.utc(2026, 10, 9), DateTime.utc(2026, 10, 9)),
          throwsA(isA<SourceException>()),
        );
      }
    });

    test('closes caps the walk at 15 requests', () async {
      final log = <Uri>[];
      final s = TcmbSource(routes({}, log), nowUtc: nowUtc);
      final r = await s.closes(
        usd,
        DateTime.utc(2026, 1, 1),
        DateTime.utc(2026, 10, 10),
      );
      expect(r, isEmpty);
      expect(log, hasLength(15));
    });

    test('empty ForexBuying -> no observation', () async {
      final body = fx('tcmb_09102026.xml')
          .replaceFirst('<ForexBuying>49.1274</ForexBuying>', '<ForexBuying/>');
      final s = TcmbSource(
        routes({'today.xml': () => ok(body)}),
        nowUtc: nowUtc,
      );
      expect((await s.latest([usd, jpy])).map((o) => o.instrumentId), [
        'FX:JPY',
      ]);
    });

    test('429 surfaces retryAfter', () async {
      final s = TcmbSource(
        routes({
          'today.xml': () =>
              http.Response('', 429, headers: {'retry-after': '120'}),
        }),
        nowUtc: nowUtc,
      );
      await expectLater(
        s.latest([usd]),
        throwsA(
          isA<SourceException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });
  });

  group('BtcTurk', () {
    test('latest ticker', () async {
      final log = <Uri>[];
      final s = BtcTurkSource(
        routes({'/api/v2/ticker': () => ok(fx('btcturk_ticker.json'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.latest([btc]);
      expect(log.single.queryParameters, {'pairSymbol': 'BTCTRY'});
      expect(r.single.instrumentId, 'CRYPTO:BTC');
      expect(r.single.price, Decimal.parse('4090283'));
      expect(r.single.kind, PriceKind.delayedQuote);
      expect(
        r.single.quoteTime,
        DateTime.fromMillisecondsSinceEpoch(1791663765379, isUtc: true),
      );
    });

    test(
      'latest: failures skipped, all failed throws, pair mismatch',
      () async {
        final s = BtcTurkSource(
          routes({'BTCTRY': () => ok(fx('btcturk_ticker.json'))}),
          nowUtc: nowUtc,
        );
        expect((await s.latest([btc, eth])).single.instrumentId, 'CRYPTO:BTC');
        final bad = BtcTurkSource(
          routes({'ETHTRY': () => ok(fx('btcturk_ticker.json'))}),
          nowUtc: nowUtc,
        );
        await expectLater(bad.latest([eth]), throwsA(isA<SourceException>()));
      },
    );

    test('bad responses throw', () async {
      for (final body in [
        '{"success":false}',
        '{"success":true,"data":[]}',
        '<html></html>',
        fx('btcturk_ticker.json').replaceFirst('"last":4090283', '"last":0'),
        fx('btcturk_ticker.json').replaceFirst('"last":4090283', '"last":1e21'),
        fx('btcturk_ticker.json').replaceFirst('1791663765379', '5'),
      ]) {
        final s = BtcTurkSource(
          routes({'ticker': () => ok(body)}),
          nowUtc: nowUtc,
        );
        await expectLater(
          s.latest([btc]),
          throwsA(isA<SourceException>()),
          reason: body,
        );
      }
    });

    test('closes: last=N, no from/to, drops today, filters range', () async {
      final log = <Uri>[];
      final s = BtcTurkSource(
        routes({'/api/v2/ohlc': () => ok(fx('btcturk_ohlc.json'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.closes(
        btc,
        DateTime.utc(2026, 10, 6),
        DateTime.utc(2026, 10, 10),
      );
      expect(log.single.queryParameters, {'pairSymbol': 'BTCTRY', 'last': '6'});
      expect(r.map((o) => o.sessionDate), [
        DateTime.utc(2026, 10, 6),
        DateTime.utc(2026, 10, 7),
        DateTime.utc(2026, 10, 8),
        DateTime.utc(2026, 10, 9),
      ]);
      expect(r.last.price, Decimal.parse('4069516'));
      expect(r.last.kind, PriceKind.close);
    });

    test('closes: wrong pairSymbol rows skipped', () async {
      final body = fx('btcturk_ohlc.json').replaceAll('"BTCTRY"', '"ETHTRY"');
      final s = BtcTurkSource(routes({'ohlc': () => ok(body)}), nowUtc: nowUtc);
      expect(
        await s.closes(
          btc,
          DateTime.utc(2026, 10, 5),
          DateTime.utc(2026, 10, 9),
        ),
        isEmpty,
      );
    });

    test('429 surfaces retryAfter', () async {
      final s = BtcTurkSource(
        routes({
          'ticker': () =>
              http.Response('', 429, headers: {'retry-after': '120'}),
        }),
        nowUtc: nowUtc,
      );
      await expectLater(
        s.latest([btc]),
        throwsA(
          isA<SourceException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });
  });
}
