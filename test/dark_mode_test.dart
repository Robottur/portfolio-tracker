import 'dart:io';

import 'package:portfolio_tracker/app/app_controller.dart';
import 'package:portfolio_tracker/app/device_prefs.dart';
import 'package:portfolio_tracker/main.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:portfolio_core/portfolio_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late AppController c;
  final now = DateTime.utc(2026, 10, 10, 12);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('dark');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  // One holding: BUY 10 @ 10, price 12 → +20.00 TRY gain.
  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(700, 2400);
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
      await c.addTransaction(
        Transaction.buy(
          instrument: Instrument.create(AssetClass.bistShare, 'AAA'),
          date: DateTime.utc(2026, 10, 1),
          dayOrder: 1,
          quantity: Decimal.parse('10'),
          unitPrice: Decimal.parse('10'),
          fees: Decimal.zero,
        ),
      );
      await c.prices.setManual(
        'XIST:AAA',
        c.today,
        Decimal.parse('12'),
        nowUtc: now,
      );
    });
    await tester.pumpWidget(AssetPortfolioApp(controller: c));
    await tester.pumpAndSettle();
  }

  Brightness brightness(WidgetTester tester) =>
      Theme.of(tester.element(find.text('AAA').first)).brightness;

  testWidgets('choosing Dark makes the app dark and is saved', (tester) async {
    await boot(tester);
    expect(brightness(tester), Brightness.light);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dashboard'));
    await tester.pumpAndSettle();
    expect(brightness(tester), Brightness.dark);
    final again = await tester.runAsync(DevicePrefs.load);
    expect(again!.themeMode, ThemeMode.dark);
  });

  testWidgets('System follows the platform brightness', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await boot(tester);
    expect(c.prefs.themeMode, ThemeMode.system);
    expect(brightness(tester), Brightness.dark);
  });

  testWidgets('a gain uses the dark-theme green', (tester) async {
    await boot(tester);
    await tester.tap(find.text('Lifetime')); // rows show gain against cost
    await tester.pumpAndSettle();
    await tester.runAsync(() => c.setThemeMode(ThemeMode.dark));
    await tester.pumpAndSettle();
    final gain = tester.widget<Text>(find.text('+20.00 TRY gain').first);
    expect(gain.style?.color, const Color(0xFF6FCF97));
  });
}
