import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Instrument _i(String s) => Instrument.create(AssetClass.bistShare, s);
Decimal _d(String s) => Decimal.parse(s);

void main() {
  late Directory tmp;
  late AppController c;
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
      await c.openFolder(MemoryRecordFolder(), 'mem', createName: 'Main');
      // Example A: buy 200 @15, sell 50 @18 -> 150 held, cost 2250, realized 150.
      await c.addTransaction(
        Transaction.buy(
          instrument: _i('AAA'),
          date: DateTime.utc(2026, 10, 1),
          dayOrder: 10,
          quantity: _d('200'),
          unitPrice: _d('15'),
          fees: Decimal.zero,
        ),
      );
      await c.addTransaction(
        Transaction.sell(
          instrument: _i('AAA'),
          date: DateTime.utc(2026, 10, 5),
          dayOrder: 10,
          quantity: _d('50'),
          unitPrice: _d('18'),
          fees: Decimal.zero,
        ),
      );
      if (second) {
        await c.addTransaction(
          Transaction.buy(
            instrument: _i('BBB'),
            date: DateTime.utc(2026, 10, 2),
            dayOrder: 10,
            quantity: _d('10'),
            unitPrice: _d('5'),
            fees: Decimal.zero,
          ),
        );
      }
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
    expect(find.text('Market closed'), findsOneWidget);
    await lifetime(tester);
    expect(find.textContaining('600.00'), findsWidgets);
    expect(find.textContaining('2,700.00'), findsWidgets);
    expect(find.text('Return % — Modified Dietz estimate'), findsOneWidget);
    expect(find.text('manual'), findsWidgets);
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(find.text('15'), findsOneWidget);
    expect(find.text('150.00'), findsOneWidget);
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
}
