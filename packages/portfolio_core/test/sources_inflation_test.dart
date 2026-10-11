import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:test/test.dart';

void main() {
  final page = File('test/fixtures/tcmb_cpi_page.html').readAsStringSync();
  final evds = File('test/fixtures/evds_cpi.json').readAsStringSync();

  http.Response html(String body) => http.Response.bytes(
    utf8.encode(body),
    200,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );

  group('tcmb page', () {
    test('tcmb page fixture parses', () async {
      final s = TcmbCpiSource(MockClient((_) async => html(page)));
      final m = await s.monthly(date(2026, 1, 1));
      expect(m['2026-09'], Decimal.parse('1.84'));
      expect(m['2026-08'], Decimal.parse('1.84'));
      expect(m['2005-01'], Decimal.parse('0.55'));
      expect(
        m.length,
        RegExp(r'<td[^>]*>\s*\d{2}-\d{4}').allMatches(page).length,
      );
      expect(s.assetClasses, isEmpty);
      expect(s.domains, ['www.tcmb.gov.tr']);
      expect(await s.latest([]), isEmpty);
    });

    test('changed header throws the exact message', () async {
      final s = TcmbCpiSource(
        MockClient((_) async => html(page.replaceFirst('Ay-Yıl', 'Ay-Yil'))),
      );
      await expectLater(
        s.monthly(date(2026, 1, 1)),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            'TCMB inflation page changed — enter months manually',
          ),
        ),
      );
    });

    test('malformed row throws', () async {
      final s = TcmbCpiSource(
        MockClient((_) async => html(page.replaceFirst('>1.84<', '>n/a<'))),
      );
      await expectLater(
        s.monthly(date(2026, 1, 1)),
        throwsA(isA<SourceException>()),
      );
    });
  });

  group('evds', () {
    test('evds parses levels into monthly %', () async {
      late http.BaseRequest req;
      final s = EvdsSource(
        MockClient((r) async {
          req = r;
          return http.Response(evds, 200);
        }),
        key: () => ' k3y ',
        nowUtc: () => DateTime.utc(2026, 10, 11),
      );
      final m = await s.monthly(date(2026, 8, 15));
      expect(m, {'2026-08': Decimal.parse('1.84')});
      expect(req.url.toString(), contains('startDate=01-07-2026'));
      expect(req.url.toString(), contains('endDate=01-10-2026'));
      expect(req.url.toString(), contains('series=$evdsCpiSeries'));
      expect(req.headers['key'], 'k3y');
    });

    test('empty key makes no request', () async {
      var calls = 0;
      final s = EvdsSource(
        MockClient((_) async {
          calls++;
          return http.Response(evds, 200);
        }),
        key: () => '  ',
      );
      await expectLater(
        s.monthly(date(2026, 8, 1)),
        throwsA(
          isA<SourceException>().having(
            (e) => e.message,
            'message',
            'Add your EVDS key in Settings',
          ),
        ),
      );
      expect(calls, 0);
    });

    test('rejected key', () async {
      for (final code in [401, 403]) {
        final s = EvdsSource(
          MockClient((_) async => http.Response('nope', code)),
          key: () => 'sekret-key',
        );
        try {
          await s.monthly(date(2026, 8, 1));
          fail('should throw');
        } on SourceException catch (e) {
          expect(e.message, 'EVDS rejected the key');
          expect(e.toString(), isNot(contains('sekret-key')));
        }
      }
    });

    test('other failures never carry the key', () async {
      final s = EvdsSource(
        MockClient((_) async => throw http.ClientException('x sekret-key')),
        key: () => 'sekret-key',
      );
      try {
        await s.monthly(date(2026, 8, 1));
        fail('should throw');
      } on SourceException catch (e) {
        expect(e.toString(), isNot(contains('sekret-key')));
      }
    });
  });
}
