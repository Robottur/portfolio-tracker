import 'dart:io';

import 'package:asset_portfolio/app/app_controller.dart';
import 'package:asset_portfolio/app/device_prefs.dart';
import 'package:asset_portfolio/main.dart';
import 'package:asset_portfolio/ui/gain_colors.dart';
import 'package:asset_portfolio/ui/privacy.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

Decimal _d(String s) => Decimal.parse(s);

const _lightGain = Color(0xFF1B7F3B);
const _lightLoss = Color(0xFFC62828);
const _darkGain = Color(0xFF6FCF97);
const _darkLoss = Color(0xFFFF8A80);

void main() {
  late Directory tmp;
  late AppController c;
  final now = DateTime.utc(2026, 10, 10, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('gain');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Instrument aaa() => Instrument.create(AssetClass.bistShare, 'AAA');
  Transaction buy(int day, String q, String p) => Transaction.buy(
    instrument: aaa(),
    date: DateTime.utc(2026, 10, day),
    dayOrder: 10,
    quantity: _d(q),
    unitPrice: _d(p),
    fees: Decimal.zero,
  );

  Future<void> boot(
    WidgetTester tester, {
    required String price,
    bool exampleA = false,
  }) async {
    tester.view.physicalSize = const Size(700, 1400);
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
      await c.addTransaction(buy(1, '100', '10'));
      if (exampleA) {
        await c.addTransaction(buy(2, '100', '20'));
        await c.addTransaction(
          Transaction.sell(
            instrument: aaa(),
            date: DateTime.utc(2026, 10, 5),
            dayOrder: 20,
            quantity: _d('50'),
            unitPrice: _d('18'),
            fees: Decimal.zero,
          ),
        );
      }
      await c.prices.setManual('XIST:AAA', c.today, _d(price), nowUtc: now);
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.pumpAndSettle();
  }

  Color? colorOf(WidgetTester t, Finder f) =>
      t.widget<Text>(f.first).style?.color;

  Iterable<Color?> allColors(WidgetTester t) =>
      t.widgetList<Text>(find.byType(Text)).map((w) => w.style?.color);

  testWidgets('lifetime gain is green', (tester) async {
    await boot(tester, price: '18', exampleA: true);
    await tester.tap(find.text('Lifetime'));
    await tester.pumpAndSettle();
    expect(colorOf(tester, find.text('+600.00 TRY gain')), _lightGain);
  });

  testWidgets('loss shows red in holdings and detail', (tester) async {
    await boot(tester, price: '8');
    await tester.tap(find.text('Holdings'));
    await tester.pumpAndSettle();
    expect(colorOf(tester, find.textContaining('loss')), _lightLoss);
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(colorOf(tester, find.text('−200.00 TRY loss')), _lightLoss);
  });

  testWidgets('privacy on: no gain or loss colour anywhere', (tester) async {
    await boot(tester, price: '8');
    await tester.runAsync(() => c.setPrivacy(true));
    for (final tab in ['Lifetime', 'Holdings']) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      expect(
        allColors(tester).where(
          (x) =>
              const [_lightGain, _lightLoss, _darkGain, _darkLoss].contains(x),
        ),
        isEmpty,
      );
    }
    await tester.tap(find.textContaining('AAA').first);
    await tester.pumpAndSettle();
    expect(
      allColors(tester).where(
        (x) => const [_lightGain, _lightLoss, _darkGain, _darkLoss].contains(x),
      ),
      isEmpty,
    );
  });

  Future<TextStyle?> styleFor(
    WidgetTester t,
    String v, {
    bool dark = false,
    bool masked = false,
  }) async {
    TextStyle? out;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: dark ? Brightness.dark : Brightness.light),
        home: PrivacyScope(
          masked: masked,
          child: Builder(
            builder: (ctx) {
              out = gainStyle(ctx, _d(v));
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    return out;
  }

  testWidgets('dark variants, zero and masked', (tester) async {
    expect((await styleFor(tester, '1', dark: true))?.color, _darkGain);
    expect((await styleFor(tester, '-1', dark: true))?.color, _darkLoss);
    expect(await styleFor(tester, '0'), isNull);
    expect(await styleFor(tester, '-1', masked: true), isNull);
  });
}
