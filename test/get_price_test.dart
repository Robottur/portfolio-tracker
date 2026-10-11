import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(String body) =>
    http.Response(body, 200, headers: {'content-type': 'application/json'});

String _fx(String f) =>
    File('packages/portfolio_core/test/fixtures/$f').readAsStringSync();

void main() {
  late Directory tmp;
  late AppController c;
  late List<Uri> requests;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('gp');
    requests = [];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> boot(
    WidgetTester tester,
    http.Response Function(Uri) answer, {
    Set<String> enabled = const {},
    DateTime? now,
  }) async {
    tester.view.physicalSize = const Size(700, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final prefs = await DevicePrefs.load();
      await prefs.setEnabledSources(enabled);
      c = AppController(
        prefs: prefs,
        privateDir: tmp,
        network: MockClient((r) async {
          requests.add(r.url);
          return answer(r.url);
        }),
        nowUtc: () => now ?? DateTime.utc(2026, 10, 9, 20),
      );
      await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.tap(find.byIcon(Icons.receipt_long_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  Future<void> getPrice(WidgetTester tester) async {
    await tester.tap(find.text('Get price'));
    await settle(tester);
  }

  String price(WidgetTester tester) =>
      tester.widget<TextField>(find.byKey(const Key('price'))).controller!.text;

  http.Response routes(Uri u) => switch (u.host) {
    'query1.finance.yahoo.com' => _json(_fx('yahoo_thyao.json')),
    'www.isyatirim.com.tr' => _json(_fx('isyatirim_thyao.json')),
    _ => http.Response('', 404),
  };

  testWidgets('today fills the Yahoo price and says where it came from', (
    tester,
  ) async {
    await boot(tester, routes, enabled: {'yahoo'});
    await fill(tester, 'symbol', 'THYAO');
    await getPrice(tester);
    expect(price(tester), '287.5');
    expect(find.textContaining('Yahoo Finance'), findsWidgets);
  });

  testWidgets('a Sunday gets the Friday close, with its date', (tester) async {
    await boot(tester, routes, enabled: {'isyatirim'});
    await fill(tester, 'symbol', 'THYAO');
    await tester.tap(find.textContaining('Date  '));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('4'),
      ),
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await getPrice(tester);
    expect(price(tester), '292');
    expect(find.textContaining('2026-10-02'), findsOneWidget);
  });

  testWidgets('disabled source asks first; Cancel sends nothing', (
    tester,
  ) async {
    await boot(tester, routes);
    await fill(tester, 'symbol', 'THYAO');
    await tester.tap(find.text('Get price'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This sends THYAO to query1.finance.yahoo.com. '
        'Enable Yahoo Finance and fetch?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(requests, isEmpty);
    expect(c.prefs.enabledSources, isEmpty);
    expect(price(tester), '');
  });

  testWidgets('Enable and fetch enables the source and fills the field', (
    tester,
  ) async {
    await boot(tester, routes);
    await fill(tester, 'symbol', 'THYAO');
    await tester.tap(find.text('Get price'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enable and fetch'));
    await settle(tester);
    expect(c.prefs.enabledSources, contains('yahoo'));
    expect(price(tester), '287.5');
  });

  testWidgets('a TEFAS 429 shows the limit inline and fills nothing', (
    tester,
  ) async {
    await boot(
      tester,
      (_) => http.Response('', 429, headers: {'retry-after': '60'}),
      enabled: {'tefas'},
    );
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fund').last);
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', 'TTE');
    await getPrice(tester);
    expect(find.textContaining('TEFAS (funds):'), findsOneWidget);
    expect(price(tester), '');
  });

  testWidgets('a gold price is cut to 8 fractional digits', (tester) async {
    await boot(
      tester,
      (u) => _json(
        u.path.contains('USDTRY')
            ? _fx('yahoo_usdtry.json')
            : _fx('yahoo_gcf.json'),
      ),
      enabled: {'gold'},
    );
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gold').last);
    await tester.pumpAndSettle();
    await getPrice(tester);
    final frac = price(tester).split('.');
    expect(frac, hasLength(2));
    expect(frac[1].length, lessThanOrEqualTo(8));
  });
}
