import 'dart:async';
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
final thyao = Instrument.create(AssetClass.bistShare, 'THYAO');
final usd = Instrument.create(AssetClass.fx, 'USD');
final gram = Instrument.create(AssetClass.gold, 'GRAM');

http.Response json(String body, [int code = 200]) =>
    http.Response(body, code, headers: {'content-type': 'application/json'});

/// Routes by a substring of the request URL; first match wins.
MockClient routes(Map<String, http.Response Function()> r, [List<Uri>? log]) =>
    MockClient((req) async {
      log?.add(req.url);
      expect(req.headers['User-Agent'], 'Mozilla/5.0');
      for (final e in r.entries) {
        if (req.url.toString().contains(e.key)) return e.value();
      }
      return json('{}', 404);
    });

void main() {
  group('Yahoo', () {
    test('latest THYAO', () async {
      final log = <Uri>[];
      final s = YahooSource(
        routes({'THYAO.IS': () => json(fx('yahoo_thyao.json'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.latest([thyao]);
      expect(r, hasLength(1));
      expect(r.single.instrumentId, 'XIST:THYAO');
      expect(r.single.price, Decimal.parse('287.5'));
      expect(r.single.kind, PriceKind.delayedQuote);
      expect(r.single.source, 'yahoo');
      expect(r.single.receivedAt, now);
      expect(
        r.single.quoteTime,
        DateTime.fromMillisecondsSinceEpoch(1791558599 * 1000, isUtc: true),
      );
      expect(r.single.sessionDate, DateTime.utc(2026, 10, 9));
      expect(log.single.path, '/v8/finance/chart/THYAO.IS');
      expect(log.single.queryParameters, {'range': '1d', 'interval': '1d'});
    });

    test('FX symbol is USDTRY=X', () async {
      final log = <Uri>[];
      final s = YahooSource(
        routes({'USDTRY': () => json(fx('yahoo_usdtry.json'))}, log),
        nowUtc: nowUtc,
      );
      final r = await s.latest([usd]);
      expect(r.single.instrumentId, 'FX:USD');
      expect(r.single.price > Decimal.zero, isTrue);
      expect(log.single.path, contains('USDTRY=X'));
    });

    test('one failed instrument is skipped, all failed throws', () async {
      final c = routes({
        'THYAO.IS': () => json(fx('yahoo_thyao.json')),
        'XXXXX.IS': () => json(fx('yahoo_error.json')),
      });
      final s = YahooSource(c, nowUtc: nowUtc);
      final bad = Instrument.create(AssetClass.bistShare, 'XXXXX');
      expect((await s.latest([bad, thyao])), hasLength(1));
      expect(s.latest([bad]), throwsA(isA<SourceException>()));
    });

    test('HTML block page, error object, 429, 500 throw', () async {
      for (final resp in [
        http.Response(fx('html_block.html'), 200),
        json(fx('yahoo_error.json')),
        http.Response('', 429, headers: {'retry-after': '30'}),
        http.Response('', 500),
      ]) {
        final s = YahooSource(routes({'chart': () => resp}), nowUtc: nowUtc);
        expect(s.latest([thyao]), throwsA(isA<SourceException>()));
      }
    });

    test('429 carries retryAfter', () async {
      final s = YahooSource(
        routes({
          'chart': () => http.Response('', 429, headers: {'retry-after': '30'}),
        }),
        nowUtc: nowUtc,
      );
      await expectLater(
        s.latest([thyao]),
        throwsA(
          isA<SourceException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
    });

    test('non-TRY currency, zero price, exponent price are rejected', () async {
      Map<String, Object?> doc() =>
          jsonDecode(fx('yahoo_thyao.json')) as Map<String, Object?>;
      Map<String, Object?> meta(Map<String, Object?> d) =>
          (((d['chart'] as Map)['result'] as List).first as Map)['meta']
              as Map<String, Object?>;
      final variants = <Map<String, Object?>>[];
      var d = doc();
      meta(d)['currency'] = 'USD';
      variants.add(d);
      d = doc();
      meta(d)['regularMarketPrice'] = 0;
      variants.add(d);
      d = doc();
      meta(d)['regularMarketPrice'] = 1e-7;
      variants.add(d);
      d = doc();
      meta(d).remove('regularMarketTime');
      variants.add(d);
      for (final v in variants) {
        final s = YahooSource(
          routes({'chart': () => json(jsonEncode(v))}),
          nowUtc: nowUtc,
        );
        expect(s.latest([thyao]), throwsA(isA<SourceException>()));
      }
    });

    test('bad quote time next to a good instrument', () async {
      final d = jsonDecode(fx('yahoo_thyao.json')) as Map<String, Object?>;
      final meta =
          (((d['chart'] as Map)['result'] as List).first as Map)['meta'] as Map;
      meta['symbol'] = 'ASELS.IS';
      meta['regularMarketTime'] = 99999999999999;
      final s = YahooSource(
        routes({
          'ASELS.IS': () => json(jsonEncode(d)),
          'THYAO.IS': () => json(fx('yahoo_thyao.json')),
        }),
        nowUtc: nowUtc,
      );
      final asels = Instrument.create(AssetClass.bistShare, 'ASELS');
      final r = await s.latest([asels, thyao]);
      expect(r.map((o) => o.instrumentId), ['XIST:THYAO']);
    });

    test('meta.symbol mismatch skips the instrument', () async {
      final s = YahooSource(
        routes({'ASELS.IS': () => json(fx('yahoo_thyao.json'))}),
        nowUtc: nowUtc,
      );
      final asels = Instrument.create(AssetClass.bistShare, 'ASELS');
      expect(s.latest([asels]), throwsA(isA<SourceException>()));
    });

    test('closes is empty without a request', () async {
      final s = YahooSource(MockClient((_) => fail('network')), nowUtc: nowUtc);
      expect(
        await s.closes(
          thyao,
          DateTime.utc(2026, 9, 1),
          DateTime.utc(2026, 10, 1),
        ),
        isEmpty,
      );
    });

    test('timeout becomes SourceException', () async {
      final s = YahooSource(
        MockClient((_) => Completer<http.Response>().future),
        nowUtc: nowUtc,
        timeout: const Duration(milliseconds: 20),
      );
      expect(s.latest([thyao]), throwsA(isA<SourceException>()));
    });
  });

  group('Is Yatirim', () {
    IsYatirimSource src(http.Response Function() r, [List<Uri>? log]) =>
        IsYatirimSource(routes({'HisseTekil': r}, log), nowUtc: nowUtc);
    final from = DateTime.utc(2026, 9, 29), to = DateTime.utc(2026, 10, 9);

    test('closes use HG_KAPANIS and fixture dates', () async {
      final log = <Uri>[];
      final r = await src(
        () => json(fx('isyatirim_thyao.json')),
        log,
      ).closes(thyao, from, to);
      final rows = (jsonDecode(fx('isyatirim_thyao.json'))['value'] as List);
      expect(r, hasLength(rows.length));
      expect(r.first.sessionDate, DateTime.utc(2026, 9, 29));
      expect(r.first.price, Decimal.parse('291.5'));
      expect(r.last.sessionDate, DateTime.utc(2026, 10, 9));
      expect(r.first.kind, PriceKind.close);
      expect(r.first.source, 'isyatirim');
      expect(r.first.quoteTime, isNull);
      expect(log.single.queryParameters, {
        'hisse': 'THYAO',
        'startdate': '29-09-2026',
        'enddate': '09-10-2026',
      });
    });

    test('failures throw, empty list is empty', () async {
      for (final body in [
        fx('html_block.html'),
        '{"ok":false}',
        '{"ok":true}',
        '{"ok":true,"value":[{"HGDG_HS_KODU":"THYAO","HGDG_TARIH":"29-09-2026","HG_KAPANIS":0}]}',
      ]) {
        expect(
          src(() => json(body)).closes(thyao, from, to),
          throwsA(isA<SourceException>()),
        );
      }
      expect(
        await src(() => json('{"ok":true,"value":[]}')).closes(thyao, from, to),
        isEmpty,
      );
    });

    test('rows of another symbol are skipped', () async {
      final d = jsonDecode(fx('isyatirim_thyao.json')) as Map;
      ((d['value'] as List).first as Map)['HGDG_HS_KODU'] = 'ASELS';
      final r = await src(() => json(jsonEncode(d))).closes(thyao, from, to);
      expect(r, hasLength(8));
      expect(r.first.sessionDate, DateTime.utc(2026, 9, 30));
    });

    test('latest is empty', () async {
      expect(await src(() => json('{}')).latest([thyao]), isEmpty);
    });
  });

  group('Gold', () {
    final div = Decimal.parse('31.1034768');
    final routesOk = {
      'GC=F': () => json(fx('yahoo_gcf.json')),
      'USDTRY=X': () => json(fx('yahoo_usdtry.json')),
    };

    test('latest = GC x USDTRY / 31.1034768', () async {
      Decimal meta(String f) => Decimal.parse(
        (jsonDecode(fx(f))['chart']['result'][0]['meta']['regularMarketPrice']
                as num)
            .toString(),
      );
      final r = await GoldSource(
        routes(routesOk),
        nowUtc: nowUtc,
      ).latest([gram]);
      expect(r, hasLength(1));
      expect(
        r.single.price,
        divide(meta('yahoo_gcf.json') * meta('yahoo_usdtry.json'), div),
      );
      // An intraday snapshot, never a close for its session date.
      expect(r.single.kind, PriceKind.delayedQuote);
      expect(r.single.source, 'gold');
      expect(r.single.instrumentId, 'GOLD:GRAM');
      expect(isStorablePrice(r.single.price), isTrue);
    });

    test('latest needs both quotes', () async {
      final s = GoldSource(
        routes({...routesOk, 'USDTRY=X': () => json(fx('yahoo_error.json'))}),
        nowUtc: nowUtc,
      );
      expect(s.latest([gram]), throwsA(isA<SourceException>()));
    });

    String hist(List<Object?> ts, List<Object?> cl) => jsonEncode({
      'chart': {
        'result': [
          {
            'meta': {},
            'timestamp': ts,
            'indicators': {
              'quote': [
                {'close': cl},
              ],
            },
          },
        ],
      },
    });

    test('closes request starts one day before from', () async {
      final log = <Uri>[];
      final s = GoldSource(
        routes({'chart': () => json(hist([], []))}, log),
        nowUtc: nowUtc,
      );
      await s.closes(
        gram,
        DateTime.utc(2026, 9, 29),
        DateTime.utc(2026, 10, 9),
      );
      final from = DateTime.utc(2026, 9, 28).millisecondsSinceEpoch ~/ 1000;
      expect(
        log.map((u) => u.queryParameters['period1']),
        everyElement('$from'),
      );
    });

    test('closes exclude today and keep the later bar of a date', () async {
      // 2026-10-09 08:00Z and 10:00Z share an Istanbul date; 10-10 is today.
      final t1 = DateTime.utc(2026, 10, 9, 8).millisecondsSinceEpoch ~/ 1000;
      final t2 = DateTime.utc(2026, 10, 9, 10).millisecondsSinceEpoch ~/ 1000;
      final t3 = DateTime.utc(2026, 10, 10, 8).millisecondsSinceEpoch ~/ 1000;
      final s = GoldSource(
        routes({
          'GC=F': () => json(hist([t1, t2, t3], [4000.0, 4100.0, 4200.0])),
          'USDTRY=X': () => json(hist([t1, t2, t3], [40.0, 41.0, 42.0])),
        }),
        nowUtc: nowUtc,
      );
      final r = await s.closes(
        gram,
        DateTime.utc(2026, 10, 9),
        DateTime.utc(2026, 10, 10),
      );
      expect(r.map((o) => o.sessionDate), [DateTime.utc(2026, 10, 9)]);
      expect(
        r.single.price,
        divide(Decimal.parse('4100') * Decimal.parse('41'), div),
      );
    });

    test('non-int history timestamp is a SourceException', () async {
      final s = GoldSource(
        routes({
          'chart': () => json(hist([1.5e9], [1.0])),
        }),
        nowUtc: nowUtc,
      );
      expect(
        s.closes(gram, DateTime.utc(2026, 9, 1), DateTime.utc(2026, 10, 1)),
        throwsA(isA<SourceException>()),
      );
    });

    test('closes join on Istanbul date', () async {
      List<(DateTime, double)> rows(String f) {
        final r = jsonDecode(fx(f))['chart']['result'][0];
        final ts = r['timestamp'] as List;
        final cl = r['indicators']['quote'][0]['close'] as List;
        return [
          for (var i = 0; i < ts.length; i++)
            if (cl[i] != null)
              (
                istanbulToday(
                  DateTime.fromMillisecondsSinceEpoch(
                    (ts[i] as int) * 1000,
                    isUtc: true,
                  ),
                ),
                (cl[i] as num).toDouble(),
              ),
        ];
      }

      final g = {for (final e in rows('yahoo_gcf_history.json')) e.$1: e.$2};
      final u = {for (final e in rows('yahoo_usdtry_history.json')) e.$1: e.$2};
      final common = g.keys.where(u.containsKey).toList()..sort();
      final s = GoldSource(
        routes({
          'GC=F': () => json(fx('yahoo_gcf_history.json')),
          'USDTRY=X': () => json(fx('yahoo_usdtry_history.json')),
        }),
        nowUtc: nowUtc,
      );
      final r = await s.closes(
        gram,
        DateTime.utc(2026, 9, 29),
        DateTime.utc(2026, 10, 10),
      );
      expect(common, isNotEmpty);
      expect(r.map((o) => o.sessionDate).toList(), common);
      expect(
        r.first.price,
        divide(
          Decimal.parse(g[common.first].toString()) *
              Decimal.parse(u[common.first].toString()),
          div,
        ),
      );
      expect(r.first.kind, PriceKind.derived);
      expect(r.first.quoteTime, isNull);
    });
  });
}
