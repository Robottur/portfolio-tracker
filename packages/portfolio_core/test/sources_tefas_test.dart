import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

String _fx(String n) => File('test/fixtures/$n').readAsStringSync();
http.Response _json(String body) => http.Response(
  body,
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

final tte = Instrument.create(AssetClass.fund, 'TTE');

void main() {
  late List<http.Request> reqs;
  TefasSource make(
    String Function(Map<String, dynamic> body) serve, {
    String? Function(String)? knownKind,
    Future<void> Function(String, String)? rememberKind,
  }) {
    reqs = [];
    return TefasSource(
      MockClient((r) async {
        reqs.add(r);
        return _json(serve(jsonDecode(r.body) as Map<String, dynamic>));
      }),
      nowUtc: () => testNow,
      knownKind: knownKind,
      rememberKind: rememberKind,
    );
  }

  test('closes parses the fixture', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    final r = await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9));
    expect(r, hasLength(7));
    final newest = r.reduce(
      (a, b) => a.sessionDate.isAfter(b.sessionDate) ? a : b,
    );
    expect(newest.price, Decimal.parse('1.157776'));
    expect(newest.sessionDate, date(2026, 10, 9));
    expect(
      r.every((o) => o.kind == PriceKind.close && o.source == 'tefas'),
      isTrue,
    );
    expect(r.first.instrumentId, 'TEFAS:TTE');
  });

  test('request carries headers and body fields', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9));
    final q = reqs.single;
    expect(
      q.url.toString(),
      'https://www.tefas.gov.tr/api/funds/fonGnlBlgSiraliGetir',
    );
    expect(q.headers['Origin'], 'https://www.tefas.gov.tr');
    expect(q.headers['Referer'], 'https://www.tefas.gov.tr/tr/fon-verileri');
    final b = jsonDecode(q.body) as Map;
    expect(b['basTarih'], '20261001');
    expect(b['bitTarih'], '20261009');
    expect(b['fonKodu'], 'TTE');
    expect(b['fonTipi'], 'YAT');
    expect(b['dil'], 'TR');
  });

  test('guesses the kind, remembers it, then reuses it', () async {
    final remembered = <String>[];
    String serve(Map<String, dynamic> b) => b['fonTipi'] == 'EMK'
        ? _fx('tefas_tte_yat.json')
        : _fx('tefas_empty.json');
    final s = make(
      serve,
      rememberKind: (c, k) async => remembered.add('$c:$k'),
    );
    final r = await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9));
    expect(r, isNotEmpty);
    expect(remembered, ['TTE:EMK']);
    final s2 = make(serve, knownKind: (_) => 'EMK');
    await s2.closes(tte, date(2026, 10, 1), date(2026, 10, 9));
    expect(reqs, hasLength(1));
    expect(jsonDecode(reqs.single.body)['fonTipi'], 'EMK');
  });

  test('all kinds empty gives an empty list', () async {
    final s = make((_) => _fx('tefas_empty.json'));
    expect(await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)), isEmpty);
    expect(
      [for (final q in reqs) jsonDecode(q.body)['fonTipi']],
      ['YAT', 'EMK', 'BYF'],
    );
  });

  test('known kind that is empty is not re-guessed', () async {
    final s = make((_) => _fx('tefas_empty.json'), knownKind: (_) => 'YAT');
    expect(await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)), isEmpty);
    expect(reqs, hasLength(1));
  });

  test('error body is an error without server text', () async {
    final s = make(
      (_) => '{"errorMessage":"something else","resultList":null}',
    );
    await expectLater(
      s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'message',
          isNot(contains('something else')),
        ),
      ),
    );
  });

  test('429 keeps Retry-After', () async {
    final s = TefasSource(
      MockClient(
        (_) async => http.Response('', 429, headers: {'retry-after': '60'}),
      ),
      nowUtc: () => testNow,
    );
    await expectLater(
      s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)),
      throwsA(
        isA<SourceException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 60),
        ),
      ),
    );
  });

  group('429 back-off', () {
    Future<Duration?> retryFor(Map<String, String> headers) async {
      final s = TefasSource(
        MockClient((_) async => http.Response('', 429, headers: headers)),
        nowUtc: () => testNow,
      );
      try {
        await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9));
      } on SourceException catch (e) {
        return e.retryAfter;
      }
      return null;
    }

    test('no headers: 60 s', () async {
      expect(await retryFor({}), const Duration(seconds: 60));
    });
    test('ratelimit-reset seconds', () async {
      expect(
        await retryFor({'ratelimit-reset': '42'}),
        const Duration(seconds: 42),
      );
    });
    test('Retry-After is clamped to an hour', () async {
      expect(
        await retryFor({'retry-after': '99999'}),
        const Duration(seconds: 3600),
      );
    });
  });

  test('latest returns every in-window row', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    final r = await s.latest([tte]);
    expect(r, hasLength(7));
    expect(r.every((o) => o.kind == PriceKind.close), isTrue);
  });

  test('rows for another code do not set or remember a kind', () async {
    final remembered = <String>[];
    final s = make(
      (_) => _fx('tefas_tte_yat.json').replaceAll('"TTE"', '"OTH"'),
      rememberKind: (c, k) async => remembered.add('$c:$k'),
    );
    expect(await s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)), isEmpty);
    expect(remembered, isEmpty);
    // Nothing matched, so every kind was still tried.
    expect(reqs, hasLength(3));
  });

  test('a 40-day window is two requests', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    await s.closes(tte, date(2026, 9, 1), date(2026, 10, 10));
    expect(
      [
        for (final q in reqs)
          '${jsonDecode(q.body)['basTarih']}-${jsonDecode(q.body)['bitTarih']}',
      ],
      ['20260912-20261010', '20260901-20260911'],
    );
  });

  test('latest requests a 10-day window', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    await s.latest([tte]);
    final b = jsonDecode(reqs.single.body) as Map;
    expect(b['basTarih'], '20260930');
    expect(b['bitTarih'], '20261010');
  });

  test('latest throws only if every fund failed', () async {
    final s = make((_) => _fx('tefas_empty.json'));
    // empty everywhere is not a failure, just no price
    expect(await s.latest([tte]), isEmpty);
    final bad = make((_) => '{"errorMessage":"x","resultList":null}');
    await expectLater(bad.latest([tte]), throwsA(isA<SourceException>()));
  });

  test('consent denial surfaces as itself', () {
    final s = TefasSource(
      ConsentClient(MockClient((_) => fail('network')), () => {}),
    );
    expect(
      s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)),
      throwsA(isA<ConsentDeniedException>()),
    );
  });

  test('a 429 on the first fund stops latest at once', () async {
    reqs = [];
    final s = TefasSource(
      MockClient((r) async {
        reqs.add(r);
        return http.Response('', 429, headers: {'retry-after': '60'});
      }),
      nowUtc: () => testNow,
    );
    await expectLater(
      s.latest([tte, Instrument.create(AssetClass.fund, 'AFT')]),
      throwsA(
        isA<SourceException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 60),
        ),
      ),
    );
    expect(reqs, hasLength(1));
  });

  test('errorMessage with an empty list is an error, one request', () async {
    final s = make((_) => '{"resultList":[],"errorMessage":"boom"}');
    await expectLater(
      s.closes(tte, date(2026, 10, 1), date(2026, 10, 9)),
      throwsA(
        isA<SourceException>().having(
          (e) => e.message,
          'message',
          'TEFAS error',
        ),
      ),
    );
    expect(reqs, hasLength(1));
  });

  test('rows for another fund do not remember the kind', () async {
    final remembered = <String>[];
    final s = make(
      (_) => _fx('tefas_tte_yat.json'),
      rememberKind: (c, k) async => remembered.add(k),
    );
    final r = await s.closes(
      Instrument.create(AssetClass.fund, 'AFT'),
      date(2026, 10, 1),
      date(2026, 10, 9),
    );
    expect(r, isEmpty);
    expect(remembered, isEmpty);
  });
}
