import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
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
    Future<void>? gate,
    Future<void> Function()? seed,
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
          await gate;
          return answer(r.url);
        }),
        nowUtc: () => now ?? DateTime.utc(2026, 10, 9, 20),
      );
      await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
      await seed?.call();
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

  testWidgets('gold consent names gold prices, not the symbol', (tester) async {
    await boot(tester, routes);
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gold').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get price'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This sends gold prices to query1.finance.yahoo.com. '
        'Enable Gold (derived) and fetch?',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await settle(tester);
  });

  testWidgets('the note names the source that answered', (tester) async {
    final gate = Completer<void>();
    await boot(
      tester,
      (u) => _json(
        u.host == 'query1.finance.yahoo.com'
            ? _fx('yahoo_usdtry.json')
            : '<x/>',
      ),
      enabled: {'tcmb'},
      gate: gate.future,
      seed: () async {
        await c.addTransaction(
          Transaction.buy(
            instrument: Instrument.create(AssetClass.fx, 'USD'),
            date: DateTime.utc(2026, 10, 1),
            dayOrder: 10,
            quantity: Decimal.parse('10'),
            unitPrice: Decimal.parse('1'),
            fees: Decimal.zero,
          ),
        );
        // Holds the price queue so the press below is decided later.
        unawaited(c.refreshPrices(manual: true));
      },
    );
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Currency').last);
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', 'USD');
    await tester.tap(find.text('Get price'));
    await tester.pump();
    await tester.runAsync(() async {
      await c.prefs.setEnabledSources({'tcmb', 'yahoo'});
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
    expect(find.textContaining('Yahoo Finance'), findsOneWidget);
    expect(find.textContaining('TCMB'), findsNothing);
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
    Decimal meta(String f) => Decimal.parse(
      (jsonDecode(_fx(f))['chart']['result'][0]['meta']['regularMarketPrice']
              as num)
          .toString(),
    );
    final raw = divide(
      meta('yahoo_gcf.json') * meta('yahoo_usdtry.json'),
      Decimal.parse('31.1034768'),
    );
    expect(raw.scale, greaterThan(8));
    expect(price(tester), roundHalfEven(raw, 8).toString());
  });

  testWidgets('a second press after a 429 sends nothing; refresh stays off', (
    tester,
  ) async {
    await boot(
      tester,
      (_) => http.Response('', 429, headers: {'retry-after': '60'}),
      enabled: {'tefas'},
      seed: () async {
        await c.addTransaction(
          Transaction.buy(
            instrument: Instrument.create(AssetClass.fund, 'TTE'),
            date: DateTime.utc(2026, 10, 1),
            dayOrder: 10,
            quantity: Decimal.parse('10'),
            unitPrice: Decimal.parse('1'),
            fees: Decimal.zero,
          ),
        );
      },
    );
    await tester.tap(find.byKey(const Key('assetClass')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fund').last);
    await tester.pumpAndSettle();
    await fill(tester, 'symbol', 'TTE');
    await getPrice(tester);
    final first = requests.length;
    expect(first, greaterThan(0));
    await getPrice(tester);
    expect(requests.length, first);
    expect(
      find.textContaining('TEFAS (funds): Rate limited; try again after'),
      findsOneWidget,
    );
    await tester.runAsync(() => c.refreshPrices(manual: true));
    expect(requests.length, first);
  });

  // Presses Get price, optionally moves the date to the 4th while the fetch
  // is held, then lets the held response through inside the real zone.
  Future<void> heldFetch(
    WidgetTester tester, {
    required bool changeDate,
  }) async {
    final gate = Completer<void>();
    await boot(tester, routes, enabled: {'yahoo'}, gate: gate.future);
    await fill(tester, 'symbol', 'THYAO');
    await tester.tap(find.text('Get price'));
    await tester.pump();
    if (changeDate) {
      // Short pumps only: the source's 20 s timeout runs on the fake clock.
      Future<void> frames() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await tester.tap(find.textContaining('Date  '));
      await frames();
      await tester.tap(
        find.descendant(
          of: find.byType(DatePickerDialog),
          matching: find.text('4'),
        ),
      );
      await tester.tap(find.text('OK'));
      await frames();
    }
    await tester.runAsync(() async {
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await settle(tester);
  }

  testWidgets('a held response still fills the form when nothing changed', (
    tester,
  ) async {
    await heldFetch(tester, changeDate: false);
    expect(price(tester), '287.5');
    expect(find.textContaining('Yahoo Finance'), findsOneWidget);
  });

  testWidgets('a result that lands after the date changed is dropped', (
    tester,
  ) async {
    await heldFetch(tester, changeDate: true);
    expect(requests, hasLength(1));
    expect(price(tester), '');
    expect(find.textContaining('Yahoo Finance'), findsNothing);
  });
}
