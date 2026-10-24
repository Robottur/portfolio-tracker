import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:asset_portfolio/ui/holding_screen.dart';
import 'package:asset_portfolio/ui/status_banner.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Instrument _i(String s) => Instrument.create(AssetClass.bistShare, s);
Decimal _d(String s) => Decimal.parse(s);

Transaction _buy(String sym, int day, String q, String p) => Transaction.buy(
  instrument: _i(sym),
  date: DateTime.utc(2026, 10, day),
  dayOrder: 10,
  quantity: _d(q),
  unitPrice: _d(p),
  fees: Decimal.zero,
);

Transaction _sell(String sym, int day, String q, String p) => Transaction.sell(
  instrument: _i(sym),
  date: DateTime.utc(2026, 10, day),
  dayOrder: 20,
  quantity: _d(q),
  unitPrice: _d(p),
  fees: Decimal.zero,
);

const _conflictId = '33333333-3333-4333-8333-333333333333';

void main() {
  late Directory tmp;
  late AppController c;
  late MemoryRecordFolder folder;
  final now = DateTime.utc(2026, 10, 10, 12); // a Saturday

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('dash');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> boot(
    WidgetTester tester, {
    bool second = false,
    double width = 700,
    String sellPrice = '18',
  }) async {
    tester.view.physicalSize = Size(width, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      c = AppController(
        prefs: await DevicePrefs.load(),
        privateDir: tmp,
        network: MockClient((_) async => fail('network')),
        nowUtc: () => now,
      );
      folder = MemoryRecordFolder();
      await c.openFolder(folder, 'mem', createName: 'Main');
      // Example A: avg cost 15, 150 held, cost 2250, realized 150.
      Future<void> tx(Transaction t) => c.addTransaction(t);
      await tx(_buy('AAA', 1, '100', '10'));
      await tx(_buy('AAA', 2, '100', '20'));
      await tx(_sell('AAA', 5, '50', sellPrice));
      if (second) await tx(_buy('BBB', 3, '10', '5'));
      await c.prices.setManual('XIST:AAA', c.today, _d('18'), nowUtc: now);
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.pumpAndSettle();
  }

  Future<void> lifetime(WidgetTester tester) async {
    await tester.tap(find.text('Lifetime'));
    await tester.pumpAndSettle();
  }

  testWidgets('lifetime gain, value, and holding detail', (tester) async {
    await boot(tester);
    expect(find.text('Market closed — last prices'), findsOneWidget);
    await lifetime(tester);
    expect(find.textContaining('600.00'), findsWidgets);
    expect(find.textContaining('2,700.00'), findsWidgets);
    expect(find.text('Return % — Modified Dietz estimate'), findsOneWidget);
    expect(find.text('manual'), findsWidgets);
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('15'), findsOneWidget);
    expect(find.textContaining('150.00'), findsOneWidget);
  });

  testWidgets('privacy mode masks amounts', (tester) async {
    await boot(tester);
    await lifetime(tester);
    await tester.runAsync(() => c.setPrivacy(true));
    await tester.pumpAndSettle();
    expect(find.textContaining('2,700.00'), findsNothing);
    expect(find.textContaining('600.00'), findsNothing);
    expect(find.text('•••••'), findsWidgets);
  });

  testWidgets('missing price shows subtotal, never Total', (tester) async {
    await boot(tester, second: true);
    await lifetime(tester);
    expect(find.textContaining('Known priced holdings'), findsOneWidget);
    expect(find.textContaining('XIST:BBB'), findsWidgets);
    expect(find.textContaining('Total'), findsNothing);
  });

  testWidgets('wide layout shows detail pane beside holdings', (tester) async {
    await boot(tester, width: 1000);
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('Average cost'), findsOneWidget);
    expect(find.text('Realized gain'), findsOneWidget);
  });

  Future<void> inject(WidgetTester tester, List<Transaction> txs) async {
    await tester.runAsync(() async {
      final pid = c.scan!.descriptor!.portfolioId;
      for (final (i, t) in txs.indexed) {
        final r = LedgerRecord.newUpsert(
          portfolioId: pid,
          deviceId: i == 0
              ? c.prefs.deviceId
              : '22222222-2222-4222-8222-222222222222',
          transaction: t,
          transactionId: txs.length == 2 ? _conflictId : null,
          now: DateTime.utc(2026, 10, 8, i),
        );
        folder.records[r.fileName] = r.encode();
      }
      await c.rescan();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('incomplete scan shows previous data under its label', (
    tester,
  ) async {
    await boot(tester);
    await inject(tester, [_buy('CCC', 3, '1', '1'), _buy('CCC', 3, '2', '1')]);
    expect(c.scan!.complete, isFalse);
    await lifetime(tester);
    expect(find.textContaining('Showing previous data from'), findsOneWidget);
    expect(find.textContaining('2,700.00'), findsWidgets);
    expect(find.textContaining('ledger issue'), findsOneWidget);
  });

  testWidgets('incomplete scan without previous data is unavailable', (
    tester,
  ) async {
    await boot(tester);
    c.lastValidScan = null;
    await inject(tester, [_buy('CCC', 3, '1', '1'), _buy('CCC', 3, '2', '1')]);
    expect(find.textContaining('Unavailable — ledger has'), findsWidgets);
    expect(find.text('Portfolio value'), findsNothing);
    expect(find.textContaining('2,700.00'), findsNothing);
  });

  testWidgets('oversell ledger is unavailable', (tester) async {
    await boot(tester);
    await inject(tester, [_sell('AAA', 8, '500', '18')]);
    expect(find.textContaining('Unavailable — ledger has'), findsWidgets);
    expect(find.text('Portfolio value'), findsNothing);
  });

  test('derived gold is labelled indicative, even as an intraday quote', () {
    PriceObservation o(String source, PriceKind kind) => PriceObservation(
      instrumentId: 'GOLD:GRAM',
      price: _d('4000'),
      sessionDate: DateTime.utc(2026, 10, 9),
      quoteTime: now,
      receivedAt: now,
      source: source,
      kind: kind,
    );
    expect(priceTag(o('gold', PriceKind.delayedQuote)), 'indicative');
    expect(priceTag(o('yahoo', PriceKind.delayedQuote)), 'Delayed');
  });

  testWidgets('realized loss shows minus sign and words', (tester) async {
    await boot(tester, sellPrice: '12');
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('−150.00 TRY loss'), findsOneWidget);
  });

  testWidgets('holding gains follow the selected period', (tester) async {
    await boot(tester, width: 360);
    // 1W baseline is Sat 10-03: 200 held at 16, then 50 sold at 18.
    await tester.runAsync(
      () => c.setManualPrice('XIST:AAA', DateTime.utc(2026, 10, 2), _d('16')),
    );
    await tester.pumpAndSettle();
    Finder inRow(String t) => find.descendant(
      of: find.byType(HoldingTile),
      matching: find.textContaining(t),
    );
    await tester.tap(find.text('1W'));
    await tester.pumpAndSettle();
    expect(inRow('400.00'), findsOneWidget); // 2700 − 3200 + 900
    expect(tester.takeException(), isNull); // seven periods fit at 360 px
    await lifetime(tester);
    expect(inRow('450.00'), findsOneWidget); // 2700 − cost 2250
  });
}
