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

  test('a 40-day window is two requests', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    await s.closes(tte, date(2026, 9, 1), date(2026, 10, 10));
    expect(reqs, hasLength(2));
    final first = jsonDecode(reqs.first.body) as Map;
    expect(first['bitTarih'], '20261010');
  });

  test('latest takes the newest row from a 10-day window', () async {
    final s = make((_) => _fx('tefas_tte_yat.json'));
    final r = await s.latest([tte]);
    expect(r.single.price, Decimal.parse('1.157776'));
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
}
